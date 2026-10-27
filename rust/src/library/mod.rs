//! The music library: a SQLite index of the audio files under the chosen folders.

mod art;
pub use art::art_colors;
mod scan;

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};

use anyhow::Result;
use rayon::prelude::*;
use rusqlite::{params, Connection, OptionalExtension};

use crate::api::library::{Playlist, Track};

/// Separates multiple artists in one column.
const SEP: char = '\u{1f}';

pub struct Library {
    db: Connection,
    art_dir: PathBuf,
}

impl Library {
    pub fn open(data_dir: &Path, cache_dir: &Path) -> Result<Self> {
        std::fs::create_dir_all(data_dir)?;
        let art_dir = cache_dir.join("art");
        std::fs::create_dir_all(&art_dir)?;
        let db = Connection::open(data_dir.join("library.db"))?;
        db.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             PRAGMA foreign_keys = ON;
             CREATE TABLE IF NOT EXISTS tracks (
                 id INTEGER PRIMARY KEY,
                 path TEXT NOT NULL UNIQUE,
                 mtime INTEGER NOT NULL,
                 size INTEGER NOT NULL,
                 title TEXT NOT NULL,
                 artists TEXT NOT NULL,
                 album TEXT,
                 album_artist TEXT,
                 track_no INTEGER,
                 disc_no INTEGER,
                 year INTEGER,
                 duration REAL NOT NULL,
                 sample_rate INTEGER NOT NULL,
                 bits INTEGER,
                 channels INTEGER NOT NULL,
                 codec TEXT NOT NULL,
                 art TEXT
             );
             CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             -- Keyed by path, not track id, so they survive a file leaving and coming back.
             CREATE TABLE IF NOT EXISTS plays (
                 path TEXT PRIMARY KEY,
                 count INTEGER NOT NULL,
                 last INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS playlists (
                 id INTEGER PRIMARY KEY,
                 name TEXT NOT NULL,
                 created INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS playlist_tracks (
                 playlist INTEGER NOT NULL REFERENCES playlists (id) ON DELETE CASCADE,
                 position INTEGER NOT NULL,
                 path TEXT NOT NULL,
                 PRIMARY KEY (playlist, position)
             );",
        )?;
        Ok(Library { db, art_dir })
    }

    pub fn art_dir(&self) -> &Path {
        &self.art_dir
    }

    /// The folders to scan. Defaults to the system music folder (see `default_folder`).
    pub fn folders(&self) -> Result<Vec<String>> {
        let saved: Option<String> = self
            .db
            .query_row("SELECT value FROM settings WHERE key = 'folders'", [], |r| r.get(0))
            .optional()?;
        Ok(match saved {
            Some(value) => value.split(SEP).filter(|f| !f.is_empty()).map(String::from).collect(),
            None => default_folder().into_iter().collect(),
        })
    }

    pub fn set_folders(&self, folders: &[String]) -> Result<()> {
        self.db.execute(
            "INSERT INTO settings (key, value) VALUES ('folders', ?1)
             ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            [folders.join(&SEP.to_string())],
        )?;
        Ok(())
    }

    /// Brings the index in line with the folders: reads new and changed files, drops missing
    /// ones. `progress(done, total)` is called from worker threads as files are read.
    pub fn scan(&mut self, progress: impl Fn(usize, usize) + Sync) -> Result<()> {
        let folders = self.folders()?;
        let found = scan::find_audio(&folders);

        let mut known: HashMap<String, (i64, i64)> = HashMap::new();
        {
            let mut stmt = self.db.prepare("SELECT path, mtime, size FROM tracks")?;
            let rows = stmt.query_map([], |r| Ok((r.get(0)?, (r.get(1)?, r.get(2)?))))?;
            for row in rows {
                let (path, stamp) = row?;
                known.insert(path, stamp);
            }
        }

        let present: HashSet<String> =
            found.iter().map(|f| f.path.to_string_lossy().into_owned()).collect();
        let changed: Vec<_> = found
            .iter()
            .filter(|f| known.get(f.path.to_string_lossy().as_ref()) != Some(&(f.mtime, f.size)))
            .collect();

        let total = changed.len();
        let done = AtomicUsize::new(0);
        progress(0, total);
        let art_dir = &self.art_dir;
        let scanned: Vec<_> = changed
            .par_iter()
            .filter_map(|file| {
                let mut track = scan::read(file);
                let key = track.as_mut().and_then(|t| t.picture.take()).and_then(|p| art::store(art_dir, &p));
                let n = done.fetch_add(1, Relaxed) + 1;
                if n % 16 == 0 || n == total {
                    progress(n, total);
                }
                track.map(|t| (t, key))
            })
            .collect();

        let tx = self.db.transaction()?;
        {
            let mut upsert = tx.prepare(
                "INSERT INTO tracks (path, mtime, size, title, artists, album, album_artist,
                     track_no, disc_no, year, duration, sample_rate, bits, channels, codec, art)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
                 ON CONFLICT (path) DO UPDATE SET
                     mtime = excluded.mtime, size = excluded.size, title = excluded.title,
                     artists = excluded.artists, album = excluded.album,
                     album_artist = excluded.album_artist, track_no = excluded.track_no,
                     disc_no = excluded.disc_no, year = excluded.year,
                     duration = excluded.duration, sample_rate = excluded.sample_rate,
                     bits = excluded.bits, channels = excluded.channels, codec = excluded.codec,
                     art = excluded.art",
            )?;
            for (t, art) in &scanned {
                upsert.execute(params![
                    t.path,
                    t.mtime,
                    t.size,
                    t.title,
                    t.artists.join(&SEP.to_string()),
                    t.album,
                    t.album_artist,
                    t.track_no,
                    t.disc_no,
                    t.year,
                    t.duration_secs,
                    t.sample_rate,
                    t.bits,
                    t.channels,
                    t.codec,
                    art,
                ])?;
            }
            let mut delete = tx.prepare("DELETE FROM tracks WHERE path = ?1")?;
            for path in known.keys().filter(|p| !present.contains(*p)) {
                delete.execute([path])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn tracks(&self) -> Result<Vec<Track>> {
        let mut stmt = self.db.prepare(
            "SELECT id, tracks.path, title, artists, album, album_artist, track_no, disc_no,
                    year, duration, sample_rate, bits, channels, codec, art, mtime,
                    coalesce(plays.count, 0), plays.last
             FROM tracks LEFT JOIN plays ON plays.path = tracks.path
             ORDER BY title COLLATE NOCASE",
        )?;
        let rows = stmt.query_map([], |r| {
            let artists: String = r.get(3)?;
            Ok(Track {
                id: r.get(0)?,
                path: r.get(1)?,
                title: r.get(2)?,
                artists: artists.split(SEP).filter(|a| !a.is_empty()).map(String::from).collect(),
                album: r.get(4)?,
                album_artist: r.get(5)?,
                track_no: r.get(6)?,
                disc_no: r.get(7)?,
                year: r.get(8)?,
                duration_secs: r.get(9)?,
                sample_rate: r.get(10)?,
                bits: r.get(11)?,
                channels: r.get(12)?,
                codec: r.get(13)?,
                art: r.get(14)?,
                added: r.get(15)?,
                plays: r.get(16)?,
                last_played: r.get(17)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Counts one listen of `path`.
    pub fn record_play(&self, path: &str) -> Result<()> {
        self.db.execute(
            "INSERT INTO plays (path, count, last) VALUES (?1, 1, ?2)
             ON CONFLICT (path) DO UPDATE SET count = count + 1, last = excluded.last",
            params![path, now()],
        )?;
        Ok(())
    }

    /// The user's playlists, oldest first.
    pub fn playlists(&self) -> Result<Vec<Playlist>> {
        let mut playlists: Vec<Playlist> = self
            .db
            .prepare("SELECT id, name FROM playlists ORDER BY created, id")?
            .query_map([], |r| Ok(Playlist { id: r.get(0)?, name: r.get(1)?, paths: Vec::new() }))?
            .collect::<rusqlite::Result<_>>()?;
        let mut stmt = self.db.prepare(
            "SELECT playlist, path FROM playlist_tracks ORDER BY playlist, position",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?;
        for row in rows {
            let (id, path) = row?;
            if let Some(playlist) = playlists.iter_mut().find(|p| p.id == id) {
                playlist.paths.push(path);
            }
        }
        Ok(playlists)
    }

    pub fn create_playlist(&self, name: &str, paths: &[String]) -> Result<i64> {
        self.db.execute("INSERT INTO playlists (name, created) VALUES (?1, ?2)", params![name, now()])?;
        let id = self.db.last_insert_rowid();
        self.set_playlist_tracks(id, paths)?;
        Ok(id)
    }

    pub fn rename_playlist(&self, id: i64, name: &str) -> Result<()> {
        self.db.execute("UPDATE playlists SET name = ?2 WHERE id = ?1", params![id, name])?;
        Ok(())
    }

    pub fn delete_playlist(&self, id: i64) -> Result<()> {
        self.db.execute("DELETE FROM playlists WHERE id = ?1", [id])?;
        Ok(())
    }

    /// Replaces the playlist's contents, in order. Playlists are small, so adding, removing
    /// and reordering all come down to this.
    pub fn set_playlist_tracks(&self, id: i64, paths: &[String]) -> Result<()> {
        let tx = self.db.unchecked_transaction()?;
        tx.execute("DELETE FROM playlist_tracks WHERE playlist = ?1", [id])?;
        {
            let mut insert =
                tx.prepare("INSERT INTO playlist_tracks (playlist, position, path) VALUES (?1, ?2, ?3)")?;
            for (position, path) in paths.iter().enumerate() {
                insert.execute(params![id, position as i64, path])?;
            }
        }
        tx.commit()?;
        Ok(())
    }
}

/// Unix seconds.
fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// The system music folder: the phone's shared Music folder on Android.
fn default_folder() -> Option<String> {
    if cfg!(target_os = "android") {
        return Some("/storage/emulated/0/Music".into());
    }
    dirs::audio_dir().map(|d| d.to_string_lossy().into_owned())
}
