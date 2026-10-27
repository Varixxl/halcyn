//! Reading one file's tags and properties, and finding the audio files under a folder.

use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use lofty::file::FileType;
use lofty::picture::PictureType;
use lofty::prelude::*;
use lofty::tag::ItemKey;

const AUDIO_EXTENSIONS: &[&str] = &[
    "flac", "wav", "wave", "aiff", "aif", "aifc", "mp3", "m4a", "mp4", "ogg", "oga", "mka",
    "webm", "caf",
];

/// A file on disk, before its tags are read.
pub struct Found {
    pub path: PathBuf,
    pub mtime: i64,
    pub size: i64,
}

/// What the library stores for one track.
pub struct Scanned {
    pub path: String,
    pub mtime: i64,
    pub size: i64,
    pub title: String,
    pub artists: Vec<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_no: Option<u32>,
    pub disc_no: Option<u32>,
    pub year: Option<u32>,
    pub duration_secs: f64,
    pub sample_rate: u32,
    pub bits: Option<u32>,
    pub channels: u32,
    pub codec: String,
    /// The cover image's bytes, before it is written to the art cache.
    pub picture: Option<Vec<u8>>,
}

/// The audio files and the playlist files under `folders`.
pub fn find_files(folders: &[String]) -> (Vec<Found>, Vec<Found>) {
    let (mut found, mut playlists) = (Vec::new(), Vec::new());
    for folder in folders {
        for entry in jwalk::WalkDir::new(folder).skip_hidden(true).into_iter().flatten() {
            let path = entry.path();
            let is_audio = path
                .extension()
                .and_then(|e| e.to_str())
                .is_some_and(|e| AUDIO_EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()));
            let is_playlist = super::playlist_files::is_playlist(&path);
            if !(is_audio || is_playlist) || !entry.file_type().is_file() {
                continue;
            }
            let Ok(meta) = entry.metadata() else { continue };
            let mtime = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map_or(0, |d| d.as_secs() as i64);
            let file = Found { path, mtime, size: meta.len() as i64 };
            if is_audio {
                found.push(file)
            } else {
                playlists.push(file)
            }
        }
    }
    (found, playlists)
}

pub fn read(file: &Found) -> Option<Scanned> {
    let tagged = lofty::read_from_path(&file.path).ok()?;
    let props = tagged.properties();
    let tag = tagged.primary_tag().or_else(|| tagged.first_tag());
    let text = |key: ItemKey| tag.and_then(|t| t.get_string(key)).map(str::to_string);

    let mut artists: Vec<String> = Vec::new();
    if let Some(tag) = tag {
        for value in tag.get_strings(ItemKey::TrackArtist) {
            for name in value.split(';').map(str::trim).filter(|n| !n.is_empty()) {
                if !artists.iter().any(|a| a == name) {
                    artists.push(name.to_string());
                }
            }
        }
    }

    let picture = tag.and_then(|t| {
        let pictures = t.pictures();
        pictures
            .iter()
            .find(|p| p.pic_type() == PictureType::CoverFront)
            .or_else(|| pictures.first())
            .map(|p| p.data().to_vec())
    });
    let picture = picture.or_else(|| folder_cover(&file.path));

    Some(Scanned {
        path: file.path.to_string_lossy().into_owned(),
        mtime: file.mtime,
        size: file.size,
        title: text(ItemKey::TrackTitle).unwrap_or_else(|| {
            file.path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
        }),
        artists,
        album: text(ItemKey::AlbumTitle),
        album_artist: text(ItemKey::AlbumArtist),
        track_no: tag.and_then(|t| t.track()),
        disc_no: tag.and_then(|t| t.disk()),
        year: tag.and_then(|t| t.date()).map(|d| d.year as u32),
        duration_secs: props.duration().as_secs_f64(),
        sample_rate: props.sample_rate().unwrap_or(0),
        bits: props.bit_depth().map(u32::from),
        channels: props.channels().map_or(2, u32::from),
        codec: codec_name(tagged.file_type()).to_string(),
        picture,
    })
}

/// A cover.jpg (or similar) next to the file, for files without an embedded picture.
fn folder_cover(path: &Path) -> Option<Vec<u8>> {
    let dir = path.parent()?;
    ["cover", "folder", "front", "album"].iter().find_map(|name| {
        ["jpg", "jpeg", "png"].iter().find_map(|ext| std::fs::read(dir.join(format!("{name}.{ext}"))).ok())
    })
}

fn codec_name(file_type: FileType) -> &'static str {
    match file_type {
        FileType::Flac => "FLAC",
        FileType::Mpeg => "MP3",
        FileType::Mp4 => "AAC/ALAC",
        FileType::Vorbis => "Vorbis",
        FileType::Opus => "Opus",
        FileType::Wav => "WAV",
        FileType::Aiff => "AIFF",
        _ => "Audio",
    }
}
