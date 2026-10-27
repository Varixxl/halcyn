//! What's playing on the user's Discord profile, through the Discord app's own Rich Presence
//! socket on this computer (a named pipe on Windows). Nothing goes anywhere else. A thread
//! of its own keeps Discord showing the latest activity, at most one update every few
//! seconds (Discord's limit), and looks for Discord again every so often while it's closed.

use std::collections::VecDeque;
use std::io::{Read, Write};
use std::sync::{Condvar, LazyLock, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};

/// Between looks for Discord while it's closed.
const RETRY: Duration = Duration::from_secs(20);
/// Discord takes 5 updates in any 20 s: a song change goes at once unless that many went
/// lately.
const BURST: usize = 5;
const WINDOW: Duration = Duration::from_secs(20);

#[derive(Default)]
struct State {
    app_id: String,
    /// The activity (JSON) Discord should show; None clears it.
    want: Option<String>,
    sent: Option<String>,
    /// "" (not tried yet), "on", or why not.
    status: String,
    running: bool,
}

static STATE: LazyLock<(Mutex<State>, Condvar)> = LazyLock::new(Default::default);

/// Shows `activity` (Discord's activity object, as JSON) or, with None, nothing.
pub fn set(app_id: String, activity: Option<String>) {
    let (lock, ready) = &*STATE;
    let mut state = lock.lock().unwrap();
    if state.app_id != app_id {
        state.app_id = app_id;
        state.sent = None;
    }
    state.want = activity;
    if !state.running && state.want.is_some() {
        state.running = true;
        std::thread::Builder::new().name("discord".into()).spawn(run).expect("a thread");
    }
    ready.notify_one();
}

pub fn status() -> String {
    STATE.0.lock().unwrap().status.clone()
}

trait Pipe: Read + Write + Send {}
impl<T: Read + Write + Send> Pipe for T {}

struct Conn {
    pipe: Box<dyn Pipe>,
    app_id: String,
    nonce: u64,
}

fn run() {
    let (lock, ready) = &*STATE;
    let mut conn: Option<Conn> = None;
    let mut recent: VecDeque<Instant> = VecDeque::new();
    loop {
        let (app_id, want) = {
            let state = lock.lock().unwrap();
            let state = ready.wait_timeout_while(state, RETRY, |s| s.want == s.sent).unwrap().0;
            if state.want == state.sent {
                continue;
            }
            (state.app_id.clone(), state.want.clone())
        };
        while recent.front().is_some_and(|t| t.elapsed() >= WINDOW) {
            recent.pop_front();
        }
        if recent.len() >= BURST {
            std::thread::sleep(WINDOW.saturating_sub(recent[0].elapsed()));
            continue; // (what to show may have changed meanwhile)
        }
        recent.push_back(Instant::now());
        let result = (|| -> Result<()> {
            if conn.as_ref().is_some_and(|c| c.app_id != app_id) {
                conn = None;
            }
            if conn.is_none() {
                if want.is_none() {
                    return Ok(());
                }
                conn = Some(connect(&app_id)?);
            }
            let c = conn.as_mut().unwrap();
            c.nonce += 1;
            let activity = match &want {
                Some(json) => serde_json::from_str(json)?,
                None => serde_json::Value::Null,
            };
            let mut args = serde_json::json!({ "pid": std::process::id() });
            if !activity.is_null() {
                args["activity"] = activity;
            }
            let command = serde_json::json!({ "cmd": "SET_ACTIVITY", "args": args, "nonce": c.nonce.to_string() });
            send(&mut c.pipe, 1, &command)?;
            reply(&mut c.pipe)?;
            Ok(())
        })();
        let mut state = lock.lock().unwrap();
        match result {
            Ok(()) => {
                state.sent = want;
                state.status = if conn.is_some() { "on".into() } else { String::new() };
            }
            Err(e) => {
                conn = None;
                state.sent = None;
                state.status = e.to_string().chars().take(80).collect();
                // Look again in a while, or when something changes.
                drop(ready.wait_timeout(state, RETRY).unwrap());
            }
        }
    }
}

fn connect(app_id: &str) -> Result<Conn> {
    let mut pipe = open().ok_or_else(|| anyhow!("Discord isn't open"))?;
    send(&mut pipe, 0, &serde_json::json!({ "v": 1, "client_id": app_id }))?;
    reply(&mut pipe)?;
    Ok(Conn { pipe, app_id: app_id.into(), nonce: 0 })
}

#[cfg(windows)]
fn open() -> Option<Box<dyn Pipe>> {
    (0..10).find_map(|i| {
        let pipe = std::fs::OpenOptions::new().read(true).write(true).open(format!(r"\\?\pipe\discord-ipc-{i}"));
        pipe.ok().map(|p| Box::new(p) as Box<dyn Pipe>)
    })
}

/// Discord's socket, wherever this Discord keeps it: the plain app, Flatpak, Snap, or
/// Vesktop's arRPC.
#[cfg(unix)]
fn open() -> Option<Box<dyn Pipe>> {
    let base = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"]
        .iter()
        .find_map(|v| std::env::var(v).ok())
        .unwrap_or_else(|| "/tmp".into());
    let dirs = ["", "app/com.discordapp.Discord/", "app/com.discordapp.DiscordCanary/", "snap.discord/",
        ".flatpak/dev.vencord.Vesktop/xdg-run/", "app/dev.vencord.Vesktop/"];
    for dir in dirs {
        for i in 0..10 {
            let path = format!("{base}/{dir}discord-ipc-{i}");
            if let Ok(s) = std::os::unix::net::UnixStream::connect(&path) {
                s.set_read_timeout(Some(Duration::from_secs(10))).ok()?;
                s.set_write_timeout(Some(Duration::from_secs(10))).ok()?;
                return Some(Box::new(s));
            }
        }
    }
    None
}

fn send(pipe: &mut Box<dyn Pipe>, op: u32, data: &serde_json::Value) -> Result<()> {
    let body = serde_json::to_vec(data)?;
    let mut frame = Vec::with_capacity(8 + body.len());
    frame.extend_from_slice(&op.to_le_bytes());
    frame.extend_from_slice(&(body.len() as u32).to_le_bytes());
    frame.extend_from_slice(&body);
    pipe.write_all(&frame)?;
    pipe.flush()?;
    Ok(())
}

/// Discord's answer; an error if it said no or hung up.
fn reply(pipe: &mut Box<dyn Pipe>) -> Result<serde_json::Value> {
    let mut head = [0u8; 8];
    pipe.read_exact(&mut head).map_err(|_| anyhow!("Discord closed the connection"))?;
    let op = u32::from_le_bytes(head[..4].try_into()?);
    let len = u32::from_le_bytes(head[4..].try_into()?) as usize;
    if len > 1 << 20 {
        bail!("Discord sent something odd");
    }
    let mut body = vec![0u8; len];
    pipe.read_exact(&mut body)?;
    let data: serde_json::Value = serde_json::from_slice(&body).unwrap_or_default();
    // 2: Discord closed it, saying why.
    if op == 2 || data["evt"] == "ERROR" {
        let message = data["data"]["message"].as_str().or(data["message"].as_str()).unwrap_or("Discord said no");
        bail!("{message}");
    }
    Ok(data)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    /// A pretend Discord: says hello, then answers every command, keeping what it got.
    #[test]
    fn talks_to_discord_through_its_socket() {
        let dir = std::env::temp_dir().join(format!("halcyn-discord-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let listener = UnixListener::bind(dir.join("discord-ipc-0")).unwrap();
        let fake = std::thread::spawn(move || {
            let (s, _) = listener.accept().unwrap();
            let mut pipe: Box<dyn Pipe> = Box::new(s);
            let mut got = vec![];
            for _ in 0..3 {
                let mut head = [0u8; 8];
                if pipe.read_exact(&mut head).is_err() {
                    break;
                }
                let mut body = vec![0u8; u32::from_le_bytes(head[4..].try_into().unwrap()) as usize];
                pipe.read_exact(&mut body).unwrap();
                got.push((u32::from_le_bytes(head[..4].try_into().unwrap()), String::from_utf8(body).unwrap()));
                send(&mut pipe, 1, &serde_json::json!({ "evt": null, "data": {} })).unwrap();
            }
            got
        });
        std::env::set_var("XDG_RUNTIME_DIR", &dir);
        set("123".into(), Some(r#"{"type":2,"details":"A song"}"#.into()));
        let deadline = Instant::now() + Duration::from_secs(5);
        while status() != "on" && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(status(), "on");
        set("123".into(), None);
        let got = fake.join().unwrap();
        assert_eq!(got[0], (0, r#"{"client_id":"123","v":1}"#.into()));
        let first: serde_json::Value = serde_json::from_str(&got[1].1).unwrap();
        assert_eq!(first["cmd"], "SET_ACTIVITY");
        assert_eq!(first["args"]["activity"]["details"], "A song");
        // Cleared: the same command without an activity, a few seconds later.
        let second: serde_json::Value = serde_json::from_str(&got[2].1).unwrap();
        assert!(second["args"].get("activity").is_none());
        std::fs::remove_dir_all(&dir).ok();
    }
}
