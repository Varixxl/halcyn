//! The sound settings: volume and the equalizer. They run on the output's audio thread, so
//! a change is heard within one buffer instead of after the ring's second of lookahead.
//!
//! At full volume with the EQ off the stage is skipped entirely and the output stays
//! bit-exact. Otherwise each sample goes through the filters in f64 and is dithered back to
//! 24 bits (TPDF), like the resampler's output.

use std::sync::atomic::{AtomicU64, Ordering::Acquire, Ordering::Release};
use std::sync::Mutex;

use super::convert::Tpdf;

/// Room for a headphone correction (10), the 10 bands, bass and treble.
pub const MAX_FILTERS: usize = 32;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Kind {
    Peak,
    LowShelf,
    HighShelf,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Filter {
    pub kind: Kind,
    pub hz: f64,
    pub gain_db: f64,
    pub q: f64,
}

/// Everything the audio thread needs, with no heap, so it can be copied in without
/// allocating.
#[derive(Clone, Copy, Debug)]
pub struct Design {
    /// Linear gain applied before the filters: the volume times the EQ's pre-gain.
    pub gain: f64,
    pub filters: [Filter; MAX_FILTERS],
    pub count: usize,
}

impl Default for Design {
    fn default() -> Self {
        let none = Filter { kind: Kind::Peak, hz: 1000.0, gain_db: 0.0, q: 1.0 };
        Design { gain: 1.0, filters: [none; MAX_FILTERS], count: 0 }
    }
}

impl Design {
    /// `filters` with no effect (0 dB) are left out; past MAX_FILTERS the rest are dropped.
    pub fn new(gain: f64, filters: &[Filter]) -> Self {
        let mut design = Design { gain, ..Design::default() };
        for f in filters.iter().filter(|f| f.gain_db != 0.0).take(MAX_FILTERS) {
            design.filters[design.count] = *f;
            design.count += 1;
        }
        design
    }

    /// Whether the samples need touching at all.
    pub fn active(&self) -> bool {
        self.gain != 1.0 || self.count > 0
    }
}

/// Hands the latest design from the engine to the audio thread without ever blocking it.
#[derive(Default)]
pub struct Control {
    generation: AtomicU64,
    design: Mutex<Design>,
}

impl Control {
    pub fn set(&self, design: Design) {
        *self.design.lock().unwrap() = design;
        self.generation.fetch_add(1, Release);
    }

    pub fn get(&self) -> Design {
        *self.design.lock().unwrap()
    }
}

#[derive(Clone, Copy, Default)]
struct Coefficients {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
}

impl Coefficients {
    /// The RBJ cookbook, the same formulas libavfilter's equalizer and shelves use.
    fn new(f: &Filter, rate: f64) -> Self {
        let a = 10f64.powf(f.gain_db / 40.0);
        let w0 = std::f64::consts::TAU * f.hz.min(rate * 0.49) / rate;
        let (cw, alpha) = (w0.cos(), w0.sin() / (2.0 * f.q));
        let (b, d) = match f.kind {
            Kind::Peak => (
                [1.0 + alpha * a, -2.0 * cw, 1.0 - alpha * a],
                [1.0 + alpha / a, -2.0 * cw, 1.0 - alpha / a],
            ),
            Kind::LowShelf | Kind::HighShelf => {
                let sa = 2.0 * a.sqrt() * alpha;
                // The high shelf is the low one mirrored.
                let s = if f.kind == Kind::LowShelf { 1.0 } else { -1.0 };
                (
                    [
                        a * ((a + 1.0) - s * (a - 1.0) * cw + sa),
                        s * 2.0 * a * ((a - 1.0) - s * (a + 1.0) * cw),
                        a * ((a + 1.0) - s * (a - 1.0) * cw - sa),
                    ],
                    [
                        (a + 1.0) + s * (a - 1.0) * cw + sa,
                        -s * 2.0 * ((a - 1.0) + s * (a + 1.0) * cw),
                        (a + 1.0) + s * (a - 1.0) * cw - sa,
                    ],
                )
            }
        };
        Coefficients { b0: b[0] / d[0], b1: b[1] / d[0], b2: b[2] / d[0], a1: d[1] / d[0], a2: d[2] / d[0] }
    }

    /// Gain in dB at `hz`.
    fn db_at(&self, hz: f64, rate: f64) -> f64 {
        let w = std::f64::consts::TAU * hz / rate;
        let (c1, s1, c2, s2) = (w.cos(), w.sin(), (2.0 * w).cos(), (2.0 * w).sin());
        let num = ((self.b0 + self.b1 * c1 + self.b2 * c2).powi(2) + (self.b1 * s1 + self.b2 * s2).powi(2)).sqrt();
        let den = ((1.0 + self.a1 * c1 + self.a2 * c2).powi(2) + (self.a1 * s1 + self.a2 * s2).powi(2)).sqrt();
        20.0 * (num / den).log10()
    }
}

/// The combined response of `filters`, in dB at each of `freqs`.
pub fn response(filters: &[Filter], freqs: &[f64]) -> Vec<f64> {
    const RATE: f64 = 48_000.0;
    let coefficients: Vec<_> = filters.iter().map(|f| Coefficients::new(f, RATE)).collect();
    freqs.iter().map(|&hz| coefficients.iter().map(|c| c.db_at(hz, RATE)).sum()).collect()
}

/// `n` frequencies spread evenly on a log scale from 20 Hz to 20 kHz.
pub fn log_freqs(n: usize) -> Vec<f64> {
    (0..n).map(|i| 20.0 * 1000f64.powf(i as f64 / (n - 1) as f64)).collect()
}

/// The cut that keeps the EQ's biggest boost from clipping: dB, 0 or below, in 0.1 dB steps.
pub fn preamp_db(filters: &[Filter]) -> f64 {
    let peak = response(filters, &log_freqs(300)).into_iter().fold(0.0, f64::max);
    -(peak * 10.0).ceil() / 10.0
}

/// One stream's filters and their state. Lives on the audio thread.
pub struct Chain {
    rate: f64,
    channels: usize,
    generation: u64,
    design: Design,
    coefficients: [Coefficients; MAX_FILTERS],
    /// Per channel, per filter: the two delay values (transposed direct form II).
    state: Vec<[f64; 2]>,
    dither: Tpdf,
}

impl Chain {
    pub fn new(control: &Control, rate: u32, channels: usize) -> Self {
        let mut chain = Chain {
            rate: rate as f64,
            channels,
            generation: u64::MAX,
            design: Design::default(),
            coefficients: [Coefficients::default(); MAX_FILTERS],
            state: vec![[0.0; 2]; channels * MAX_FILTERS],
            dither: Tpdf::new(),
        };
        chain.refresh(control);
        chain
    }

    /// Picks up a new design if there is one. Never blocks: if the engine is mid-update,
    /// the old design plays on for one more buffer.
    fn refresh(&mut self, control: &Control) {
        let generation = control.generation.load(Acquire);
        if generation == self.generation {
            return;
        }
        let Ok(design) = control.design.try_lock() else { return };
        let design = *design;
        // Keep the filters' state when only the gains moved, so dragging a slider doesn't click.
        let same_shape = design.count == self.design.count
            && design.filters[..design.count]
                .iter()
                .zip(&self.design.filters[..self.design.count])
                .all(|(a, b)| a.kind == b.kind && a.hz == b.hz);
        if !same_shape {
            self.state.iter_mut().for_each(|s| *s = [0.0; 2]);
        }
        for (c, f) in self.coefficients.iter_mut().zip(&design.filters[..design.count]) {
            *c = Coefficients::new(f, self.rate);
        }
        self.design = design;
        self.generation = generation;
    }

    /// Whether samples need to go through `process`, after picking up any new design.
    pub fn active(&mut self, control: &Control) -> bool {
        self.refresh(control);
        self.design.active()
    }

    /// Applies volume and EQ to interleaved full-scale samples in place.
    pub fn process(&mut self, control: &Control, samples: &mut [i32]) {
        self.refresh(control);
        if !self.design.active() {
            return;
        }
        const SCALE: f64 = 1.0 / 2_147_483_648.0;
        let (count, channels, gain) = (self.design.count, self.channels, self.design.gain);
        for frame in samples.chunks_exact_mut(channels) {
            for (ch, sample) in frame.iter_mut().enumerate() {
                let mut x = *sample as f64 * SCALE * gain;
                let state = &mut self.state[ch * MAX_FILTERS..ch * MAX_FILTERS + count];
                for (c, z) in self.coefficients[..count].iter().zip(state) {
                    let y = c.b0 * x + z[0];
                    z[0] = c.b1 * x - c.a1 * y + z[1];
                    z[1] = c.b2 * x - c.a2 * y;
                    x = y;
                }
                *sample = self.dither.quantize(x);
            }
        }
        // Silence decays towards denormals, which are slow; snap them to zero.
        for z in &mut self.state {
            for v in z {
                if v.abs() < 1e-30 {
                    *v = 0.0;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn peak(hz: f64, gain_db: f64) -> Filter {
        Filter { kind: Kind::Peak, hz, gain_db, q: 1.41 }
    }

    #[test]
    fn response_matches_the_gains() {
        let filters = [
            peak(1000.0, 6.0),
            Filter { kind: Kind::LowShelf, hz: 100.0, gain_db: 12.0, q: 0.71 },
            Filter { kind: Kind::HighShelf, hz: 8000.0, gain_db: -4.0, q: 0.71 },
        ];
        let r = response(&filters, &[20.0, 1000.0, 20000.0]);
        assert!((r[0] - 12.0).abs() < 0.5, "bass shelf: {}", r[0]);
        assert!((r[1] - 6.0).abs() < 0.3, "peak: {}", r[1]);
        assert!((r[2] + 4.0).abs() < 0.5, "treble shelf: {}", r[2]);
        assert!((preamp_db(&filters) + 12.0).abs() < 0.3);
        assert_eq!(preamp_db(&[peak(1000.0, -6.0)]), 0.0);
    }

    #[test]
    fn bypassed_when_flat_and_at_full_volume() {
        let control = Control::default();
        control.set(Design::new(1.0, &[peak(1000.0, 0.0)]));
        let mut chain = Chain::new(&control, 48_000, 2);
        let original: Vec<i32> = (0..960).map(|i| (i * 1_234_567) as i32).collect();
        let mut samples = original.clone();
        chain.process(&control, &mut samples);
        assert_eq!(samples, original, "bit-exact");
    }

    #[test]
    fn volume_and_eq_change_the_level() {
        let control = Control::default();
        let mut chain = Chain::new(&control, 48_000, 1);
        let tone = |hz: f64| -> Vec<i32> {
            (0..48_000).map(|i| ((std::f64::consts::TAU * hz * i as f64 / 48_000.0).sin() * 0.25 * 2_147_483_647.0) as i32).collect()
        };
        let rms = |s: &[i32]| (s[24_000..].iter().map(|&v| (v as f64 / 2_147_483_648.0).powi(2)).sum::<f64>() / 24_000.0).sqrt();
        let before = rms(&tone(1000.0));

        // Half volume: -6 dB.
        control.set(Design::new(0.5, &[]));
        let mut s = tone(1000.0);
        chain.process(&control, &mut s);
        assert!((20.0 * (rms(&s) / before).log10() + 6.02).abs() < 0.05);

        // +6 dB at 1 kHz.
        control.set(Design::new(1.0, &[peak(1000.0, 6.0)]));
        let mut s = tone(1000.0);
        chain.process(&control, &mut s);
        assert!((20.0 * (rms(&s) / before).log10() - 6.0).abs() < 0.1);
    }
}
