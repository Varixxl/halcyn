//! The engine thread. It owns the decoder, the converter and the output, keeps the output's
//! ring buffer full, and reports what happens as `PlayerEvent`s.

mod convert;
pub mod dsp;
mod output;
pub(crate) mod source;
mod spectrum;

use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering::Relaxed;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use lofty::prelude::*;

use crate::api::player::{PlayerEvent, Repeat, SignalPath, TrackInfo};
use convert::Converter;
use output::{Output, Shared};
use source::{Source, SourceInfo};
use spectrum::{Analyzer, History};

/// Receives the visualizer's band levels.
pub type SpectrumSink = Box<dyn Fn(Vec<f32>) + Send>;

pub enum Command {
    /// Replaces the queue and starts playing `start`.
    Queue { paths: Vec<PathBuf>, start: usize },
    /// Replaces the queue and loads `start` paused at `at` secs, e.g. to resume last session.
    Cue { paths: Vec<PathBuf>, start: usize, at: f64 },
    /// Replaces the queue around the current track, which is now entry `index`. Playback
    /// carries on undisturbed.
    Edit { paths: Vec<PathBuf>, index: usize },
    /// Starts (Some) or stops (None) sending the visualizer's spectrum.
    Spectrum(Option<SpectrumSink>),
    /// New volume and EQ. `label` describes them for the signal path, None when bypassed.
    Sound { design: dsp::Design, label: Option<String> },
    Play,
    Pause,
    Stop,
    Seek(f64),
    Next,
    Repeat(Repeat),
    /// Back to the start of the track, or to the previous one when near the start already.
    Previous,
}

pub struct Engine {
    tx: mpsc::Sender<Command>,
}

impl Engine {
    pub fn start(emit: impl Fn(PlayerEvent) + Send + 'static) -> Self {
        let (tx, rx) = mpsc::channel();
        std::thread::Builder::new()
            .name("halcyn-engine".into())
            .spawn(move || Runner::new(Box::new(emit)).run(rx))
            .expect("can't start the engine thread");
        Engine { tx }
    }

    pub fn send(&self, cmd: Command) {
        let _ = self.tx.send(cmd);
    }
}

/// How much audio the ring holds ahead of the output.
const RING_SECS: f64 = 1.0;
/// How long to let the output play out the last buffer after the ring runs dry.
const TAIL: Duration = Duration::from_millis(150);
const POSITION_EVERY: Duration = Duration::from_millis(200);
/// Past this point, Previous restarts the track instead of going back.
const RESTART_AFTER_SECS: f64 = 3.0;
const SPECTRUM_EVERY: Duration = Duration::from_millis(16);

struct Track {
    source: Source,
    /// False once a session has read from the source, so the next one has to seek first.
    fresh: bool,
}

/// One open output stream playing the current track.
struct Session {
    converter: Converter,
    ring: rtrb::Producer<i32>,
    shared: Arc<Shared>,
    rate: u32,
    channels: usize,
    /// Samples pushed into the ring so far.
    written: u64,
    /// A copy of the newest samples, kept while the visualizer is on.
    history: Option<History>,
    /// Track position this session started at.
    start_secs: f64,
    block: Vec<i32>,
    block_pos: usize,
    decoding_done: bool,
    drained_at: Option<Instant>,
}

impl Session {
    /// Decodes until the ring is full or the track is out.
    fn fill(&mut self, source: &mut Source) -> Result<()> {
        loop {
            if self.block_pos == self.block.len() {
                if self.decoding_done {
                    return Ok(());
                }
                if !self.converter.pull(source, &mut self.block)? {
                    self.decoding_done = true;
                    self.block.clear();
                }
                self.block_pos = 0;
                continue;
            }
            let n = self.ring.slots().min(self.block.len() - self.block_pos);
            if n == 0 {
                return Ok(());
            }
            let chunk = self.ring.write_chunk_uninit(n).map_err(|e| anyhow!("{e}"))?;
            let samples = &self.block[self.block_pos..self.block_pos + n];
            chunk.fill_from_iter(samples.iter().copied());
            self.written += n as u64;
            if let Some(history) = &mut self.history {
                history.push(samples, self.written);
            }
            self.block_pos += n;
        }
    }

    fn position(&self) -> f64 {
        self.start_secs + self.shared.frames_played.load(Relaxed) as f64 / self.rate as f64
    }

    fn ring_empty(&self) -> bool {
        self.ring.slots() == self.ring.buffer().capacity()
    }

    /// Enough history to reach back from the speakers past the whole ring.
    fn new_history(&self) -> History {
        History::new(self.ring.buffer().capacity() + self.rate as usize / 2 * self.channels)
    }
}

struct Spectrum {
    sink: SpectrumSink,
    analyzer: Option<Analyzer>,
    last: Instant,
}

struct Runner {
    emit: Box<dyn Fn(PlayerEvent) + Send>,
    output: Option<Box<dyn Output>>,
    queue: Vec<PathBuf>,
    index: usize,
    track: Option<Track>,
    session: Option<Session>,
    playing: bool,
    /// The rate the graph actually ran at when it refused ours; we resample to it ourselves.
    rate_override: Option<u32>,
    /// Where to start when a cued track is first played.
    resume_at: Option<f64>,
    last_position: Instant,
    spectrum: Option<Spectrum>,
    dsp: Arc<dsp::Control>,
    /// What the volume and EQ do, for the signal path; None when they're bypassed.
    sound: Option<String>,
    repeat: Repeat,
}

impl Runner {
    fn new(emit: Box<dyn Fn(PlayerEvent) + Send>) -> Self {
        Runner {
            emit,
            output: None,
            queue: Vec::new(),
            index: 0,
            track: None,
            session: None,
            playing: false,
            rate_override: None,
            resume_at: None,
            last_position: Instant::now(),
            spectrum: None,
            dsp: Arc::default(),
            sound: None,
            repeat: Repeat::Off,
        }
    }

    fn run(mut self, rx: mpsc::Receiver<Command>) {
        loop {
            let wait = Duration::from_millis(if self.playing { 10 } else { 250 });
            match rx.recv_timeout(wait) {
                Ok(cmd) => {
                    if let Err(err) = self.handle(cmd) {
                        self.fail(err);
                    }
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => break,
            }
            if self.playing {
                if let Err(err) = self.tick() {
                    self.fail(err);
                }
            }
        }
    }

    fn handle(&mut self, cmd: Command) -> Result<()> {
        match cmd {
            Command::Queue { paths, start } => {
                self.queue = paths;
                self.load(start)?;
            }
            Command::Cue { paths, start, at } => {
                self.queue = paths;
                self.cue(start, at)?;
            }
            Command::Edit { paths, index } => {
                self.queue = paths;
                self.index = index;
            }
            Command::Sound { design, label } => {
                self.dsp.set(design);
                if label != self.sound {
                    self.sound = label;
                    self.emit_path();
                }
            }
            Command::Spectrum(sink) => {
                self.spectrum = sink.map(|sink| Spectrum { sink, analyzer: None, last: Instant::now() });
                let on = self.spectrum.is_some();
                if let Some(session) = self.session.as_mut() {
                    session.history = on.then(|| session.new_history());
                }
            }
            Command::Next => {
                if let Some(next) = self.next_index(false) {
                    self.load(next)?;
                }
            }
            Command::Repeat(mode) => self.repeat = mode,
            Command::Previous => {
                if self.track.is_none() {
                    return Ok(());
                }
                if self.index == 0 || self.position() > RESTART_AFTER_SECS {
                    self.end_session();
                    self.start_session(0.0, !self.playing)?;
                    (self.emit)(PlayerEvent::Position { secs: 0.0 });
                } else {
                    self.load(self.index - 1)?;
                }
            }
            Command::Play => {
                if self.track.is_none() || self.playing {
                    return Ok(());
                }
                match self.output.as_mut().filter(|_| self.session.is_some()) {
                    Some(output) => output.set_paused(false)?,
                    None => self.start_session(self.resume_at.unwrap_or(0.0), false)?,
                }
                self.set_playing(true);
            }
            Command::Pause => {
                if let (Some(output), Some(_)) = (self.output.as_mut(), &self.session) {
                    output.set_paused(true)?;
                }
                self.set_playing(false);
            }
            Command::Stop => {
                self.end_session();
                self.set_playing(false);
                (self.emit)(PlayerEvent::Position { secs: 0.0 });
            }
            Command::Seek(secs) => {
                if self.track.is_none() {
                    return Ok(());
                }
                self.end_session();
                self.start_session(secs, !self.playing)?;
                (self.emit)(PlayerEvent::Position { secs: self.position() });
            }
        }
        Ok(())
    }

    fn tick(&mut self) -> Result<()> {
        let (Some(track), Some(session)) = (self.track.as_mut(), self.session.as_mut()) else {
            return Ok(());
        };
        session.fill(&mut track.source)?;

        // PipeWire may keep the graph at another rate than we asked for and resample us.
        // Resample to the graph's rate ourselves instead.
        let device_rate = session.shared.device_rate.load(Relaxed);
        if device_rate != 0 && device_rate != session.rate && self.rate_override.is_none() {
            let at = session.position();
            self.rate_override = Some(device_rate);
            self.end_session();
            return self.start_session(at, false);
        }

        if session.decoding_done && session.block_pos == session.block.len() && session.ring_empty()
        {
            let drained_at = *session.drained_at.get_or_insert_with(Instant::now);
            if drained_at.elapsed() >= TAIL {
                if let Some(next) = self.next_index(true) {
                    return self.load(next);
                }
                self.end_session();
                self.set_playing(false);
                (self.emit)(PlayerEvent::Ended);
                return Ok(());
            }
        }

        if let Some(spectrum) = self.spectrum.as_mut().filter(|s| s.last.elapsed() >= SPECTRUM_EVERY) {
            spectrum.last = Instant::now();
            let analyzer = match spectrum.analyzer.take() {
                Some(a) if a.rate == session.rate && a.channels == session.channels => a,
                _ => Analyzer::new(session.rate, session.channels),
            };
            let analyzer = spectrum.analyzer.insert(analyzer);
            if let Some(history) = &session.history {
                let frame = session.shared.frames_played.load(Relaxed);
                if let Some(bands) = analyzer.analyse(history, frame) {
                    (spectrum.sink)(bands);
                }
            }
        }

        if self.last_position.elapsed() >= POSITION_EVERY {
            self.last_position = Instant::now();
            (self.emit)(PlayerEvent::Position { secs: self.position() });
        }
        Ok(())
    }

    /// The entry after the current one, if any. Repeat all wraps around; repeat one keeps
    /// the same track when it `ended` (Next still moves on).
    fn next_index(&self, ended: bool) -> Option<usize> {
        if self.queue.is_empty() {
            return None;
        }
        match self.repeat {
            Repeat::One if ended => Some(self.index),
            Repeat::Off => (self.index + 1 < self.queue.len()).then_some(self.index + 1),
            _ => Some((self.index + 1) % self.queue.len()),
        }
    }

    /// Opens queue entry `index` without playing it; Play starts it at `at` secs.
    fn cue(&mut self, index: usize, at: f64) -> Result<()> {
        let path = self.queue.get(index).cloned().ok_or_else(|| anyhow!("no track {index} in the queue"))?;
        self.end_session();
        self.set_playing(false);
        self.index = index;
        let source = Source::open(&path)?;
        let track = track_info(&path, &source.info);
        (self.emit)(PlayerEvent::Loaded { track, index: index as u32 });
        self.track = Some(Track { source, fresh: true });
        self.rate_override = None;
        self.resume_at = Some(at);
        (self.emit)(PlayerEvent::Position { secs: at });
        Ok(())
    }

    /// Opens queue entry `index` and starts playing it.
    fn load(&mut self, index: usize) -> Result<()> {
        let path = self.queue.get(index).cloned().ok_or_else(|| anyhow!("no track {index} in the queue"))?;
        self.end_session();
        self.index = index;
        let source = Source::open(&path)?;
        let track = track_info(&path, &source.info);
        (self.emit)(PlayerEvent::Loaded { track, index: index as u32 });
        self.track = Some(Track { source, fresh: true });
        self.rate_override = None;
        self.start_session(0.0, false)?;
        self.set_playing(true);
        Ok(())
    }

    fn start_session(&mut self, at: f64, paused: bool) -> Result<()> {
        let track = self.track.as_mut().ok_or_else(|| anyhow!("nothing loaded"))?;
        let info = track.source.info.clone();
        let start_secs = if track.fresh && at == 0.0 {
            0.0
        } else {
            track.source.seek(at)? as f64 / info.sample_rate as f64
        };
        track.fresh = false;
        self.resume_at = None;

        if self.output.is_none() {
            self.output = Some(output::open_default()?);
        }
        let output = self.output.as_mut().unwrap();
        let caps = output.caps();
        let rate = self.rate_override.unwrap_or_else(|| output::choose_rate(info.sample_rate, &caps));
        let converter = Converter::new(info.sample_rate, rate, info.channels)?;
        let (ring, consumer) =
            rtrb::RingBuffer::new((rate as f64 * RING_SECS) as usize * info.channels);
        let shared = Arc::new(Shared { dsp: self.dsp.clone(), ..Shared::default() });
        let mut session = Session {
            converter,
            ring,
            shared: shared.clone(),
            rate,
            channels: info.channels,
            written: 0,
            history: None,
            start_secs,
            block: Vec::new(),
            block_pos: 0,
            decoding_done: false,
            drained_at: None,
        };
        if self.spectrum.is_some() {
            session.history = Some(session.new_history());
        }
        session.fill(&mut track.source)?;
        output.open(rate, info.channels, consumer, shared, paused)?;

        self.session = Some(session);
        self.emit_path();
        Ok(())
    }

    /// Tells the UI what happens to the audio now.
    fn emit_path(&self) {
        let (Some(track), Some(session), Some(output)) = (&self.track, &self.session, &self.output) else {
            return;
        };
        let info = &track.source.info;
        let warning = self.rate_override.map(|r| {
            format!(
                "PipeWire kept the graph at {}. Add {} to its allowed rates for bit-exact playback.",
                khz(r),
                khz(info.sample_rate)
            )
        });
        let path = signal_path(info, &session.converter, output.caps().backend, session.rate, warning, self.sound.as_deref());
        (self.emit)(PlayerEvent::Path { path });
    }

    fn end_session(&mut self) {
        if let Some(session) = self.session.take() {
            let clipped = session.converter.clipped();
            if clipped > 0 {
                eprintln!("halcyn: the resampler clipped {clipped} samples");
            }
            if let Some(output) = self.output.as_mut() {
                output.close();
            }
        }
    }

    fn position(&self) -> f64 {
        self.session.as_ref().map(Session::position).or(self.resume_at).unwrap_or(0.0)
    }

    fn set_playing(&mut self, playing: bool) {
        if self.playing != playing {
            self.playing = playing;
            (self.emit)(PlayerEvent::Playing { playing });
        }
    }

    fn fail(&mut self, err: anyhow::Error) {
        self.end_session();
        self.set_playing(false);
        (self.emit)(PlayerEvent::Error { message: format!("{err:#}"), index: self.index as u32 });
    }
}

fn track_info(path: &Path, info: &SourceInfo) -> TrackInfo {
    // A streamed song's details are the app's; it has no tags to read here.
    let tagged = (!crate::streaming::is_stream(path)).then(|| lofty::read_from_path(path).ok()).flatten();
    let tag = tagged.as_ref().and_then(|t| t.primary_tag().or_else(|| t.first_tag()));
    let text = |value: Option<std::borrow::Cow<'_, str>>| value.map(|v| v.into_owned());
    TrackInfo {
        path: path.to_string_lossy().into_owned(),
        title: text(tag.and_then(|t| t.title())).unwrap_or_else(|| {
            path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
        }),
        artist: text(tag.and_then(|t| t.artist())),
        album: text(tag.and_then(|t| t.album())),
        duration_secs: info.total_frames.map(|f| f as f64 / info.sample_rate as f64),
    }
}

fn signal_path(
    info: &SourceInfo,
    converter: &Converter,
    backend: &str,
    rate: u32,
    warning: Option<String>,
    sound: Option<&str>,
) -> SignalPath {
    let codec = if info.codec.starts_with("pcm_") { "PCM".into() } else { info.codec.to_uppercase() };
    let mut source = vec![codec];
    if let Some(bits) = info.bits_per_sample {
        source.push(format!("{bits}-bit"));
    }
    source.push(khz(info.sample_rate));
    source.push(match info.channels {
        1 => "mono".into(),
        2 => "stereo".into(),
        n => format!("{n} ch"),
    });

    let mut steps = Vec::new();
    if !converter.is_passthrough() {
        steps.push(format!("Resampled {} → {}", khz(info.sample_rate), khz(rate)));
    }
    steps.extend(sound.map(String::from));
    let processing = if steps.is_empty() {
        if info.lossless { "Bit-exact".into() } else { "Bit-exact from the decoder".into() }
    } else {
        format!("{} · f64 · TPDF dither to 24-bit", steps.join(" · "))
    };

    SignalPath {
        source: source.join(" · "),
        processing,
        output: format!("{backend} · 32-bit · {}", khz(rate)),
        bit_exact: steps.is_empty(),
        warning,
    }
}

fn khz(rate: u32) -> String {
    format!("{} kHz", rate as f64 / 1000.0)
}
