//! Decoding: the default audio track of one file, as interleaved samples.

use std::fs::File;
use std::path::Path;

use anyhow::{anyhow, Context, Result};
use symphonia::core::codecs::audio::{AudioDecoder, AudioDecoderOptions};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo, TrackType};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::units::{Time, TimeBase, Timestamp};

#[derive(Clone, Debug)]
pub struct SourceInfo {
    pub codec: String,
    pub lossless: bool,
    pub sample_rate: u32,
    pub channels: usize,
    pub bits_per_sample: Option<u32>,
    pub total_frames: Option<u64>,
}

/// Where `Source::read` puts the decoded samples.
pub enum Samples<'a> {
    /// Full-scale i32. Integer sources land here unchanged (16-bit is shifted up 16, 24-bit 8).
    Int(&'a mut Vec<i32>),
    /// f64 in [-1, 1), for the processing path.
    Float(&'a mut Vec<f64>),
}

pub struct Source {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn AudioDecoder>,
    track_id: u32,
    time_base: Option<TimeBase>,
    /// Frames to drop after an accurate seek, which lands on the packet before the target.
    skip_frames: u64,
    pub info: SourceInfo,
}

impl Source {
    pub fn open(path: &Path) -> Result<Self> {
        let file = File::open(path).with_context(|| format!("can't open {}", path.display()))?;
        let stream = MediaSourceStream::new(Box::new(file), Default::default());
        let mut hint = Hint::new();
        if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            hint.with_extension(ext);
        }
        let format = symphonia::default::get_probe()
            .probe(&hint, stream, FormatOptions::default(), MetadataOptions::default())
            .context("unsupported or damaged file")?;

        let track = format
            .default_track(TrackType::Audio)
            .ok_or_else(|| anyhow!("the file has no audio track"))?;
        let params = track
            .codec_params
            .as_ref()
            .and_then(|p| p.audio())
            .ok_or_else(|| anyhow!("the audio track has no codec parameters"))?
            .clone();
        let (track_id, time_base, total_frames) = (track.id, track.time_base, track.num_frames);

        let decoder = symphonia::default::get_codecs()
            .make_audio_decoder(&params, &AudioDecoderOptions::default())
            .context("no decoder for this codec")?;
        let codec = decoder.codec_info().short_name;
        let lossless = matches!(codec, "flac" | "alac" | "wavpack")
            || (codec.starts_with("pcm_") && !matches!(codec, "pcm_alaw" | "pcm_mulaw"));

        let info = SourceInfo {
            codec: codec.to_string(),
            lossless,
            sample_rate: params.sample_rate.ok_or_else(|| anyhow!("unknown sample rate"))?,
            channels: params.channels.as_ref().map(|c| c.count()).unwrap_or(0),
            bits_per_sample: if lossless { params.bits_per_sample } else { None },
            total_frames,
        };
        if info.channels == 0 {
            return Err(anyhow!("unknown channel layout"));
        }

        Ok(Source { format, decoder, track_id, time_base, skip_frames: 0, info })
    }

    /// Decodes the next packet into `out`, replacing its contents. Returns false at the end of
    /// the stream. Damaged packets are skipped.
    pub fn read(&mut self, out: Samples<'_>) -> Result<bool> {
        loop {
            let packet = match self.format.next_packet()? {
                Some(packet) => packet,
                None => return Ok(false),
            };
            if packet.track_id != self.track_id {
                continue;
            }
            let buf = match self.decoder.decode(&packet) {
                Ok(buf) => buf,
                Err(SymphoniaError::DecodeError(_)) => continue,
                Err(err) => return Err(err.into()),
            };

            let frames = buf.frames();
            let skip = (self.skip_frames as usize).min(frames);
            self.skip_frames -= skip as u64;
            if skip == frames {
                continue;
            }
            let skip = skip * buf.spec().channels().count();
            match out {
                Samples::Int(v) => {
                    buf.copy_to_vec_interleaved(v);
                    v.drain(..skip);
                }
                Samples::Float(v) => {
                    buf.copy_to_vec_interleaved(v);
                    v.drain(..skip);
                }
            }
            return Ok(true);
        }
    }

    /// Seeks to `secs`, sample-accurately. Returns the frame the next `read` starts at.
    pub fn seek(&mut self, secs: f64) -> Result<u64> {
        let time = Time::try_from_secs_f64(secs.max(0.0)).ok_or_else(|| anyhow!("bad seek time"))?;
        let seeked = self
            .format
            .seek(SeekMode::Accurate, SeekTo::Time { time, track_id: Some(self.track_id) })?;
        self.decoder.reset();
        let required = self.ts_to_frames(seeked.required_ts);
        self.skip_frames = required.saturating_sub(self.ts_to_frames(seeked.actual_ts));
        Ok(required)
    }

    fn ts_to_frames(&self, ts: Timestamp) -> u64 {
        let ts = ts.get().max(0) as u128;
        match self.time_base {
            Some(tb) => {
                (ts * tb.numer.get() as u128 * self.info.sample_rate as u128
                    / tb.denom.get() as u128) as u64
            }
            None => ts as u64,
        }
    }
}
