//! Audio outputs. Each backend plays interleaved full-scale i32 from a ring buffer.

use std::sync::atomic::{AtomicU32, AtomicU64};
use std::sync::Arc;

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
