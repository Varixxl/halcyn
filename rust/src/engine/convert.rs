//! Turns decoded audio into the output format: interleaved full-scale i32 at the output rate.
//!
//! When the rates match, samples pass through untouched (bit-exact). Otherwise they are
//! resampled in f64 with rubato's FFT resampler and quantized to 24 bits with TPDF dither.

use anyhow::Result;
use audioadapter_buffers::direct::InterleavedSlice;
use rubato::{Fft, FixedSync, Resampler};

use super::source::{Samples, Source};

/// Input frames per resampler call.
const CHUNK: usize = 1024;
/// The resampled path is dithered to 24 bits, the most any DAC resolves.
const BITS: u32 = 24;

pub struct Converter {
    channels: usize,
    mode: Mode,
}

enum Mode {
    Passthrough,
    Resample(Box<Resampling>),
}

struct Resampling {
    resampler: Fft<f64>,
    source_rate: u64,
    output_rate: u64,
    decoded: Vec<f64>,
    /// Decoded frames waiting for the resampler, interleaved.
    pending: Vec<f64>,
    output: Vec<f64>,
    /// Resampler latency still to drop from the start of the output.
    delay_left: usize,
    frames_in: u64,
    frames_out: u64,
    finished: bool,
    dither: Tpdf,
}

impl Converter {
    pub fn new(source_rate: u32, output_rate: u32, channels: usize) -> Result<Self> {
        let mode = if source_rate == output_rate {
            Mode::Passthrough
        } else {
            let resampler = Fft::<f64>::new(
                source_rate as usize,
                output_rate as usize,
                CHUNK,
                channels,
                FixedSync::Input,
            )?;
            Mode::Resample(Box::new(Resampling {
                delay_left: resampler.output_delay(),
                output: vec![0.0; resampler.output_frames_max() * channels],
                resampler,
                source_rate: source_rate as u64,
                output_rate: output_rate as u64,
                decoded: Vec::new(),
                pending: Vec::new(),
                frames_in: 0,
                frames_out: 0,
                finished: false,
                dither: Tpdf::new(),
            }))
        };
        Ok(Converter { channels, mode })
    }

    pub fn is_passthrough(&self) -> bool {
        matches!(self.mode, Mode::Passthrough)
    }

    /// Samples clipped by the resampler's overshoot so far.
    pub fn clipped(&self) -> u64 {
        match &self.mode {
            Mode::Passthrough => 0,
            Mode::Resample(r) => r.dither.clipped,
        }
    }

    /// Replaces `out` with the next block of output samples. Returns false once the source is
    /// exhausted and everything has been flushed.
    pub fn pull(&mut self, source: &mut Source, out: &mut Vec<i32>) -> Result<bool> {
        out.clear();
        match &mut self.mode {
            Mode::Passthrough => source.read(Samples::Int(out)),
            Mode::Resample(r) => r.pull(source, self.channels, out),
        }
    }
}

impl Resampling {
    fn pull(&mut self, source: &mut Source, channels: usize, out: &mut Vec<i32>) -> Result<bool> {
        while out.is_empty() {
            let need = self.resampler.input_frames_next();
            while !self.finished && self.pending.len() < need * channels {
                if source.read(Samples::Float(&mut self.decoded))? {
                    self.frames_in += (self.decoded.len() / channels) as u64;
                    self.pending.extend_from_slice(&self.decoded);
                } else {
                    self.finished = true;
                }
            }

            // After the last input, pad with silence until the tail is out.
            let expected = (self.frames_in * self.output_rate).div_ceil(self.source_rate);
            if self.finished {
                if self.frames_out >= expected {
                    return Ok(false);
                }
                self.pending.resize(need * channels, 0.0);
            }

            let input = InterleavedSlice::new(&self.pending[..need * channels], channels, need)?;
            let frames = self.resampler.output_frames_next();
            let mut output =
                InterleavedSlice::new_mut(&mut self.output[..frames * channels], channels, frames)?;
            let (_, produced) = self.resampler.process_into_buffer(&input, &mut output, None)?;
            self.pending.drain(..need * channels);

            let start = self.delay_left.min(produced);
            self.delay_left -= start;
            let mut end = produced;
            if self.finished {
                end = end.min(start + (expected - self.frames_out) as usize);
            }
            self.frames_out += (end - start) as u64;
            out.extend(
                self.output[start * channels..end * channels].iter().map(|&s| self.dither.quantize(s)),
            );
        }
        Ok(true)
    }
}

/// Triangular dither (±1 LSB) and rounding to `BITS`, left-aligned in an i32.
pub(super) struct Tpdf {
    state: u64,
    clipped: u64,
}

impl Tpdf {
    pub(super) fn new() -> Self {
        Tpdf { state: 0x9E37_79B9_7F4A_7C15, clipped: 0 }
    }

    fn uniform(&mut self) -> f64 {
        // xorshift64*
        self.state ^= self.state >> 12;
        self.state ^= self.state << 25;
        self.state ^= self.state >> 27;
        (self.state.wrapping_mul(0x2545_F491_4F6C_DD1D) >> 11) as f64 / (1u64 << 53) as f64
    }

    pub(super) fn quantize(&mut self, sample: f64) -> i32 {
        const SCALE: f64 = (1u64 << (BITS - 1)) as f64;
        let value = (sample * SCALE + self.uniform() - self.uniform()).round();
        let clamped = value.clamp(-SCALE, SCALE - 1.0);
        if clamped != value {
            self.clipped += 1;
        }
        (clamped as i32) << (32 - BITS)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dither_stays_within_one_lsb() {
        let mut d = Tpdf::new();
        let lsb = 1i64 << (32 - BITS);
        for i in 0..10_000 {
            let x = (i as f64 / 10_000.0) - 0.5;
            let q = d.quantize(x) as i64;
            let exact = x * (1u64 << 31) as f64;
            assert!((q as f64 - exact).abs() <= 1.5 * lsb as f64);
            assert_eq!(q % lsb, 0);
        }
        assert_eq!(d.clipped, 0);
    }

    #[test]
    fn dither_clips_and_counts_overs() {
        let mut d = Tpdf::new();
        assert_eq!(d.quantize(1.5), ((1i32 << 23) - 1) << 8);
        assert_eq!(d.quantize(-1.5), i32::MIN);
        assert_eq!(d.clipped, 2);
    }
}

/// End-to-end checks of decode + convert against ffmpeg. Skipped when ffmpeg isn't installed.
#[cfg(test)]
mod file_tests {
    use std::path::PathBuf;
    use std::process::Command;

    use super::*;

    fn ffmpeg(args: &[&str]) -> bool {
        Command::new("ffmpeg").args(["-v", "error", "-y"]).args(args).status().is_ok_and(|s| s.success())
    }

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("halcyn-tests-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join(name)
    }

    fn convert_all(path: &PathBuf, output_rate: u32) -> (Vec<i32>, usize) {
        let mut source = Source::open(path).unwrap();
        let channels = source.info.channels;
        let mut converter = Converter::new(source.info.sample_rate, output_rate, channels).unwrap();
        let (mut all, mut block) = (Vec::new(), Vec::new());
        while converter.pull(&mut source, &mut block).unwrap() {
            all.extend_from_slice(&block);
        }
        (all, channels)
    }

    #[test]
    fn passthrough_matches_ffmpeg_bit_for_bit() {
        let flac = temp("noise24.flac");
        let raw = temp("noise24.raw");
        if !ffmpeg(&["-f", "lavfi", "-i", "anoisesrc=r=48000:a=0.5:d=3", "-ac", "2", "-sample_fmt", "s32", "-c:a", "flac", "-bits_per_raw_sample", "24", flac.to_str().unwrap()]) {
            eprintln!("ffmpeg missing, skipped");
            return;
        }
        assert!(ffmpeg(&["-i", flac.to_str().unwrap(), "-f", "s32le", "-c:a", "pcm_s32le", raw.to_str().unwrap()]));
        let expected: Vec<i32> = std::fs::read(&raw)
            .unwrap()
            .chunks_exact(4)
            .map(|b| i32::from_le_bytes(b.try_into().unwrap()))
            .collect();

        let (ours, _) = convert_all(&flac, 48000);
        assert_eq!(ours.len(), expected.len());
        assert!(ours == expected, "decoded samples differ from ffmpeg");
    }

    #[test]
    fn resampling_is_accurate_and_aligned() {
        let flac = temp("sine441.flac");
        // 997 Hz at -6 dBFS, 2 s, stereo, computed in double and stored as 24-bit.
        let sine = "aevalsrc=0.5*sin(2*PI*997*t)|0.5*sin(2*PI*997*t):s=44100:d=2";
        if !ffmpeg(&["-f", "lavfi", "-i", sine, "-sample_fmt", "s32", "-c:a", "flac", "-bits_per_raw_sample", "24", flac.to_str().unwrap()]) {
            eprintln!("ffmpeg missing, skipped");
            return;
        }
        let (ours, channels) = convert_all(&flac, 48000);
        let frames = ours.len() / channels;
        assert_eq!(frames, 96000, "2 s at 48 kHz");

        // Compare against the ideal sine at 48 kHz, away from the edges. Any leftover resampler
        // delay would show up as a big phase error here.
        let amplitude = 0.5;
        let mut err = 0.0f64;
        let mut n = 0;
        for i in 4800..frames - 4800 {
            let t = i as f64 / 48000.0;
            let ideal = amplitude * (2.0 * std::f64::consts::PI * 997.0 * t).sin();
            for c in 0..channels {
                let got = ours[i * channels + c] as f64 / 2f64.powi(31);
                err += (got - ideal).powi(2);
                n += 1;
            }
        }
        let rms_db = 10.0 * (err / n as f64).log10();
        eprintln!("resampling residual: {rms_db:.1} dBFS");
        assert!(rms_db < -120.0, "residual {rms_db:.1} dBFS");
    }
}

