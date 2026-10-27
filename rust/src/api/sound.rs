//! Volume and the equalizer. Applied on the output's audio thread, so changes are heard at once.

use crate::api::player::engine;
use crate::engine::dsp::{self, Design, Filter, Kind};
use crate::engine::Command;

#[derive(Clone, Copy, Debug)]
pub enum EqFilterKind {
    Peak,
    LowShelf,
    HighShelf,
}

#[derive(Clone, Debug)]
pub struct EqFilter {
    pub kind: EqFilterKind,
    pub hz: f64,
    pub gain_db: f64,
    pub q: f64,
}

#[derive(Clone, Debug)]
pub struct SoundSettings {
    /// Linear gain, 0..1. Exactly 1 leaves the samples alone (with the EQ off).
    pub volume: f64,
    pub eq: bool,
    /// The headphone correction, the bands and the bass and treble shelves, in order.
    pub filters: Vec<EqFilter>,
}

pub struct SoundInfo {
    /// The cut that keeps the EQ's boosts from clipping (0 or below).
    pub preamp_db: f64,
    /// The EQ's response in dB at `sound_curve_freqs()`, before the pre-gain.
    pub curve: Vec<f64>,
}

const CURVE_POINTS: usize = 120;

/// The frequencies `SoundInfo.curve` is measured at: 20 Hz to 20 kHz, log spaced.
#[flutter_rust_bridge::frb(sync)]
pub fn sound_curve_freqs() -> Vec<f64> {
    dsp::log_freqs(CURVE_POINTS)
}

/// Applies `settings` and returns what the EQ does.
#[flutter_rust_bridge::frb(sync)]
pub fn sound_set(settings: SoundSettings) -> SoundInfo {
    let filters: Vec<Filter> = settings
        .filters
        .iter()
        .map(|f| Filter {
            kind: match f.kind {
                EqFilterKind::Peak => Kind::Peak,
                EqFilterKind::LowShelf => Kind::LowShelf,
                EqFilterKind::HighShelf => Kind::HighShelf,
            },
            hz: f.hz,
            gain_db: f.gain_db,
            q: f.q,
        })
        .collect();
    let preamp_db = dsp::preamp_db(&filters);
    let curve = dsp::response(&filters, &dsp::log_freqs(CURVE_POINTS));

    let volume = settings.volume.clamp(0.0, 1.0);
    let eq = settings.eq && filters.iter().any(|f| f.gain_db != 0.0);
    let design = if eq {
        Design::new(volume * 10f64.powf(preamp_db / 20.0), &filters)
    } else {
        Design::new(volume, &[])
    };
    let mut label = Vec::new();
    if eq {
        label.push("EQ".to_string());
    }
    if volume < 1.0 {
        label.push(if volume <= 0.0 {
            "Muted".to_string()
        } else {
            format!("Volume {:.1} dB", 20.0 * volume.log10())
        });
    }
    let label = (!label.is_empty()).then(|| label.join(" · "));
    engine().send(Command::Sound { design, label });
    SoundInfo { preamp_db: if eq { preamp_db } else { 0.0 }, curve }
}
