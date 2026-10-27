//! Plays a file through the engine and prints its events: `cargo run --example play -- <file>`.
//! Set HALCYN_PW_TARGET to a PipeWire node name to play somewhere other than the default sink.

use halcyn_core::api::player::PlayerEvent;
use halcyn_core::engine::{Command, Engine};

fn main() {
    let path = std::env::args().nth(1).expect("usage: play <file>");
    let (tx, rx) = std::sync::mpsc::channel();
    let engine = Engine::start(move |event| {
        let _ = tx.send(event);
    });
    engine.send(Command::Queue { paths: vec![path.into()], start: 0 });
    for event in rx {
        if !matches!(event, PlayerEvent::Position { .. }) {
            println!("{event:?}");
        }
        if matches!(event, PlayerEvent::Ended | PlayerEvent::Error { .. }) {
            break;
        }
    }
}
