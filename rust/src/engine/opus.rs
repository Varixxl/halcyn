//! Opus, which symphonia reads out of WebM and Ogg but can't decode: libopus does it.
//! Mono and stereo (channel mapping family 0) only, which is what music comes as.

use std::ptr::NonNull;

use symphonia::core::audio::{
    AsGenericAudioBufferRef, AudioBuffer, AudioMut, AudioSpec, Channels, GenericAudioBufferRef, Position,
};
use symphonia::core::codecs::audio::well_known::CODEC_ID_OPUS;
use symphonia::core::codecs::audio::{AudioCodecParameters, AudioDecoder, FinalizeResult};
use symphonia::core::codecs::CodecInfo;
use symphonia::core::errors::{decode_error, unsupported_error, Result};
use symphonia::core::packet::PacketRef;

/// The parts of libopus (vendor/opus, built by build.rs) that Halcyn uses.
pub(crate) mod ffi {
    use std::os::raw::{c_int, c_uchar};

    #[repr(C)]
    pub struct OpusDecoder {
        _private: [u8; 0],
    }

    pub const OPUS_OK: c_int = 0;
    pub const OPUS_RESET_STATE: c_int = 4028;

    unsafe extern "C" {
        pub fn opus_decoder_create(fs: i32, channels: c_int, error: *mut c_int) -> *mut OpusDecoder;
        pub fn opus_decode_float(
            st: *mut OpusDecoder,
            data: *const c_uchar,
            len: i32,
            pcm: *mut f32,
            frame_size: c_int,
            decode_fec: c_int,
        ) -> c_int;
        pub fn opus_decoder_ctl(st: *mut OpusDecoder, request: c_int, ...) -> c_int;
        pub fn opus_decoder_destroy(st: *mut OpusDecoder);
        pub fn opus_packet_get_nb_samples(packet: *const c_uchar, len: i32, fs: i32) -> c_int;
    }
}

/// Opus always decodes at 48 kHz, whatever it was made from.
const RATE: u32 = 48_000;
/// The longest packet there is: 120 ms.
const MAX_FRAMES: usize = 5760;

const INFO: CodecInfo = CodecInfo { short_name: "opus", long_name: "Opus", profiles: &[] };

pub fn is_opus(params: &AudioCodecParameters) -> bool {
    params.codec == CODEC_ID_OPUS
}

pub struct OpusDecoder {
    state: NonNull<ffi::OpusDecoder>,
    params: AudioCodecParameters,
    channels: usize,
    /// The encoder's lead-in (OpusHead's pre-skip), dropped from the very first packet when the
    /// container doesn't say to (WebM doesn't; Ogg does, through the packet's trim).
    pre_skip: usize,
    started: bool,
    pcm: Vec<f32>,
    buf: AudioBuffer<f32>,
}

// libopus's state belongs to whoever holds the decoder; nothing else touches it.
unsafe impl Send for OpusDecoder {}
unsafe impl Sync for OpusDecoder {}

impl OpusDecoder {
    pub fn try_new(params: &AudioCodecParameters) -> Result<Self> {
        // OpusHead: "OpusHead", version, channels, pre-skip (LE u16), rate, gain, family.
        let head = params.extra_data.as_deref().filter(|h| h.len() >= 19 && h.starts_with(b"OpusHead"));
        let channels = match (head, &params.channels) {
            (Some(h), _) => h[9] as usize,
            (None, Some(c)) => c.count(),
            (None, None) => 2,
        };
        if head.is_some_and(|h| h[18] != 0) || !(1..=2).contains(&channels) {
            return unsupported_error("opus: only mono and stereo are supported");
        }
        let pre_skip = head.map_or(0, |h| u16::from_le_bytes([h[10], h[11]]) as usize);
        let mut error = 0;
        let state = unsafe { ffi::opus_decoder_create(RATE as i32, channels as i32, &mut error) };
        let Some(state) = NonNull::new(state).filter(|_| error == ffi::OPUS_OK) else {
            return unsupported_error("opus: libopus couldn't start a decoder");
        };
        let layout = Channels::Positioned(if channels == 1 {
            Position::FRONT_CENTER
        } else {
            Position::FRONT_LEFT | Position::FRONT_RIGHT
        });
        let mut params = params.clone();
        params.with_sample_rate(RATE).with_channels(layout.clone());
        Ok(OpusDecoder {
            state,
            params,
            channels,
            pre_skip,
            started: false,
            pcm: vec![0.0; MAX_FRAMES * channels],
            buf: AudioBuffer::new(AudioSpec::new(RATE, layout), MAX_FRAMES),
        })
    }

    fn decode_inner(&mut self, packet: &PacketRef<'_>) -> Result<()> {
        self.buf.clear();
        let frames = unsafe {
            ffi::opus_decode_float(
                self.state.as_ptr(),
                packet.data.as_ptr(),
                packet.data.len() as i32,
                self.pcm.as_mut_ptr(),
                MAX_FRAMES as i32,
                0,
            )
        };
        if frames < 0 {
            return decode_error("opus: damaged packet");
        }
        let frames = frames as usize;
        self.buf.render_uninit(Some(frames));
        self.buf.copy_from_slice_interleaved(&&self.pcm[..frames * self.channels]);
        let mut start = packet.trim_start.get() as usize;
        if !self.started && start == 0 {
            start = self.pre_skip;
        }
        self.started = true;
        self.buf.trim(start, packet.trim_end.get() as usize);
        Ok(())
    }
}

impl Drop for OpusDecoder {
    fn drop(&mut self) {
        unsafe { ffi::opus_decoder_destroy(self.state.as_ptr()) }
    }
}

impl AudioDecoder for OpusDecoder {
    fn reset(&mut self) {
        // After a seek: the lead-in was at the start, not here.
        self.started = true;
        unsafe { ffi::opus_decoder_ctl(self.state.as_ptr(), ffi::OPUS_RESET_STATE) };
    }

    fn codec_info(&self) -> &CodecInfo {
        &INFO
    }

    fn codec_params(&self) -> &AudioCodecParameters {
        &self.params
    }

    fn decode_ref(&mut self, packet: &PacketRef<'_>) -> Result<GenericAudioBufferRef<'_>> {
        if let Err(e) = self.decode_inner(packet) {
            self.buf.clear();
            return Err(e);
        }
        Ok(self.buf.as_generic_audio_buffer_ref())
    }

    fn finalize(&mut self) -> FinalizeResult {
        Default::default()
    }

    fn last_decoded(&self) -> GenericAudioBufferRef<'_> {
        self.buf.as_generic_audio_buffer_ref()
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use crate::engine::source::{Samples, Source};

    /// Decodes HALCYN_TEST_OPUS (a .webm or .opus file) and compares it with HALCYN_TEST_REF,
    /// ffmpeg's decode of it as 48 kHz stereo f32: `ffmpeg -c:a libopus -i x -f f32le ref.f32`.
    #[test]
    #[ignore]
    fn matches_ffmpeg() {
        let file = std::env::var("HALCYN_TEST_OPUS").expect("HALCYN_TEST_OPUS");
        let reference: Vec<f32> = std::fs::read(std::env::var("HALCYN_TEST_REF").expect("HALCYN_TEST_REF"))
            .unwrap()
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
            .collect();
        let mut source = Source::open(Path::new(&file)).unwrap();
        println!("{:?}", source.info);
        let mut ours = Vec::new();
        let mut buf = Vec::new();
        while source.read(Samples::Float(&mut buf)).unwrap() {
            ours.extend(buf.iter().map(|s| *s as f32));
        }
        let worst = ours.iter().zip(&reference).map(|(a, b)| (a - b).abs()).fold(0f32, f32::max);
        println!("ours {} samples, ffmpeg {}, worst difference {worst:e}", ours.len(), reference.len());
        // WebM's end trim (DiscardPadding) isn't read: up to a packet of the encoder's padding stays.
        assert!(ours.len() >= reference.len() && ours.len() <= reference.len() + 960 * 2);
        assert!(worst < 1e-4);
        // Seeking (mid-song, as playing does) lands where it says.
        let mut source = Source::open(Path::new(&file)).unwrap();
        source.read(Samples::Float(&mut buf)).unwrap();
        let at = source.seek(2.5).unwrap();
        assert!(source.read(Samples::Float(&mut buf)).unwrap());
        let start = at as usize * 2;
        // Opus needs 80 ms of the stream before a seek to settle; the rest of that packet is close.
        let worst = buf.iter().zip(&reference[start..]).skip(3840 * 2).map(|(a, b)| (*a as f32 - b).abs()).fold(0f32, f32::max);
        println!("seeked to frame {at} ({} frames read), worst difference after {worst:e}", buf.len() / 2);
        assert_eq!(at, 120_000);
    }
}
