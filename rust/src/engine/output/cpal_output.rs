//! Output through cpal: WASAPI on Windows, AAudio on Android. A dedicated thread owns the
//! device and its stream (they aren't Send everywhere); commands reach it over a channel,
//! and the realtime callback pulls samples straight from the ring buffer.
//!
//! Shared-mode WASAPI and Android's mixer each run at one rate. The output reports only
//! that rate, so the engine resamples to it itself and the signal path stays truthful.

use std::sync::atomic::Ordering::Relaxed;
use std::sync::{mpsc, Arc};
use std::thread::JoinHandle;

use anyhow::{anyhow, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{BufferSize, FromSample, SampleFormat, SizedSample, StreamConfig};

use super::super::dsp::Chain;
use super::{Caps, Output, Shared};

/// Rates worth asking a device for, ascending.
const RATES: [u32; 8] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000];

enum Cmd {
    Open {
        rate: u32,
        channels: usize,
        ring: rtrb::Consumer<i32>,
        shared: Arc<Shared>,
        paused: bool,
        reply: mpsc::Sender<Result<()>>,
    },
    Pause(bool, mpsc::Sender<Result<()>>),
    Close,
}

pub struct CpalOutput {
    tx: Option<mpsc::Sender<Cmd>>,
    thread: Option<JoinHandle<()>>,
    caps: Caps,
}

impl CpalOutput {
    pub fn new() -> Result<Self> {
        let (tx, rx) = mpsc::channel();
        let (ready_tx, ready_rx) = mpsc::channel();
        let thread = std::thread::Builder::new()
            .name("halcyn-output".into())
            .spawn(move || run(rx, ready_tx))?;
        let caps = ready_rx.recv().map_err(|_| anyhow!("the audio output thread stopped"))??;
        Ok(CpalOutput { tx: Some(tx), thread: Some(thread), caps })
    }

    fn send(&self, cmd: Cmd) -> Result<()> {
        self.tx
            .as_ref()
            .and_then(|tx| tx.send(cmd).ok())
            .ok_or_else(|| anyhow!("the audio output thread stopped"))
    }
}

impl Output for CpalOutput {
    fn caps(&self) -> Caps {
        self.caps.clone()
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
        result.recv().map_err(|_| anyhow!("the audio output thread stopped"))?
    }

    fn set_paused(&mut self, paused: bool) -> Result<()> {
        let (reply, result) = mpsc::channel();
        self.send(Cmd::Pause(paused, reply))?;
        result.recv().map_err(|_| anyhow!("the audio output thread stopped"))?
    }

    fn close(&mut self) {
        let _ = self.send(Cmd::Close);
    }
}

impl Drop for CpalOutput {
    fn drop(&mut self) {
        // Closing the channel ends the thread's loop.
        self.tx = None;
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn run(rx: mpsc::Receiver<Cmd>, ready: mpsc::Sender<Result<Caps>>) {
    let host = cpal::default_host();
    let Some(device) = host.default_output_device() else {
        let _ = ready.send(Err(anyhow!("no audio output device")));
        return;
    };
    let rates = match supported_rates(&device) {
        Ok(rates) => rates,
        Err(err) => {
            let _ = ready.send(Err(err));
            return;
        }
    };
    let _ = ready.send(Ok(Caps { backend: host.id().name(), rates }));

    let mut stream: Option<cpal::Stream> = None;
    for cmd in rx {
        match cmd {
            Cmd::Open { rate, channels, ring, shared, paused, reply } => {
                stream = None;
                // A panic in the driver shouldn't take the thread down with it.
                let opened = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    open(&device, rate, channels, ring, shared, paused)
                }))
                .unwrap_or_else(|panic| Err(anyhow!("the audio output failed: {}", panic_message(&panic))));
                let _ = reply.send(opened.map(|s| stream = Some(s)));
            }
            Cmd::Pause(paused, reply) => {
                let result = match &stream {
                    Some(s) if paused => s.pause().map_err(|e| anyhow!("pausing: {e}")),
                    Some(s) => s.play().map_err(|e| anyhow!("playing: {e}")),
                    None => Ok(()),
                };
                let _ = reply.send(result);
            }
            Cmd::Close => stream = None,
        }
    }
}

fn panic_message(panic: &Box<dyn std::any::Any + Send>) -> String {
    panic
        .downcast_ref::<&str>()
        .map(|s| s.to_string())
        .or_else(|| panic.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "unknown error".into())
}

fn supported_rates(device: &cpal::Device) -> Result<Vec<u32>> {
    // Android mixes at 48 kHz on practically every phone; resampling there ourselves is
    // better than letting the mixer do it unseen.
    if cfg!(target_os = "android") {
        return Ok(vec![48_000]);
    }
    let configs: Vec<_> = device
        .supported_output_configs()
        .map_err(|e| anyhow!("reading the output's formats: {e}"))?
        .filter(|c| c.channels() >= 2)
        .collect();
    let mut rates: Vec<u32> = RATES
        .into_iter()
        .filter(|&r| configs.iter().any(|c| c.min_sample_rate() <= r && r <= c.max_sample_rate()))
        .collect();
    if rates.is_empty() {
        let default = device
            .default_output_config()
            .map_err(|e| anyhow!("reading the output's format: {e}"))?;
        rates.push(default.sample_rate());
    }
    Ok(rates)
}

fn open(
    device: &cpal::Device,
    rate: u32,
    channels: usize,
    ring: rtrb::Consumer<i32>,
    shared: Arc<Shared>,
    paused: bool,
) -> Result<cpal::Stream> {
    // The deepest format the device takes at this rate: 32-bit int, then float, then 16-bit.
    let formats: Vec<SampleFormat> = device
        .supported_output_configs()
        .map_err(|e| anyhow!("reading the output's formats: {e}"))?
        .filter(|c| c.channels() as usize == channels && c.min_sample_rate() <= rate && rate <= c.max_sample_rate())
        .map(|c| c.sample_format())
        .collect();
    let format = [SampleFormat::I32, SampleFormat::F32, SampleFormat::I16]
        .into_iter()
        .find(|f| formats.contains(f))
        .unwrap_or(SampleFormat::F32);
    let config = StreamConfig { channels: channels as u16, sample_rate: rate, buffer_size: BufferSize::Default };
    shared.device_rate.store(rate, Relaxed);
    let feed = Feed {
        chain: Chain::new(&shared.dsp, rate, channels),
        scratch: Vec::with_capacity(rate as usize * channels),
        ring,
        shared,
        channels,
    };
    let stream = match format {
        SampleFormat::I32 => build::<i32>(device, config, feed),
        SampleFormat::I16 => build::<i16>(device, config, feed),
        _ => build::<f32>(device, config, feed),
    }?;
    if !paused {
        stream.play().map_err(|e| anyhow!("starting the output: {e}"))?;
    }
    Ok(stream)
}

fn build<T: SizedSample + FromSample<i32> + Send + 'static>(
    device: &cpal::Device,
    config: StreamConfig,
    mut feed: Feed,
) -> Result<cpal::Stream> {
    device
        .build_output_stream::<T, _, _>(
            config,
            move |out: &mut [T], info: &cpal::OutputCallbackInfo| {
                let ts = info.timestamp();
                feed.shared.mark_heard(ts.playback.duration_since(ts.callback));
                feed.fill(out)
            },
            |err| eprintln!("audio output: {err}"),
            None,
        )
        .map_err(|e| anyhow!("opening the output: {e}"))
}

struct Feed {
    ring: rtrb::Consumer<i32>,
    shared: Arc<Shared>,
    channels: usize,
    chain: Chain,
    /// Samples on their way out; sized up front so the callback never allocates.
    scratch: Vec<i32>,
}

impl Feed {
    fn fill<T: SizedSample + FromSample<i32>>(&mut self, out: &mut [T]) {
        let channels = self.channels;
        let wanted = out.len() / channels * channels;
        let available = self.ring.slots().min(wanted).min(self.scratch.capacity()) / channels * channels;
        self.scratch.clear();
        if let Ok(chunk) = self.ring.read_chunk(available) {
            let (a, b) = chunk.as_slices();
            self.scratch.extend_from_slice(a);
            self.scratch.extend_from_slice(b);
            chunk.commit_all();
        }
        if self.chain.active(&self.shared.dsp) {
            self.chain.process(&self.shared.dsp, &mut self.scratch);
        }
        for (dst, &sample) in out.iter_mut().zip(&self.scratch) {
            *dst = T::from_sample(sample);
        }
        for dst in &mut out[self.scratch.len()..] {
            *dst = T::EQUILIBRIUM;
        }
        if self.scratch.len() < wanted {
            self.shared.underruns.fetch_add(1, Relaxed);
        }
        self.shared.frames_played.fetch_add((self.scratch.len() / channels) as u64, Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Opens the default device and plays a second of digital silence (zeros only, so it
    /// can't be heard wherever it goes). Run with `--ignored`; needs an audio device.
    #[test]
    #[ignore]
    fn plays_silence_through_the_default_device() {
        let mut output = CpalOutput::new().expect("an output device");
        let caps = output.caps();
        assert!(!caps.rates.is_empty());
        let rate = caps.rates[0];
        let (mut producer, consumer) = rtrb::RingBuffer::new(rate as usize * 2);
        for _ in 0..rate as usize * 2 {
            producer.push(0).unwrap();
        }
        let shared = Arc::new(Shared::default());
        output.open(rate, 2, consumer, shared.clone(), false).expect("a stream");
        std::thread::sleep(std::time::Duration::from_millis(700));
        let played = shared.frames_played.load(Relaxed);
        output.close();
        eprintln!("{}: {played} frames at {rate} Hz, rates {:?}", caps.backend, caps.rates);
        assert!(played > rate as u64 / 4, "the callback ran");
    }
}
