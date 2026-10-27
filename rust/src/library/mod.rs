//! The music library: a SQLite index of the audio files under the chosen folders.

mod art;
pub use art::art_colors;
pub(crate) use art::store as store_art;
mod playlist_files;
mod scan;

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};

use anyhow::Result;
use rayon::prelude::*;
use rusqlite::{params, Connection, OptionalExtension};

use crate::api::library::{Playlist, Track};
use crate::api::streaming::RemoteTrack;

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
             );
             -- Playlist files the user deleted in the app, so a rescan doesn't bring them back.
             CREATE TABLE IF NOT EXISTS ignored_playlist_files (source TEXT PRIMARY KEY);
             -- Covers downloaded for tracks without one of their own (see store_fetched_art).
             -- Apart from tracks, so a rescan of the file keeps them.
             CREATE TABLE IF NOT EXISTS fetched_art (path TEXT PRIMARY KEY, art TEXT NOT NULL);
             -- Songs from Tidal and YouTube Music the user has come across (searched, imported,
             -- queued), so playlists and the queue can show them. Paths are `tidal:<id>` and
             -- `ytm:<id>`.
             CREATE TABLE IF NOT EXISTS stream_tracks (
                 id INTEGER PRIMARY KEY,
                 path TEXT NOT NULL UNIQUE,
                 title TEXT NOT NULL,
                 artists TEXT NOT NULL,
                 album TEXT,
                 duration REAL NOT NULL,
                 codec TEXT NOT NULL,
                 art TEXT,
                 isrc TEXT,
                 -- When first come across: its `added`.
                 seen INTEGER NOT NULL
             );
             -- Covers of streamed songs by address, so each is downloaded once.
             CREATE TABLE IF NOT EXISTS stream_art (url TEXT PRIMARY KEY, art TEXT NOT NULL);",
        )?;
        // Playlists read from a file in the music folders: its path and when it last changed.
        let has_source: bool = db
            .prepare("SELECT 1 FROM pragma_table_info('playlists') WHERE name = 'source'")?
            .exists([])?;
        if !has_source {
            db.execute_batch(
                "ALTER TABLE playlists ADD COLUMN source TEXT;
                 ALTER TABLE playlists ADD COLUMN source_mtime INTEGER;",
            )?;
        }
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
        let (found, playlist_files) = scan::find_files(&folders);

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
        let library_changed = !scanned.is_empty() || known.keys().any(|p| !present.contains(p));
        self.sync_playlist_files(&playlist_files, library_changed)?;
        Ok(())
    }

    /// Makes a playlist of each playlist file and keeps it like the file: read again when
    /// the file changes (or the library does, so entries found later join), removed when
    /// the file goes. One the user deleted stays deleted. Edits made in the app last until
    /// then.
    fn sync_playlist_files(&mut self, files: &[scan::Found], library_changed: bool) -> Result<()> {
        let ignored: HashSet<String> = self
            .db
            .prepare("SELECT source FROM ignored_playlist_files")?
            .query_map([], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        let existing: HashMap<String, (i64, Option<i64>)> = self
            .db
            .prepare("SELECT source, id, source_mtime FROM playlists WHERE source IS NOT NULL")?
            .query_map([], |r| Ok((r.get(0)?, (r.get(1)?, r.get(2)?))))?
            .collect::<rusqlite::Result<_>>()?;
        let library: Vec<String> = self
            .db
            .prepare("SELECT path FROM tracks")?
            .query_map([], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        let resolver = playlist_files::Resolver::new(library.iter().map(String::as_str));

        let present: HashSet<String> =
            files.iter().map(|f| f.path.to_string_lossy().into_owned()).collect();
        for file in files {
            let source = file.path.to_string_lossy().into_owned();
            if ignored.contains(&source) {
                continue;
            }
            let known = existing.get(&source);
            if known.is_some_and(|(_, mtime)| *mtime == Some(file.mtime)) && !library_changed {
                continue;
            }
            let Ok(bytes) = std::fs::read(&file.path) else {
                continue;
            };
            let parsed = playlist_files::parse(&file.path, &bytes);
            let paths: Vec<String> =
                parsed.entries.iter().filter_map(|e| resolver.resolve(&file.path, e)).collect();
            let name = parsed.title.unwrap_or_else(|| playlist_files::default_name(&file.path));
            let id = match known {
                Some((id, _)) => {
                    self.db.execute(
                        "UPDATE playlists SET name = ?2, source_mtime = ?3 WHERE id = ?1",
                        params![id, name, file.mtime],
                    )?;
                    *id
                }
                // Nothing of it in the library (a list of web radio, say): not worth a playlist.
                None if paths.is_empty() => continue,
                None => {
                    self.db.execute(
                        "INSERT INTO playlists (name, created, source, source_mtime)
                         VALUES (?1, ?2, ?3, ?4)",
                        params![name, file.mtime, source, file.mtime],
                    )?;
                    self.db.last_insert_rowid()
                }
            };
            self.set_playlist_tracks(id, &paths)?;
        }
        for (source, (id, _)) in &existing {
            if !present.contains(source) {
                self.db.execute("DELETE FROM playlists WHERE id = ?1", [id])?;
            }
        }
        for source in ignored.iter().filter(|s| !present.contains(*s)) {
            self.db.execute("DELETE FROM ignored_playlist_files WHERE source = ?1", [source])?;
        }
        Ok(())
    }

    /// A playlist file from anywhere (`name` is its file name, `path` where it was, for
    /// entries relative to it): its title, the library tracks it lists, and how many
    /// entries it has.
    pub fn read_playlist_file(&self, path: &str, name: &str, bytes: &[u8]) -> Result<(String, Vec<String>, usize)> {
        let library: Vec<String> = self
            .db
            .prepare("SELECT path FROM tracks")?
            .query_map([], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        let resolver = playlist_files::Resolver::new(library.iter().map(String::as_str));
        let parsed = playlist_files::parse(Path::new(name), bytes);
        let paths = parsed.entries.iter().filter_map(|e| resolver.resolve(Path::new(path), e)).collect();
        let title = parsed.title.unwrap_or_else(|| playlist_files::default_name(Path::new(name)));
        Ok((title, paths, parsed.entries.len()))
    }

    pub fn tracks(&self) -> Result<Vec<Track>> {
        let mut stmt = self.db.prepare(
            "SELECT id, tracks.path, title, artists, album, album_artist, track_no, disc_no,
                    year, duration, sample_rate, bits, channels, codec,
                    coalesce(tracks.art, fetched_art.art), mtime,
                    coalesce(plays.count, 0), plays.last
             FROM tracks LEFT JOIN plays ON plays.path = tracks.path
                  LEFT JOIN fetched_art ON fetched_art.path = tracks.path
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

    /// The art keys of the covers already downloaded from these addresses.
    pub fn known_stream_art(&self, urls: &[String]) -> Result<HashMap<String, String>> {
        let mut stmt = self.db.prepare("SELECT art FROM stream_art WHERE url = ?1")?;
        let mut out = HashMap::new();
        for url in urls {
            if let Some(art) = stmt.query_row([url], |r| r.get::<_, String>(0)).optional()? {
                out.insert(url.clone(), art);
            }
        }
        Ok(out)
    }

    /// Records streamed songs (and their covers' keys, by address) and returns them as
    /// tracks, in the same order.
    pub fn remember_streams(
        &self,
        tracks: &[RemoteTrack],
        art: &HashMap<String, String>,
    ) -> Result<Vec<Track>> {
        let tx = self.db.unchecked_transaction()?;
        {
            let mut insert_art =
                tx.prepare("INSERT OR REPLACE INTO stream_art (url, art) VALUES (?1, ?2)")?;
            for (url, key) in art {
                insert_art.execute(params![url, key])?;
            }
            let mut upsert = tx.prepare(
                "INSERT INTO stream_tracks (path, title, artists, album, duration, codec, art, isrc, seen)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                 ON CONFLICT (path) DO UPDATE SET title = excluded.title, artists = excluded.artists,
                     album = coalesce(excluded.album, album),
                     duration = CASE WHEN excluded.duration > 0 THEN excluded.duration ELSE duration END,
                     codec = excluded.codec, art = coalesce(excluded.art, art),
                     isrc = coalesce(excluded.isrc, isrc)",
            )?;
            let now = now();
            for t in tracks {
                let key = t.art_url.as_ref().and_then(|u| art.get(u));
                upsert.execute(params![
                    t.path,
                    t.title,
                    t.artists.join(&SEP.to_string()),
                    t.album,
                    t.duration_secs,
                    t.quality.as_deref().unwrap_or(""),
                    key,
                    t.isrc,
                    now
                ])?;
            }
        }
        tx.commit()?;
        let paths: Vec<&str> = tracks.iter().map(|t| t.path.as_str()).collect();
        let mut found: HashMap<String, Track> =
            self.stream_tracks_where(&paths)?.into_iter().map(|t| (t.path.clone(), t)).collect();
        Ok(tracks.iter().filter_map(|t| found.remove(&t.path)).collect())
    }

    /// Every streamed song come across.
    pub fn stream_tracks(&self) -> Result<Vec<Track>> {
        self.stream_tracks_where(&[])
    }

    /// The streamed songs with these paths (all of them, when empty).
    fn stream_tracks_where(&self, paths: &[&str]) -> Result<Vec<Track>> {
        let sql =
            "SELECT stream_tracks.id, stream_tracks.path, title, artists, album, duration, codec,
                          art, seen, coalesce(plays.count, 0), plays.last
                   FROM stream_tracks LEFT JOIN plays ON plays.path = stream_tracks.path";
        let read = |r: &rusqlite::Row| {
            let artists: String = r.get(3)?;
            Ok(Track {
                // Apart from the library's ids.
                id: -r.get::<_, i64>(0)?,
                path: r.get(1)?,
                title: r.get(2)?,
                artists: artists.split(SEP).filter(|a| !a.is_empty()).map(String::from).collect(),
                album: r.get(4)?,
                album_artist: None,
                track_no: None,
                disc_no: None,
                year: None,
                duration_secs: r.get(5)?,
                sample_rate: 0,
                bits: None,
                channels: 2,
                codec: r.get(6)?,
                art: r.get(7)?,
                added: r.get(8)?,
                plays: r.get(9)?,
                last_played: r.get(10)?,
            })
        };
        if paths.is_empty() {
            let mut stmt = self.db.prepare(sql)?;
            let rows = stmt.query_map([], read)?;
            return Ok(rows.collect::<rusqlite::Result<_>>()?);
        }
        let mut stmt = self.db.prepare(&format!("{sql} WHERE stream_tracks.path = ?1"))?;
        let mut out = Vec::new();
        for path in paths {
            if let Some(t) = stmt.query_row([path], read).optional()? {
                out.push(t);
            }
        }
        Ok(out)
    }

    /// Stores a downloaded cover for `paths` (an album's tracks). A track's own cover,
    /// if it gets one, still comes first. Returns the art key, or None if the image
    /// couldn't be read.
    pub fn store_fetched_art(&self, paths: &[String], image: &[u8]) -> Result<Option<String>> {
        let Some(key) = art::store(&self.art_dir, image) else {
            return Ok(None);
        };
        let tx = self.db.unchecked_transaction()?;
        {
            let mut insert =
                tx.prepare("INSERT OR REPLACE INTO fetched_art (path, art) VALUES (?1, ?2)")?;
            for path in paths {
                insert.execute(params![path, key])?;
            }
        }
        tx.commit()?;
        Ok(Some(key))
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
            .prepare("SELECT id, name, source FROM playlists ORDER BY created, id")?
            .query_map([], |r| {
                Ok(Playlist { id: r.get(0)?, name: r.get(1)?, paths: Vec::new(), source: r.get(2)? })
            })?
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
        self.db.execute(
            "INSERT OR IGNORE INTO ignored_playlist_files (source)
             SELECT source FROM playlists WHERE id = ?1 AND source IS NOT NULL",
            [id],
        )?;
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A tenth of a second of silent 16-bit stereo WAV.
    fn wav(path: &Path) {
        let samples = 4410u32 * 2;
        let mut b = Vec::new();
        b.extend_from_slice(b"RIFF");
        b.extend_from_slice(&(36 + samples * 2).to_le_bytes());
        b.extend_from_slice(b"WAVEfmt ");
        b.extend_from_slice(&16u32.to_le_bytes());
        b.extend_from_slice(&1u16.to_le_bytes());
        b.extend_from_slice(&2u16.to_le_bytes());
        b.extend_from_slice(&44100u32.to_le_bytes());
        b.extend_from_slice(&(44100u32 * 4).to_le_bytes());
        b.extend_from_slice(&4u16.to_le_bytes());
        b.extend_from_slice(&16u16.to_le_bytes());
        b.extend_from_slice(b"data");
        b.extend_from_slice(&(samples * 2).to_le_bytes());
        b.resize(b.len() + samples as usize * 2, 0);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, b).unwrap();
    }

    fn set_mtime(path: &Path, secs: u64) {
        let file = std::fs::File::options().write(true).open(path).unwrap();
        file.set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs)).unwrap();
    }

    #[test]
    fn playlist_files_become_playlists_and_follow_the_file() {
        let root = std::env::temp_dir().join(format!("halcyn-playlists-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let music = root.join("Music");
        for name in ["A/one.wav", "A/two.wav", "B/three.wav"] {
            wav(&music.join(name));
        }
        let list = music.join("lists/road trip.m3u8");
        std::fs::create_dir_all(list.parent().unwrap()).unwrap();
        std::fs::write(&list, "#EXTM3U\n../B/three.wav\n../A/one.wav\nhttp://radio/x\n").unwrap();
        std::fs::write(music.join("radio.pls"), "[playlist]\nFile1=http://radio/y\n").unwrap();

        let mut lib = Library::open(&root.join("data"), &root.join("cache")).unwrap();
        lib.set_folders(&[music.to_string_lossy().into_owned()]).unwrap();
        lib.scan(|_, _| {}).unwrap();
        let path = |p: &str| music.join(p).to_string_lossy().into_owned();

        // The web-radio-only list isn't made into an empty playlist.
        let lists = lib.playlists().unwrap();
        assert_eq!(lists.len(), 1);
        assert_eq!(lists[0].name, "road trip");
        assert_eq!(lists[0].paths, vec![path("B/three.wav"), path("A/one.wav")]);
        assert_eq!(lists[0].source.as_deref(), Some(list.to_string_lossy().as_ref()));

        // The file changes: so does the playlist, title and all.
        std::fs::write(&list, "#PLAYLIST:Road\n../A/two.wav\n").unwrap();
        set_mtime(&list, 2_000_000_000);
        lib.scan(|_, _| {}).unwrap();
        let lists = lib.playlists().unwrap();
        assert_eq!(
            (lists[0].name.as_str(), lists[0].paths.clone()),
            ("Road", vec![path("A/two.wav")])
        );

        // Deleted in the app: stays deleted.
        lib.delete_playlist(lists[0].id).unwrap();
        lib.scan(|_, _| {}).unwrap();
        assert!(lib.playlists().unwrap().is_empty());

        // The file goes and comes back: it's a playlist again.
        std::fs::remove_file(&list).unwrap();
        lib.scan(|_, _| {}).unwrap();
        std::fs::write(&list, "../A/one.wav\n").unwrap();
        lib.scan(|_, _| {}).unwrap();
        assert_eq!(lib.playlists().unwrap().len(), 1);

        // And when the file is removed, its playlist is too.
        std::fs::remove_file(&list).unwrap();
        lib.scan(|_, _| {}).unwrap();
        assert!(lib.playlists().unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_playlist_file_from_elsewhere_finds_its_songs() {
        let root = std::env::temp_dir().join(format!("halcyn-import-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let music = root.join("Music");
        for name in ["Artist/Album/one.wav", "Artist/Album/two.wav"] {
            wav(&music.join(name));
        }
        let mut lib = Library::open(&root.join("data"), &root.join("cache")).unwrap();
        lib.set_folders(&[music.to_string_lossy().into_owned()]).unwrap();
        lib.scan(|_, _| {}).unwrap();
        let path = |p: &str| music.join(p).to_string_lossy().into_owned();

        // Written on a Windows PC, read from Downloads.
        let xspf = r#"<?xml version="1.0"?><playlist><title>Mine &amp; yours</title><trackList>
            <track><location>file:///D:/Music/Artist/Album/two.wav</location></track>
            <track><location>file:///D:/Music/Artist/Album/gone.wav</location></track>
            <track><location>D:\Music\Artist\Album\one.wav</location></track>
            </trackList></playlist>"#;
        let (name, paths, entries) =
            lib.read_playlist_file("/home/me/Downloads/mine.xspf", "mine.xspf", xspf.as_bytes()).unwrap();
        assert_eq!(name, "Mine & yours");
        assert_eq!(paths, vec![path("Artist/Album/two.wav"), path("Artist/Album/one.wav")]);
        assert_eq!(entries, 3);

        // No title: the file's name.
        let (name, paths, _) = lib.read_playlist_file("/cache/x", "Road Trip.m3u", b"Album/one.wav\n").unwrap();
        assert_eq!((name.as_str(), paths), ("Road Trip", vec![path("Artist/Album/one.wav")]));
        // Reading it adds no playlist by itself.
        assert!(lib.playlists().unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_fetched_cover_shows_and_survives_a_rescan() {
        let root = std::env::temp_dir().join(format!("halcyn-fetched-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let song = root.join("Music/A/one.wav");
        wav(&song);
        let mut lib = Library::open(&root.join("data"), &root.join("cache")).unwrap();
        lib.set_folders(&[root.join("Music").to_string_lossy().into_owned()]).unwrap();
        lib.scan(|_, _| {}).unwrap();
        assert_eq!(lib.tracks().unwrap()[0].art, None);

        let mut png = Vec::new();
        image::RgbImage::from_pixel(64, 64, image::Rgb([200, 40, 90]))
            .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .unwrap();
        let path = song.to_string_lossy().into_owned();
        let key = lib.store_fetched_art(&[path], &png).unwrap().unwrap();
        assert_eq!(lib.tracks().unwrap()[0].art.as_deref(), Some(key.as_str()));
        assert!(root.join(format!("cache/art/{key}-512.jpg")).exists());

        // The file changes (and still has no cover): the downloaded one stays.
        wav(&song);
        set_mtime(&song, 2_000_000_000);
        lib.scan(|_, _| {}).unwrap();
        assert_eq!(lib.tracks().unwrap()[0].art.as_deref(), Some(key.as_str()));
        assert_eq!(lib.store_fetched_art(&[], b"not an image").unwrap(), None);
        let _ = std::fs::remove_dir_all(&root);
    }
}
