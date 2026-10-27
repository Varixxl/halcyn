use std::sync::mpsc;
use std::sync::Arc;
use std::time::Duration;

use super::*;

/// Starts `source` as plugin `id`, with its requests going to the returned receiver.
fn plugin(id: &str, source: &str) -> (Result<()>, mpsc::Receiver<Request>) {
    let (tx, rx) = mpsc::channel();
    let tx = Mutex::new(tx);
    let send: Send = Arc::new(move |r| {
        let _ = tx.lock().unwrap().send(r);
    });
    (start(id, source, send), rx)
}

/// The next request that isn't a log line.
fn next(rx: &mpsc::Receiver<Request>) -> Request {
    loop {
        let r = rx.recv_timeout(Duration::from_secs(5)).expect("no request");
        if r.method != "log" {
            return r;
        }
    }
}

#[test]
fn a_call_is_answered_through_its_promise() {
    let (started, rx) = plugin(
        "answer",
        r#"halcyn.library.search('blur').then(found => console.error('found ' + found.length))"#,
    );
    started.unwrap();
    let r = next(&rx);
    assert_eq!((r.plugin.as_str(), r.method.as_str()), ("answer", "library.search"));
    assert_eq!(r.args, r#"{"query":"blur"}"#);
    reply("answer", r.call, true, "[1,2,3]".into()).unwrap();
    let r = next(&rx);
    assert_eq!((r.method.as_str(), r.args.as_str()), ("error", r#""found 3""#));
    stop("answer");
}

#[test]
fn a_refusal_rejects_the_promise() {
    let (started, rx) = plugin(
        "refused",
        r#"halcyn.http.get('https://example.com').catch(e => console.error(e.message))"#,
    );
    started.unwrap();
    let r = next(&rx);
    reply("refused", r.call, false, r#""no network permission""#.into()).unwrap();
    assert_eq!(next(&rx).args, r#""no network permission""#);
    stop("refused");
}

#[test]
fn errors_in_the_source_come_back_from_start() {
    let (started, _) = plugin("syntax", "this is not javascript (");
    let err = started.unwrap_err().to_string();
    assert!(err.contains("expecting ';'") && err.contains("1:6"), "{err}");
    let (started, _) = plugin("throws", "throw new Error('nope')");
    assert!(started.unwrap_err().to_string().contains("nope"));
}

#[test]
fn a_runaway_loop_is_stopped() {
    let (started, _) = plugin("loop", "while (true) {}");
    assert!(started.unwrap_err().to_string().contains("interrupted"));
}

#[test]
fn a_memory_hog_is_stopped() {
    let (started, _) = plugin("hog", "const a = []; while (true) a.push('x'.repeat(1 << 20));");
    let err = started.unwrap_err().to_string();
    assert!(err.contains("memory") || err.contains("interrupted"), "{err}");
}

#[test]
fn invoking_a_handler_returns_its_value_with_callbacks_as_ids() {
    let (started, rx) = plugin(
        "page",
        r#"halcyn.ui.addPage({ title: 'Hi', render: async () => [
             { type: 'text', text: 'hello' },
             { type: 'button', title: 'Go', onPress: () => console.error('pressed') },
           ] })"#,
    );
    started.unwrap();
    let r = next(&rx);
    assert_eq!(r.method, "ui.addTab");
    assert_eq!(r.args, r#"{"title":"Hi","handler":1,"where":"sidebar"}"#);
    reply("page", r.call, true, "null".into()).unwrap();

    invoke("page", 1, "null".into(), 7).unwrap();
    let r = next(&rx);
    assert_eq!(r.method, "__return");
    assert_eq!(
        r.args,
        r#"{"reply":7,"ok":true,"value":[{"type":"text","text":"hello"},{"type":"button","title":"Go","onPress":{"handler":2}}]}"#
    );
    invoke("page", 2, "null".into(), 8).unwrap();
    assert_eq!(next(&rx).args, r#""pressed""#);
    stop("page");
}

#[test]
fn a_throwing_handler_reports_and_fails_its_return() {
    let (started, rx) = plugin(
        "bad-command",
        r#"halcyn.ui.addCommand({ title: 'Boom', run: () => { throw new Error('boom') } })"#,
    );
    started.unwrap();
    let r = next(&rx);
    reply("bad-command", r.call, true, "null".into()).unwrap();
    invoke("bad-command", 1, "null".into(), 1).unwrap();
    let error = next(&rx);
    assert_eq!(error.method, "error");
    assert!(error.args.contains("boom"));
    let ret = next(&rx);
    assert_eq!(ret.method, "__return");
    assert!(ret.args.contains(r#""ok":false"#));
    stop("bad-command");
}

#[test]
fn timers_fire_in_order() {
    let (started, rx) = plugin(
        "timers",
        r#"setTimeout(() => console.error('late'), 60);
           setTimeout(() => console.error('soon'), 10);
           const t = setTimeout(() => console.error('never'), 20);
           clearTimeout(t);"#,
    );
    started.unwrap();
    assert_eq!(next(&rx).args, r#""soon""#);
    assert_eq!(next(&rx).args, r#""late""#);
    assert!(rx.recv_timeout(Duration::from_millis(100)).is_err());
    stop("timers");
}

#[test]
fn events_reach_listeners() {
    let (started, rx) = plugin(
        "events",
        r#"halcyn.on('trackChanged', t => console.error('now ' + t.title))"#,
    );
    started.unwrap();
    let r = next(&rx);
    assert_eq!((r.method.as_str(), r.args.as_str()), ("on", r#"{"event":"trackChanged"}"#));
    emit("events", "trackChanged".into(), r#"{"title":"Blur"}"#.into()).unwrap();
    assert_eq!(next(&rx).args, r#""now Blur""#);
    stop("events");
}

#[test]
fn a_stopped_plugin_takes_no_more_messages() {
    let (started, _) = plugin("stopped", "");
    started.unwrap();
    stop("stopped");
    assert!(emit("stopped", "x".into(), "null".into()).is_err());
}
