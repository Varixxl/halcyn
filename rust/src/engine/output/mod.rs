//! Audio outputs. Each backend plays interleaved full-scale i32 from a ring buffer.

use std::sync::atomic::Ordering::Relaxed;
use std::sync::atomic::{AtomicU32, AtomicU64};
use std::sync::{Arc, OnceLock};
use std::time::Instant;

use anyhow::Result;

use super::dsp;

mod cpal_output;
#[cfg(target_os = "linux")]
mod pipewire;

/// What an output can play right now.
#[derive(Clone, Debug)]
pub struct Caps {
    pub backend: &'static str,
    /// Rates the output can run at without resampling, ascending.
    pub rates: Vec<u32>,
}

/// Counters the output's audio thread updates.
#[derive(Default)]
pub struct Shared {
    pub frames_played: AtomicU64,
    pub underruns: AtomicU64,
    /// The rate the device side actually runs at, once known (0 before).
    pub device_rate: AtomicU32,
    /// Volume and EQ, applied on the audio thread.
    pub dsp: Arc<dsp::Control>,
    /// When the session's first frame was (or would have been) heard, in `now_nanos` time;
    /// 0 when the output can't tell. Lets `heard` follow the speakers between callbacks
    /// and past the device's own buffering.
    pub origin_nanos: AtomicU64,
}

impl Shared {
    /// Called by the audio callback before it adds this callback's frames: they reach the
    /// speakers `latency` from now.
    pub fn mark_heard(&self, latency: std::time::Duration) {
        let rate = self.device_rate.load(Relaxed) as u128;
        if rate == 0 {
            return;
        }
        // A latency this large is a broken timestamp, not a real device: fall back to
        // following the callbacks rather than drawing seconds behind.
        if latency.as_millis() > MAX_HEARD_LAG_MS {
            self.origin_nanos.store(0, Relaxed);
            return;
        }
        let played = self.frames_played.load(Relaxed) as u128;
        let at = now_nanos() as u128 + latency.as_nanos();
        let origin = at.saturating_sub(played * 1_000_000_000 / rate);
        self.origin_nanos.store(origin.max(1) as u64, Relaxed);
    }

    /// The frame coming out of the speakers right now, as near as the output can say.
    pub fn heard(&self) -> u64 {
        let played = self.frames_played.load(Relaxed);
        let origin = self.origin_nanos.load(Relaxed);
        let rate = self.device_rate.load(Relaxed) as u128;
        if origin == 0 || rate == 0 {
            return played;
        }
        let since = now_nanos().saturating_sub(origin) as u128;
        // Never trail the callbacks by more than MAX_HEARD_LAG_MS, whatever the device
        // claims: the visualizer's history only reaches so far back.
        let floor = played.saturating_sub((rate * MAX_HEARD_LAG_MS / 1000) as u64);
        ((since * rate / 1_000_000_000) as u64).clamp(floor, played)
    }
}

/// How far behind the callbacks `Shared::heard` may report, in milliseconds. Bluetooth
/// outputs can claim several hundred; anything past this is treated as a bad timestamp.
pub const MAX_HEARD_LAG_MS: u128 = 1000;

/// Nanoseconds on a monotonic clock shared by the audio and engine threads. Starts an hour
/// in, so an origin computed back from a burst of early callbacks can't underflow.
pub fn now_nanos() -> u64 {
    const START: u64 = 3_600 * 1_000_000_000;
    static EPOCH: OnceLock<Instant> = OnceLock::new();
    START + EPOCH.get_or_init(Instant::now).elapsed().as_nanos() as u64
}

pub trait Output: Send {
    fn caps(&self) -> Caps;
    /// Starts a stream at `rate` that plays everything pushed into `ring`, or holds it if `paused`.
    fn open(
        &mut self,
        rate: u32,
        channels: usize,
        ring: rtrb::Consumer<i32>,
        shared: Arc<Shared>,
        paused: bool,
    ) -> Result<()>;
    fn set_paused(&mut self, paused: bool) -> Result<()>;
    fn close(&mut self);
}

/// PipeWire on Linux (ALSA through cpal if PipeWire isn't running), WASAPI on Windows,
/// AAudio on Android.
pub fn open_default() -> Result<Box<dyn Output>> {
    #[cfg(target_os = "linux")]
    if let Ok(output) = pipewire::PipeWireOutput::new() {
        return Ok(Box::new(output));
    }
    Ok(Box::new(cpal_output::CpalOutput::new()?))
}

/// Picks the output rate for a source: its own rate when the output supports it, otherwise
/// the lowest supported rate above it (so nothing is cut off), otherwise the highest.
pub fn choose_rate(source_rate: u32, caps: &Caps) -> u32 {
    if caps.rates.contains(&source_rate) {
        return source_rate;
    }
    caps.rates
        .iter()
        .copied()
        .find(|&r| r > source_rate)
        .or_else(|| caps.rates.last().copied())
        .unwrap_or(source_rate)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn caps(rates: &[u32]) -> Caps {
        Caps { backend: "test", rates: rates.to_vec() }
    }

    #[test]
    fn keeps_supported_rates() {
        assert_eq!(choose_rate(44100, &caps(&[44100, 48000])), 44100);
    }

    #[test]
    fn goes_up_to_the_next_rate() {
        assert_eq!(choose_rate(44100, &caps(&[48000])), 48000);
        assert_eq!(choose_rate(88200, &caps(&[48000, 96000, 192000])), 96000);
    }

    #[test]
    fn falls_back_to_the_highest_rate() {
        assert_eq!(choose_rate(192000, &caps(&[48000, 96000])), 96000);
    }
}

#[cfg(test)]
mod heard_tests {
    use super::*;
    use std::time::Duration;

    fn shared(rate: u32, played: u64) -> Shared {
        let s = Shared::default();
        s.device_rate.store(rate, Relaxed);
        s.frames_played.store(played, Relaxed);
        s
    }

    #[test]
    fn follows_a_normal_latency() {
        let s = shared(48_000, 96_000);
        s.mark_heard(Duration::from_millis(100));
        let lag = 96_000 - s.heard();
        assert!((4_000..=4_900).contains(&lag), "lag {lag}");
    }

    #[test]
    fn ignores_an_absurd_latency() {
        let s = shared(48_000, 480_000);
        s.mark_heard(Duration::from_millis(100));
        s.mark_heard(Duration::from_secs(5));
        assert_eq!(s.heard(), 480_000);
    }

    #[test]
    fn never_trails_past_the_cap() {
        let s = shared(48_000, 480_000);
        s.mark_heard(Duration::from_millis(900));
        s.frames_played.store(960_000, Relaxed);
        assert!(s.heard() >= 960_000 - 48_000);
    }

    #[test]
    fn falls_back_without_timestamps() {
        let s = shared(48_000, 1234);
        assert_eq!(s.heard(), 1234);
    }
}
