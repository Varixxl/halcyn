//! PipeWire output. A dedicated thread runs the PipeWire main loop; commands reach it over a
//! PipeWire channel, and the realtime callback pulls samples straight from the ring buffer.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::atomic::Ordering::Relaxed;
use std::sync::{mpsc, Arc, Mutex};
use std::thread::JoinHandle;

use anyhow::{anyhow, Result};
use pipewire as pw;
use pw::core::CoreRc;
use pw::main_loop::MainLoopRc;
use pw::metadata::{Metadata, MetadataListener};
use pw::properties::PropertiesBox;
use pw::spa;
use pw::spa::param::audio::{AudioFormat, AudioInfoRaw, MAX_CHANNELS};
use pw::spa::pod::serialize::PodSerializer;
use pw::spa::pod::{Object, Pod, Value};
use pw::stream::{Stream, StreamFlags, StreamListener, StreamRc};
use pw::types::ObjectType;

use super::super::dsp::Chain;
use super::{Caps, Output, Shared};

enum Cmd {
    Open {
        rate: u32,
        channels: usize,
        ring: rtrb::Consumer<i32>,
        shared: Arc<Shared>,
        paused: bool,
        reply: mpsc::Sender<Result<()>>,
    },
    Pause(bool),
    Close,
    Quit,
}

/// The graph's clock settings, from PipeWire's "settings" metadata.
#[derive(Default)]
struct Settings {
    clock_rate: u32,
    allowed_rates: Vec<u32>,
    force_rate: u32,
}

impl Settings {
    fn apply(&mut self, key: &str, value: Option<&str>) {
        let value = value.unwrap_or("");
        match key {
            "clock.rate" => self.clock_rate = value.trim().parse().unwrap_or(0),
            "clock.force-rate" => self.force_rate = value.trim().parse().unwrap_or(0),
            "clock.allowed-rates" => {
                self.allowed_rates = value
                    .split(|c: char| !c.is_ascii_digit())
                    .filter_map(|n| n.parse().ok())
                    .collect();
                self.allowed_rates.sort_unstable();
            }
            _ => {}
        }
    }

    /// Rates the graph will run at for us, ascending.
    fn rates(&self) -> Vec<u32> {
        if self.force_rate > 0 {
            vec![self.force_rate]
        } else if !self.allowed_rates.is_empty() {
            self.allowed_rates.clone()
        } else if self.clock_rate > 0 {
            vec![self.clock_rate]
        } else {
            vec![48000]
        }
    }
}

pub struct PipeWireOutput {
    tx: pw::channel::Sender<Cmd>,
    settings: Arc<Mutex<Settings>>,
    thread: Option<JoinHandle<()>>,
}

impl PipeWireOutput {
    pub fn new() -> Result<Self> {
        let (tx, rx) = pw::channel::channel();
        let settings = Arc::new(Mutex::new(Settings::default()));
        let (ready_tx, ready_rx) = mpsc::channel();
        let thread_settings = settings.clone();
        let thread = std::thread::Builder::new().name("halcyn-pipewire".into()).spawn(move || {
            if let Err(err) = run(rx, thread_settings, &ready_tx) {
                let _ = ready_tx.send(Err(err));
            }
        })?;
        ready_rx.recv().map_err(|_| anyhow!("the PipeWire thread exited"))??;
        Ok(PipeWireOutput { tx, settings, thread: Some(thread) })
    }

    fn send(&self, cmd: Cmd) -> Result<()> {
        self.tx.send(cmd).map_err(|_| anyhow!("the PipeWire thread is gone"))
    }
}

impl Output for PipeWireOutput {
    fn caps(&self) -> Caps {
        Caps { backend: "PipeWire", rates: self.settings.lock().unwrap().rates() }
    }

    fn open(
        &mut self,
        rate: u32,
        channels: usize,
        ring: rtrb::Consumer<i32>,
        shared: Arc<Shared>,
        paused: bool,
    ) -> Result<()> {
        let (reply, result) = mpsc::channel();
        self.send(Cmd::Open { rate, channels, ring, shared, paused, reply })?;
        result.recv().map_err(|_| anyhow!("the PipeWire thread is gone"))?
    }

    fn set_paused(&mut self, paused: bool) -> Result<()> {
        self.send(Cmd::Pause(paused))
    }

    fn close(&mut self) {
        let _ = self.send(Cmd::Close);
    }
}

impl Drop for PipeWireOutput {
    fn drop(&mut self) {
        let _ = self.send(Cmd::Quit);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// What the realtime callback owns.
struct Feed {
    ring: rtrb::Consumer<i32>,
    shared: Arc<Shared>,
    channels: usize,
    chain: Chain,
    /// Samples on their way through the chain; sized up front so the callback never allocates.
    scratch: Vec<i32>,
}

/// An open stream. The listener is declared first so it is dropped before the stream.
struct Playing {
    _listener: StreamListener<Feed>,
    stream: StreamRc,
}

fn run(
    rx: pw::channel::Receiver<Cmd>,
    settings: Arc<Mutex<Settings>>,
    ready: &mpsc::Sender<Result<()>>,
) -> Result<()> {
    pw::init();
    let mainloop = MainLoopRc::new(None)?;
    let context = pw::context::ContextRc::new(&mainloop, None)?;
    let core = context.connect_rc(None)?;
    let registry = core.get_registry_rc()?;

    // Bind the "settings" metadata and keep its values current.
    let watch: Rc<RefCell<Option<(Metadata, MetadataListener)>>> = Default::default();
    let registry_weak = registry.downgrade();
    let watch_slot = watch.clone();
    let _registry_listener = registry
        .add_listener_local()
        .global(move |global| {
            let is_settings = global.type_ == ObjectType::Metadata
                && global.props.and_then(|p| p.get("metadata.name")) == Some("settings");
            let Some(registry) = registry_weak.upgrade() else { return };
            if !is_settings {
                return;
            }
            let Ok(metadata) = registry.bind::<Metadata, _>(global) else { return };
            let settings = settings.clone();
            let listener = metadata
                .add_listener_local()
                .property(move |_, key, _, value| {
                    if let Some(key) = key {
                        settings.lock().unwrap().apply(key, value);
                    }
                    0
                })
                .register();
            *watch_slot.borrow_mut() = Some((metadata, listener));
        })
        .register();
    roundtrip(&mainloop, &core)?;
    roundtrip(&mainloop, &core)?;
    let _ = ready.send(Ok(()));

    let current: RefCell<Option<Playing>> = RefCell::new(None);
    let quit = mainloop.clone();
    let _receiver = rx.attach(mainloop.loop_(), move |cmd| match cmd {
        Cmd::Open { rate, channels, ring, shared, paused, reply } => {
            current.borrow_mut().take();
            let chain = Chain::new(&shared.dsp, rate, channels);
            let scratch = Vec::with_capacity(rate as usize * channels);
            let feed = Feed { ring, shared, channels, chain, scratch };
            let _ = reply.send(open_stream(&core, rate, channels, feed, paused).map(|playing| {
                *current.borrow_mut() = Some(playing);
            }));
        }
        Cmd::Pause(paused) => {
            if let Some(playing) = current.borrow().as_ref() {
                let _ = playing.stream.set_active(!paused);
            }
        }
        Cmd::Close => {
            current.borrow_mut().take();
        }
        Cmd::Quit => {
            current.borrow_mut().take();
            quit.quit();
        }
    });
    mainloop.run();
    Ok(())
}

/// Runs the loop until the server has answered everything sent so far.
fn roundtrip(mainloop: &MainLoopRc, core: &CoreRc) -> Result<()> {
    let done = Rc::new(Cell::new(false));
    let pending = core.sync(0)?;
    let (done_flag, quit) = (done.clone(), mainloop.clone());
    let _listener = core
        .add_listener_local()
        .done(move |id, seq| {
            if id == pw::core::PW_ID_CORE && seq == pending {
                done_flag.set(true);
                quit.quit();
            }
        })
        .register();
    while !done.get() {
        mainloop.run();
    }
    Ok(())
}

fn open_stream(
    core: &CoreRc,
    rate: u32,
    channels: usize,
    feed: Feed,
    paused: bool,
) -> Result<Playing> {
    let mut props = PropertiesBox::new();
    props.insert(*pw::keys::MEDIA_TYPE, "Audio");
    props.insert(*pw::keys::MEDIA_CATEGORY, "Playback");
    props.insert(*pw::keys::MEDIA_ROLE, "Music");
    props.insert(*pw::keys::APP_NAME, "Halcyn");
    props.insert(*pw::keys::NODE_NAME, "halcyn");
    // Ask the graph to switch to our rate. It does when the rate is allowed and the device
    // supports it; the engine checks `Shared::device_rate` to see whether that happened.
    props.insert("node.rate", format!("1/{rate}"));
    props.insert(*pw::keys::NODE_LATENCY, format!("{}/{rate}", rate / 20));
    if let Ok(target) = std::env::var("HALCYN_PW_TARGET") {
        props.insert("target.object", target);
    }

    let stream = StreamRc::new(core.clone(), "Halcyn", props)?;
    let listener = stream.add_local_listener_with_user_data(feed).process(process).register()?;

    let mut info = AudioInfoRaw::new();
    info.set_format(AudioFormat::S32LE);
    info.set_rate(rate);
    info.set_channels(channels as u32);
    info.set_position(positions(channels));
    let bytes = PodSerializer::serialize(
        std::io::Cursor::new(Vec::new()),
        &Value::Object(Object {
            type_: spa::sys::SPA_TYPE_OBJECT_Format,
            id: spa::sys::SPA_PARAM_EnumFormat,
            properties: info.into(),
        }),
    )
    .map_err(|e| anyhow!("can't build the stream format: {e:?}"))?
    .0
    .into_inner();
    let mut params = [Pod::from_bytes(&bytes).ok_or_else(|| anyhow!("bad format pod"))?];

    let mut flags = StreamFlags::AUTOCONNECT | StreamFlags::MAP_BUFFERS | StreamFlags::RT_PROCESS;
    if paused {
        flags |= StreamFlags::INACTIVE;
    }
    stream.connect(spa::utils::Direction::Output, None, flags, &mut params)?;
    Ok(Playing { _listener: listener, stream })
}

/// The realtime callback: copy whatever the ring holds, pad the rest with silence.
fn process(stream: &Stream, feed: &mut Feed) {
    let Some(mut buffer) = stream.dequeue_buffer() else { return };
    let requested = buffer.requested() as usize;
    let stride = 4 * feed.channels;
    let data = &mut buffer.datas_mut()[0];
    let Some(bytes) = data.data() else { return };

    let mut frames = bytes.len() / stride;
    if requested > 0 {
        frames = frames.min(requested);
    }
    let wanted = frames * feed.channels;
    let available = feed.ring.slots().min(wanted) / feed.channels * feed.channels;
    if let Ok(chunk) = feed.ring.read_chunk(available) {
        let (a, b) = chunk.as_slices();
        if feed.chain.active(&feed.shared.dsp) && available <= feed.scratch.capacity() {
            feed.scratch.clear();
            feed.scratch.extend_from_slice(a);
            feed.scratch.extend_from_slice(b);
            feed.chain.process(&feed.shared.dsp, &mut feed.scratch);
            for (dst, sample) in bytes.chunks_exact_mut(4).zip(&feed.scratch) {
                dst.copy_from_slice(&sample.to_le_bytes());
            }
        } else {
            for (dst, sample) in bytes.chunks_exact_mut(4).zip(a.iter().chain(b)) {
                dst.copy_from_slice(&sample.to_le_bytes());
            }
        }
        chunk.commit_all();
    }
    bytes[available * 4..wanted * 4].fill(0);

    if available < wanted {
        feed.shared.underruns.fetch_add(1, Relaxed);
    }
    feed.shared.frames_played.fetch_add((available / feed.channels) as u64, Relaxed);
    if let Ok(time) = stream.time() {
        let rate = time.rate();
        if rate.num == 1 && rate.denom > 0 {
            feed.shared.device_rate.store(rate.denom, Relaxed);
        }
    }

    let chunk = data.chunk_mut();
    *chunk.offset_mut() = 0;
    *chunk.stride_mut() = stride as _;
    *chunk.size_mut() = (wanted * 4) as _;
}

fn positions(channels: usize) -> [u32; MAX_CHANNELS] {
    use spa::sys::*;
    let layout: &[u32] = match channels {
        1 => &[SPA_AUDIO_CHANNEL_MONO],
        2 => &[SPA_AUDIO_CHANNEL_FL, SPA_AUDIO_CHANNEL_FR],
        // The WAV/FLAC channel orders.
        6 => &[
            SPA_AUDIO_CHANNEL_FL,
            SPA_AUDIO_CHANNEL_FR,
            SPA_AUDIO_CHANNEL_FC,
            SPA_AUDIO_CHANNEL_LFE,
            SPA_AUDIO_CHANNEL_RL,
            SPA_AUDIO_CHANNEL_RR,
        ],
        8 => &[
            SPA_AUDIO_CHANNEL_FL,
            SPA_AUDIO_CHANNEL_FR,
            SPA_AUDIO_CHANNEL_FC,
            SPA_AUDIO_CHANNEL_LFE,
            SPA_AUDIO_CHANNEL_RL,
            SPA_AUDIO_CHANNEL_RR,
            SPA_AUDIO_CHANNEL_SL,
            SPA_AUDIO_CHANNEL_SR,
        ],
        _ => &[],
    };
    let mut out = [0; MAX_CHANNELS];
    for (i, slot) in out.iter_mut().enumerate().take(channels.min(MAX_CHANNELS)) {
        *slot = layout.get(i).copied().unwrap_or(SPA_AUDIO_CHANNEL_AUX0 + i as u32);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_allowed_rates() {
        let mut s = Settings::default();
        s.apply("clock.rate", Some("48000"));
        s.apply("clock.allowed-rates", Some("[ 96000, 44100 48000 ]"));
        assert_eq!(s.rates(), vec![44100, 48000, 96000]);
        s.apply("clock.force-rate", Some("96000"));
        assert_eq!(s.rates(), vec![96000]);
    }
}
