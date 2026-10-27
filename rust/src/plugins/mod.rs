//! Plugins: small JavaScript files, each run in its own QuickJS sandbox on its own
//! thread. A plugin can't touch files, the network or the app directly. Everything it
//! does is a request (method name + JSON) that the app answers or refuses, so the same
//! plugin behaves the same on Linux, Windows and Android, and the app decides what each
//! one may do. See `prelude.js` for the API plugins see.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use rquickjs::{CatchResultExt, Context, Function, Runtime};

/// Something a plugin asks the app to do. `call` is 0 when no answer is wanted.
#[derive(Debug, Clone)]
pub struct Request {
    pub plugin: String,
    pub call: u32,
    pub method: String,
    pub args: String,
}

pub type Send = Arc<dyn Fn(Request) + std::marker::Send + Sync>;

enum Msg {
    Reply { call: u32, ok: bool, json: String },
    Emit { event: String, json: String },
    Invoke { handler: u32, json: String, reply: u32 },
    Stop,
}

/// What one plugin may use.
const MEMORY: usize = 64 << 20;
const STACK: usize = 1 << 20;
/// How long one turn of a plugin's code (a handler, a timer, a reply) may run before
/// it's stopped, so a stuck loop can't hang its thread for good.
const TURN: Duration = Duration::from_secs(3);

static PLUGINS: Mutex<Option<HashMap<String, mpsc::Sender<Msg>>>> = Mutex::new(None);

fn with_plugins<T>(f: impl FnOnce(&mut HashMap<String, mpsc::Sender<Msg>>) -> T) -> T {
    f(PLUGINS.lock().unwrap().get_or_insert_with(HashMap::new))
}

fn post(id: &str, msg: Msg) -> Result<()> {
    let tx = with_plugins(|p| p.get(id).cloned()).ok_or_else(|| anyhow!("{id} isn't running"))?;
    tx.send(msg).map_err(|_| anyhow!("{id} has stopped"))
}

/// Starts a plugin (stopping any copy already running) and runs its top level. Errors
/// in the source (syntax, a throw at the top level) come back here.
pub fn start(id: &str, source: &str, send: Send) -> Result<()> {
    stop(id);
    let (tx, rx) = mpsc::channel();
    let (ready_tx, ready_rx) = mpsc::channel();
    // Registered before its top level runs: the app may answer what that asks for
    // before `start` returns.
    with_plugins(|p| p.insert(id.to_owned(), tx));
    let (id_owned, source) = (id.to_owned(), source.to_owned());
    let started = std::thread::Builder::new()
        .name(format!("plugin {id}"))
        .spawn(move || run(id_owned, source, rx, send, ready_tx))
        .map_err(anyhow::Error::from)
        .and_then(|_| {
            ready_rx
                .recv()
                .map_err(|_| anyhow!("the plugin's thread ended before it started"))?
                .map_err(|e| anyhow!(e))
        });
    if started.is_err() {
        with_plugins(|p| p.remove(id));
    }
    started
}

pub fn stop(id: &str) {
    if let Some(tx) = with_plugins(|p| p.remove(id)) {
        let _ = tx.send(Msg::Stop);
    }
}

pub fn reply(id: &str, call: u32, ok: bool, json: String) -> Result<()> {
    post(id, Msg::Reply { call, ok, json })
}

/// Tells a plugin something happened, e.g. `trackChanged`.
pub fn emit(id: &str, event: String, json: String) -> Result<()> {
    post(id, Msg::Emit { event, json })
}

/// Calls one of the plugin's handlers (a command, a page's render, a button). Its
/// result comes back as a `__return` request carrying `reply`.
pub fn invoke(id: &str, handler: u32, json: String, reply: u32) -> Result<()> {
    post(id, Msg::Invoke { handler, json, reply })
}

const PRELUDE: &str = include_str!("prelude.js");

fn run(
    id: String,
    source: String,
    rx: mpsc::Receiver<Msg>,
    send: Send,
    ready: mpsc::Sender<std::result::Result<(), String>>,
) {
    let setup = || -> Result<(Runtime, Context)> {
        let rt = Runtime::new()?;
        rt.set_memory_limit(MEMORY);
        rt.set_max_stack_size(STACK);
        let ctx = Context::full(&rt)?;
        Ok((rt, ctx))
    };
    let (rt, ctx) = match setup() {
        Ok(v) => v,
        Err(e) => {
            let _ = ready.send(Err(e.to_string()));
            return;
        }
    };

    let deadline = Rc::new(RefCell::new(None::<Instant>));
    {
        let deadline = deadline.clone();
        rt.set_interrupt_handler(Some(Box::new(move || {
            deadline.borrow().is_some_and(|d| Instant::now() > d)
        })));
    }
    let turn = |deadline: &Rc<RefCell<Option<Instant>>>| {
        *deadline.borrow_mut() = Some(Instant::now() + TURN);
    };

    // Timers live here rather than in the app: (when, the call that resolves it).
    let timers = Rc::new(RefCell::new(Vec::<(Instant, u32)>::new()));

    let report = {
        let (send, id) = (send.clone(), id.clone());
        move |message: String| {
            send(Request { plugin: id.clone(), call: 0, method: "error".into(), args: json_string(&message) });
        }
    };

    turn(&deadline);
    let started = ctx.with(|ctx| -> std::result::Result<(), String> {
        let (send, id, timers) = (send.clone(), id.clone(), timers.clone());
        let host = Function::new(ctx.clone(), move |call: u32, method: String, args: String| {
            if method == "__timer" {
                let ms = args.parse::<u64>().unwrap_or(0).min(24 * 3600 * 1000);
                timers.borrow_mut().push((Instant::now() + Duration::from_millis(ms), call));
            } else {
                send(Request { plugin: id.clone(), call, method, args });
            }
        })
        .map_err(|e| e.to_string())?;
        ctx.globals().set("__send", host).map_err(|e| e.to_string())?;
        ctx.eval::<(), _>(PRELUDE).catch(&ctx).map_err(|e| format!("prelude: {e}"))?;
        ctx.eval::<(), _>(source.as_str()).catch(&ctx).map_err(|e| e.to_string())
    });
    let started = started.and_then(|()| run_jobs(&rt).map_err(|e| e.to_string()));
    let failed = started.is_err();
    let _ = ready.send(started);
    if failed {
        return;
    }

    loop {
        let wait = timers
            .borrow()
            .iter()
            .map(|(at, _)| at.saturating_duration_since(Instant::now()))
            .min()
            .unwrap_or(Duration::from_secs(3600));
        let msg = match rx.recv_timeout(wait) {
            Ok(Msg::Stop) | Err(RecvTimeoutError::Disconnected) => break,
            Ok(msg) => Some(msg),
            Err(RecvTimeoutError::Timeout) => None,
        };
        turn(&deadline);
        let result = ctx.with(|ctx| -> rquickjs::Result<()> {
            let globals = ctx.globals();
            match msg {
                Some(Msg::Reply { call, ok, json }) => {
                    globals.get::<_, Function>("__resolve")?.call::<_, ()>((call, ok, json))
                }
                Some(Msg::Emit { event, json }) => {
                    globals.get::<_, Function>("__emit")?.call::<_, ()>((event, json))
                }
                Some(Msg::Invoke { handler, json, reply }) => {
                    globals.get::<_, Function>("__invoke")?.call::<_, ()>((handler, json, reply))
                }
                Some(Msg::Stop) => Ok(()),
                None => {
                    let now = Instant::now();
                    let due: Vec<u32> = {
                        let mut t = timers.borrow_mut();
                        let due = t.iter().filter(|(at, _)| *at <= now).map(|(_, c)| *c).collect();
                        t.retain(|(at, _)| *at > now);
                        due
                    };
                    let resolve = globals.get::<_, Function>("__resolve")?;
                    for call in due {
                        resolve.call::<_, ()>((call, true, "null"))?;
                    }
                    Ok(())
                }
            }
            .catch(&ctx)
            .map_err(|e| {
                report(e.to_string());
                rquickjs::Error::Unknown
            })
        });
        if result.is_ok() {
            if let Err(e) = run_jobs(&rt) {
                report(e.to_string());
            }
        }
    }
    *deadline.borrow_mut() = None;
}

/// Runs queued promise callbacks until there are none.
fn run_jobs(rt: &Runtime) -> Result<()> {
    loop {
        match rt.execute_pending_job() {
            Ok(true) => {}
            Ok(false) => return Ok(()),
            Err(e) => {
                return Err(anyhow!(e.0.with(|ctx| {
                    rquickjs::CaughtError::from_error(&ctx, rquickjs::Error::Exception).to_string()
                })));
            }
        }
    }
}

fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests;
