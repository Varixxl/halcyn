//! The library API: which folders to index, scanning them, and listing what's in them.

use std::path::Path;
use std::sync::Mutex;

use anyhow::{anyhow, Result};

use crate::frb_generated::StreamSink;
use crate::library::Library;

#[derive(Clone, Debug)]
pub struct Track {
    pub id: i64,
    pub path: String,
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
    /// Key into the art cache (see `library_art_dir`), if the track has a cover.
    pub art: Option<String>,
    /// When the file last changed, in Unix seconds: when it was added, for most libraries.
    pub added: i64,
    pub plays: u32,
    /// Unix seconds.
    pub last_played: Option<i64>,
    /// The recording's ISRC: from the file's tags, or the service (Tidal's songs have one).
    pub isrc: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Playlist {
    pub id: i64,
    pub name: String,
    /// The tracks in order. Paths that are no longer in the library are kept.
    pub paths: Vec<String>,
    /// The playlist file in the music folders it was read from, if it was.
    pub source: Option<String>,
}

/// What a playlist file chosen by the user lists, before it becomes a playlist.
pub struct PlaylistFile {
    pub name: String,
    /// The library tracks it lists, in order.
    pub paths: Vec<String>,
    /// How many entries the file has, found in the library or not.
    pub entries: u32,
}

pub struct ScanProgress {
    pub done: u32,
    pub total: u32,
}

static LIBRARY: Mutex<Option<Library>> = Mutex::new(None);

pub(crate) fn with<T>(f: impl FnOnce(&mut Library) -> Result<T>) -> Result<T> {
    let mut library = LIBRARY.lock().unwrap();
    f(library.as_mut().ok_or_else(|| anyhow!("the library isn't open"))?)
}

/// Opens (or creates) the library. Call once at startup.
pub fn library_open(data_dir: String, cache_dir: String) -> Result<()> {
    let library = Library::open(Path::new(&data_dir), Path::new(&cache_dir))?;
    *LIBRARY.lock().unwrap() = Some(library);
    Ok(())
}

/// Where cover art lives: `<dir>/<art>-128.jpg`, `-512.jpg` and `-full.jpg`.
#[flutter_rust_bridge::frb(sync)]
pub fn library_art_dir() -> Result<String> {
    with(|l| Ok(l.art_dir().to_string_lossy().into_owned()))
}

pub fn library_folders() -> Result<Vec<String>> {
    with(|l| l.folders())
}

pub fn library_set_folders(folders: Vec<String>) -> Result<()> {
    with(|l| l.set_folders(&folders))
}

/// Rescans the folders, reporting progress. Unchanged files are skipped, so this is cheap.
pub fn library_scan(progress: StreamSink<ScanProgress>) -> Result<()> {
    with(|l| {
        l.scan(|done, total| {
            let _ = progress.add(ScanProgress { done: done as u32, total: total as u32 });
        })
    })
}

pub fn library_tracks() -> Result<Vec<Track>> {
    with(|l| l.tracks())
}

/// Stores a downloaded cover for an album's tracks; returns its art key.
pub fn library_store_fetched_art(paths: Vec<String>, image: Vec<u8>) -> Result<Option<String>> {
    with(|l| l.store_fetched_art(&paths, &image))
}

/// Counts one listen of `path`, for Most played.
pub fn library_record_play(path: String) -> Result<()> {
    with(|l| l.record_play(&path))
}

pub fn library_playlists() -> Result<Vec<Playlist>> {
    with(|l| l.playlists())
}

/// Returns the new playlist's id.
pub fn library_create_playlist(name: String, paths: Vec<String>) -> Result<i64> {
    with(|l| l.create_playlist(&name, &paths))
}

/// Reads a .m3u, .m3u8, .pls or .xspf file: `name` is its file name, `path` where it is
/// (entries can be relative to it).
pub fn library_read_playlist_file(path: String, name: String, bytes: Vec<u8>) -> Result<PlaylistFile> {
    with(|l| {
        let (name, paths, entries) = l.read_playlist_file(&path, &name, &bytes)?;
        Ok(PlaylistFile { name, paths, entries: entries as u32 })
    })
}

pub fn library_rename_playlist(id: i64, name: String) -> Result<()> {
    with(|l| l.rename_playlist(id, &name))
}

pub fn library_delete_playlist(id: i64) -> Result<()> {
    with(|l| l.delete_playlist(id))
}

pub fn library_set_playlist_tracks(id: i64, paths: Vec<String>) -> Result<()> {
    with(|l| l.set_playlist_tracks(id, &paths))
}

/// The cover's two most vivid colours as 0xAARRGGBB, strongest first, read from its 128 px
/// thumbnail. Empty when the art can't be read.
pub fn library_art_colors(art_dir: String, art: String) -> Vec<u32> {
    crate::library::art_colors(&Path::new(&art_dir).join(format!("{art}-128.jpg")))
}
