//! The visualizer: band levels of what's leaving for the speakers right now. It reads a copy
//! of the samples already handed to the output, so the audio itself is never touched.

use std::collections::VecDeque;
use std::sync::Arc;

use realfft::num_complex::Complex;
use realfft::{RealFftPlanner, RealToComplex};

pub const BANDS: usize = 64;
const LOW_HZ: f32 = 40.0;
const HIGH_HZ: f32 = 14_000.0;
/// The level range mapped onto 0..1.
const FLOOR_DB: f32 = -80.0;
const CEIL_DB: f32 = -10.0;
/// Lifts the highs, so music's natural fall-off doesn't leave the right side flat.
const TILT_DB_PER_OCTAVE: f32 = 4.5;

/// The most recent samples sent to the output, interleaved, so the analyser can pick out the
/// ones playing now. The ring runs about a second ahead of the speakers.
pub struct History {
    samples: VecDeque<f32>,
    capacity: usize,
    /// Session sample index just past the newest sample held.
    end: u64,
}

impl History {
    pub fn new(capacity: usize) -> Self {
        History { samples: VecDeque::with_capacity(capacity), capacity, end: 0 }
    }

    /// Appends samples that end at session sample index `end`.
    pub fn push(&mut self, samples: &[i32], end: u64) {
        const SCALE: f32 = 1.0 / 2_147_483_648.0;
        self.samples.extend(samples.iter().map(|&s| s as f32 * SCALE));
        let over = self.samples.len().saturating_sub(self.capacity);
        self.samples.drain(..over);
        self.end = end;
    }

    /// The `len` samples ending at session sample `end`, if they're still held.
    fn window(&self, end: u64, len: usize) -> Option<impl Iterator<Item = f32> + '_> {
        let start = self.end - self.samples.len() as u64;
        if end > self.end || end < start + len as u64 {
            return None;
        }
        let from = (end - len as u64 - start) as usize;
        Some(self.samples.range(from..from + len).copied())
    }
}

pub struct Analyzer {
    pub rate: u32,
    pub channels: usize,
    fft: Arc<dyn RealToComplex<f32>>,
    window: Vec<f32>,
    input: Vec<f32>,
    output: Vec<Complex<f32>>,
    scratch: Vec<Complex<f32>>,
    /// Each band's edges in FFT bins.
    bands: Vec<(f32, f32)>,
    /// Per band: the tilt, plus the scale that puts a full-scale sine at 0 dB.
    offsets_db: Vec<f32>,
}

impl Analyzer {
    pub fn new(rate: u32, channels: usize) -> Self {
        // About 85 ms of audio: fine enough for the bass, quick enough to follow the beat.
        let size = ((rate as f32 * 0.085) as usize).next_power_of_two();
        let fft = RealFftPlanner::<f32>::new().plan_fft_forward(size);
        let window: Vec<f32> = (0..size)
            .map(|i| 0.5 - 0.5 * (std::f32::consts::TAU * i as f32 / size as f32).cos())
            .collect();
        let gain = 2.0 / window.iter().sum::<f32>();

        let high = HIGH_HZ.min(rate as f32 * 0.45);
        let per_bin = rate as f32 / size as f32;
        let edge = |i: usize| LOW_HZ * (high / LOW_HZ).powf(i as f32 / BANDS as f32);
        let bands: Vec<(f32, f32)> =
            (0..BANDS).map(|i| (edge(i) / per_bin, edge(i + 1) / per_bin)).collect();
        let offsets_db = (0..BANDS)
            .map(|i| {
                let centre = (edge(i) * edge(i + 1)).sqrt();
                20.0 * gain.log10() + TILT_DB_PER_OCTAVE * (centre / 1000.0).log2()
            })
            .collect();

        Analyzer {
            rate,
            channels,
            input: fft.make_input_vec(),
            output: fft.make_output_vec(),
            scratch: fft.make_scratch_vec(),
            fft,
            window,
            bands,
            offsets_db,
        }
    }

    /// Band levels, 0..1, for the audio ending at session frame `frame`.
    pub fn analyse(&mut self, history: &History, frame: u64) -> Option<Vec<f32>> {
        let size = self.window.len();
        let channels = self.channels;
        let samples = history.window(frame * channels as u64, size * channels)?;

        // Mono: the average of the channels.
        let scale = 1.0 / channels as f32;
        self.input.fill(0.0);
        for (i, sample) in samples.enumerate() {
            self.input[i / channels] += sample * scale;
        }
        for (x, w) in self.input.iter_mut().zip(&self.window) {
            *x *= w;
        }
        self.fft.process_with_scratch(&mut self.input, &mut self.output, &mut self.scratch).ok()?;

        let magnitude = |bin: f32| {
            // Linear between bins, for bass bands narrower than one bin.
            let i = (bin.floor() as usize).min(self.output.len() - 2);
            let t = (bin - i as f32).clamp(0.0, 1.0);
            self.output[i].norm() * (1.0 - t) + self.output[i + 1].norm() * t
        };
        Some(
            self.bands
                .iter()
                .zip(&self.offsets_db)
                .map(|(&(lo, hi), offset)| {
                    let peak = if hi - lo < 1.0 {
                        magnitude((lo + hi) / 2.0)
                    } else {
                        let last = (hi.ceil() as usize).min(self.output.len() - 1);
                        self.output[lo.floor() as usize..=last]
                            .iter()
                            .map(|c| c.norm())
                            .fold(0.0, f32::max)
                    };
                    let db = 20.0 * peak.max(1e-9).log10() + offset;
                    ((db - FLOOR_DB) / (CEIL_DB - FLOOR_DB)).clamp(0.0, 1.0)
                })
                .collect(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(rate: u32, hz: f32, amplitude: f32, frames: usize) -> Vec<i32> {
        (0..frames)
            .flat_map(|i| {
                let s = (std::f32::consts::TAU * hz * i as f32 / rate as f32).sin() * amplitude;
                let v = (s * 2_147_483_647.0) as i32;
                [v, v]
            })
            .collect()
    }

    #[test]
    fn a_tone_lights_its_own_band() {
        let rate = 48_000;
        let mut history = History::new(rate as usize * 2);
        let samples = sine(rate, 1000.0, 0.5, rate as usize);
        history.push(&samples, samples.len() as u64);
        let mut analyzer = Analyzer::new(rate, 2);
        let bands = analyzer.analyse(&history, rate as u64).unwrap();
        let loudest = (0..BANDS).max_by(|&a, &b| bands[a].total_cmp(&bands[b])).unwrap();
        let (lo, hi) = analyzer.bands[loudest];
        let per_bin = rate as f32 / analyzer.window.len() as f32;
        assert!(lo * per_bin <= 1000.0 && 1000.0 <= hi * per_bin, "band {loudest}");
        assert!(bands[loudest] > 0.8);
        assert!(bands[2] < 0.2, "the bass stays dark: {}", bands[2]);
    }

    #[test]
    fn needs_the_samples_to_still_be_there() {
        let mut history = History::new(1000);
        history.push(&[0; 4000], 4000);
        let mut analyzer = Analyzer::new(48_000, 2);
        assert!(analyzer.analyse(&history, 2000).is_none());
    }
}
