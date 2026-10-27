//! The player API that Flutter calls. Commands go to the engine thread; everything the UI
//! shows comes back through the `player_events` stream.

use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use crate::engine::{Command, Engine};
use crate::frb_generated::StreamSink;

#[derive(Debug)]
pub struct TrackInfo {
    pub path: String,
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration_secs: Option<f64>,
}

/// What happens to the audio between the file and the speakers.
#[derive(Debug)]
pub struct SignalPath {
    /// The file, e.g. "FLAC · 16-bit · 44.1 kHz · stereo".
    pub source: String,
    /// What Halcyn does to it, e.g. "Bit-exact" or "Resampled 44.1 → 48 kHz · f64 · TPDF 24-bit".
    pub processing: String,
    /// Where it goes, e.g. "PipeWire · S32 · 48 kHz".
    pub output: String,
    /// True when the samples reach the output untouched.
    pub bit_exact: bool,
    /// Set when something past Halcyn changes the audio, e.g. PipeWire resampling again.
    pub warning: Option<String>,
}

/// What happens when a track ends.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Repeat {
    /// Stop after the last track.
    #[default]
    Off,
    /// Back to the first track after the last.
    All,
    /// Play the current track again.
    One,
}

#[derive(Debug)]
pub enum PlayerEvent {
    /// Queue entry `index` started.
    Loaded { track: TrackInfo, index: u32 },
    Path { path: SignalPath },
    Playing { playing: bool },
    Position { secs: f64 },
    Ended,
    /// `index` is the queue entry it happened on, e.g. a file that couldn't be opened.
    Error { message: String, index: u32 },
}

/// Where events go. Until Flutter subscribes they wait in `pending`, so a file opened right
/// at startup still shows up.
struct Events {
    sink: Option<StreamSink<PlayerEvent>>,
    pending: Vec<PlayerEvent>,
}

static EVENTS: Mutex<Events> = Mutex::new(Events { sink: None, pending: Vec::new() });
static ENGINE: OnceLock<Engine> = OnceLock::new();

pub(crate) fn engine() -> &'static Engine {
    ENGINE.get_or_init(|| {
        Engine::start(|event| {
            let mut events = EVENTS.lock().unwrap();
            match &events.sink {
                Some(sink) => {
                    let _ = sink.add(event);
                }
                None => events.pending.push(event),
            }
        })
    })
}

pub fn player_events(sink: StreamSink<PlayerEvent>) {
    let mut events = EVENTS.lock().unwrap();
    for event in events.pending.drain(..) {
        let _ = sink.add(event);
    }
    events.sink = Some(sink);
}

/// Replaces the queue with `paths` and starts playing entry `start`.
#[flutter_rust_bridge::frb(sync)]
pub fn player_play_queue(paths: Vec<String>, start: u32) {
    let paths = paths.into_iter().map(PathBuf::from).collect();
    engine().send(Command::Queue { paths, start: start as usize });
}

/// Replaces the queue with `paths` and loads entry `start` paused, ready to play from `at`
/// secs. For picking up where the last session left off.
#[flutter_rust_bridge::frb(sync)]
pub fn player_cue_queue(paths: Vec<String>, start: u32, at: f64) {
    let paths = paths.into_iter().map(PathBuf::from).collect();
    engine().send(Command::Cue { paths, start: start as usize, at });
}

/// Replaces the queue without interrupting playback; the current track is now entry `index`.
#[flutter_rust_bridge::frb(sync)]
pub fn player_edit_queue(paths: Vec<String>, index: u32) {
    let paths = paths.into_iter().map(PathBuf::from).collect();
    engine().send(Command::Edit { paths, index: index as usize });
}

/// The visualizer's band levels (0..1, bass first), about 60 times a second while playing.
/// Nothing is computed until this is called; `player_spectrum_stop` turns it off again.
pub fn player_spectrum(sink: StreamSink<Vec<f32>>) {
    engine().send(Command::Spectrum(Some(Box::new(move |bands| {
        let _ = sink.add(bands);
    }))));
}

#[flutter_rust_bridge::frb(sync)]
pub fn player_spectrum_stop() {
    engine().send(Command::Spectrum(None));
}

#[flutter_rust_bridge::frb(sync)]
pub fn player_play() {
    engine().send(Command::Play);
}

#[flutter_rust_bridge::frb(sync)]
pub fn player_pause() {
    engine().send(Command::Pause);
}

#[flutter_rust_bridge::frb(sync)]
pub fn player_stop() {
    engine().send(Command::Stop);
}

#[flutter_rust_bridge::frb(sync)]
pub fn player_seek(secs: f64) {
    engine().send(Command::Seek(secs));
}

#[flutter_rust_bridge::frb(sync)]
pub fn player_next() {
    engine().send(Command::Next);
}

#[flutter_rust_bridge::frb(sync)]
pub fn player_set_repeat(mode: Repeat) {
    engine().send(Command::Repeat(mode));
}

#[flutter_rust_bridge::frb(sync)]
pub fn player_previous() {
    engine().send(Command::Previous);
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
