//! Pitch and speed, apart: the pitch moves without the song speeding up, and the speed
//! changes without the pitch moving. Signalsmith Stretch (vendor/signalsmith, C++) does the
//! work; with both at their defaults it isn't in the path at all and playback stays
//! bit-exact.

use std::ffi::c_void;

use super::convert::Tpdf;

extern "C" {
    fn halcyn_stretch_new(channels: i32, rate: f32) -> *mut c_void;
    fn halcyn_stretch_free(h: *mut c_void);
    fn halcyn_stretch_input_latency(h: *mut c_void) -> usize;
    fn halcyn_stretch_output_latency(h: *mut c_void) -> usize;
    fn halcyn_stretch_set_semitones(h: *mut c_void, semitones: f32);
    fn halcyn_stretch_process(h: *mut c_void, input: *const f32, in_frames: usize, out: *mut f32, out_frames: usize);
    fn halcyn_stretch_seek(h: *mut c_void, input: *const f32, in_frames: usize, speed: f64);
    fn halcyn_stretch_flush(h: *mut c_void, out: *mut f32, out_frames: usize);
}

/// How far each setting goes.
pub const MAX_SEMITONES: f64 = 12.0;
pub const MIN_SPEED: f64 = 0.5;
pub const MAX_SPEED: f64 = 2.0;

/// The pitch, in semitones, and the speed, as a multiple.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Tempo {
    pub semitones: f64,
    pub speed: f64,
}

impl Default for Tempo {
    fn default() -> Self {
        Tempo { semitones: 0.0, speed: 1.0 }
    }
}

impl Tempo {
    pub fn new(semitones: f64, speed: f64) -> Self {
        // Tiny steps are none: a slider left a hair off the middle stays bit-exact.
        let semitones = (semitones.clamp(-MAX_SEMITONES, MAX_SEMITONES) * 100.0).round() / 100.0;
        let speed = (speed.clamp(MIN_SPEED, MAX_SPEED) * 100.0).round() / 100.0;
        Tempo { semitones, speed }
    }

    pub fn active(&self) -> bool {
        *self != Tempo::default()
    }

    /// For the signal path, e.g. "Pitch +2 · Speed 1.25×".
    pub fn label(&self) -> Option<String> {
        let mut parts = Vec::new();
        if self.semitones != 0.0 {
            let n = self.semitones;
            let text = if n.fract() == 0.0 { format!("{n:+.0}") } else { format!("{n:+.1}") };
            parts.push(format!("Pitch {text}"));
        }
        if self.speed != 1.0 {
            parts.push(format!("Speed {}×", self.speed));
        }
        (!parts.is_empty()).then(|| parts.join(" · "))
    }
}

/// One session's stretcher: interleaved full-scale samples in, the same out, pitched and
/// with `1 / speed` as many frames.
pub struct Stretch {
    handle: *mut c_void,
    channels: usize,
    speed: f64,
    /// Input held back until there's enough to prime the stretcher (its input latency).
    priming: Option<Vec<f32>>,
    /// Output frames owed: the fraction left over from each block.
    owed: f64,
    input: Vec<f32>,
    output: Vec<f32>,
    dither: Tpdf,
}

// The handle is only used from the engine thread that owns the session.
unsafe impl Send for Stretch {}

impl Drop for Stretch {
    fn drop(&mut self) {
        unsafe { halcyn_stretch_free(self.handle) }
    }
}

const SCALE: f32 = 1.0 / 2_147_483_648.0;

impl Stretch {
    pub fn new(tempo: Tempo, rate: u32, channels: usize) -> Self {
        let handle = unsafe { halcyn_stretch_new(channels as i32, rate as f32) };
        unsafe { halcyn_stretch_set_semitones(handle, tempo.semitones as f32) };
        Stretch {
            handle,
            channels,
            speed: tempo.speed,
            priming: Some(Vec::new()),
            owed: 0.0,
            input: Vec::new(),
            output: Vec::new(),
            dither: Tpdf::new(),
        }
    }

    /// Replaces `block` with what it becomes. Early on that can be nothing, while the
    /// stretcher fills up.
    pub fn process(&mut self, block: &mut Vec<i32>) {
        self.input.clear();
        self.input.extend(block.iter().map(|&s| s as f32 * SCALE));
        block.clear();
        if let Some(priming) = &mut self.priming {
            priming.extend_from_slice(&self.input);
            let need = unsafe { halcyn_stretch_input_latency(self.handle) } * self.channels;
            if priming.len() < need {
                return;
            }
            // The first `need` samples prime it, so its output starts with the song's
            // start instead of a fade-in; the rest go through as usual.
            let priming = self.priming.take().unwrap();
            let (head, rest) = priming.split_at(need);
            unsafe { halcyn_stretch_seek(self.handle, head.as_ptr(), need / self.channels, self.speed) };
            self.input = rest.to_vec();
        }
        let frames = self.input.len() / self.channels;
        self.owed += frames as f64 / self.speed;
        let out_frames = self.owed.floor() as usize;
        self.owed -= out_frames as f64;
        self.output.resize(out_frames * self.channels, 0.0);
        unsafe {
            halcyn_stretch_process(self.handle, self.input.as_ptr(), frames, self.output.as_mut_ptr(), out_frames)
        };
        self.quantize(block);
    }

    /// The end of the song: what's still inside the stretcher.
    pub fn finish(&mut self, block: &mut Vec<i32>) {
        block.clear();
        if let Some(priming) = self.priming.take() {
            // A song shorter than the latency: it goes through whole, all at once.
            let mut short = priming.iter().map(|&s| (s / SCALE) as i32).collect();
            self.priming = None;
            self.process(&mut short);
            block.extend(short);
        }
        let frames = unsafe { halcyn_stretch_output_latency(self.handle) };
        self.output.resize(frames * self.channels, 0.0);
        unsafe { halcyn_stretch_flush(self.handle, self.output.as_mut_ptr(), frames) };
        let mut tail = Vec::new();
        self.quantize(&mut tail);
        block.extend(tail);
    }

    fn quantize(&mut self, block: &mut Vec<i32>) {
        block.extend(self.output.iter().map(|&s| self.dither.quantize(s as f64)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: u32 = 48_000;

    fn tone(hz: f64, secs: f64) -> Vec<i32> {
        (0..(RATE as f64 * secs) as usize)
            .flat_map(|i| {
                let v = ((std::f64::consts::TAU * hz * i as f64 / RATE as f64).sin() * 0.5 * 2_147_483_647.0) as i32;
                [v, v]
            })
            .collect()
    }

    /// Through the stretcher in blocks, as the engine does.
    fn run(tempo: Tempo, input: &[i32]) -> Vec<i32> {
        let mut stretch = Stretch::new(tempo, RATE, 2);
        let mut out = Vec::new();
        for chunk in input.chunks(2048) {
            let mut block = chunk.to_vec();
            stretch.process(&mut block);
            out.extend(block);
        }
        let mut block = Vec::new();
        stretch.finish(&mut block);
        out.extend(block);
        out
    }

    /// The tone's frequency, from its zero crossings in the middle of the output.
    fn frequency(samples: &[i32]) -> f64 {
        let left: Vec<i32> = samples.iter().step_by(2).copied().collect();
        let middle = &left[left.len() / 4..left.len() * 3 / 4];
        let crossings = middle.windows(2).filter(|w| w[0] < 0 && w[1] >= 0).count();
        crossings as f64 * RATE as f64 / middle.len() as f64
    }

    #[test]
    fn pitch_moves_without_the_length_changing() {
        let input = tone(440.0, 3.0);
        let out = run(Tempo::new(12.0, 1.0), &input);
        let ratio = out.len() as f64 / input.len() as f64;
        assert!((ratio - 1.0).abs() < 0.03, "length ratio {ratio}");
        let hz = frequency(&out);
        assert!((hz - 880.0).abs() < 15.0, "an octave up: {hz} Hz");
    }

    #[test]
    fn speed_changes_without_the_pitch_moving() {
        let input = tone(440.0, 3.0);
        let out = run(Tempo::new(0.0, 1.5), &input);
        let ratio = out.len() as f64 / input.len() as f64;
        assert!((ratio - 1.0 / 1.5).abs() < 0.03, "length ratio {ratio}");
        let hz = frequency(&out);
        assert!((hz - 440.0).abs() < 10.0, "same pitch: {hz} Hz");
    }

    #[test]
    fn a_hair_off_the_middle_is_none() {
        assert!(!Tempo::new(0.001, 1.0004).active());
        assert_eq!(Tempo::new(2.0, 1.25).label().as_deref(), Some("Pitch +2 · Speed 1.25×"));
        assert_eq!(Tempo::new(-0.5, 1.0).label().as_deref(), Some("Pitch -0.5"));
    }
}
