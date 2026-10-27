//! Songs from Tidal and YouTube Music. Their paths are `tidal:<id>` and `ytm:<videoId>`;
//! `open` turns one into something the decoder reads, downloading it into the stream cache
//! as it plays.

pub mod download;
pub mod http;
pub mod tidal;
pub mod youtube;

use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::SystemTime;

use anyhow::{anyhow, Result};
use symphonia::core::io::MediaSource;

pub use crate::api::streaming::{RemotePlaylist, RemoteShelf, RemoteTrack};

struct Dirs {
    cache: PathBuf,
}

static DIRS: OnceLock<Dirs> = OnceLock::new();

/// Reads the saved sign-ins. Call once at startup.
pub fn init(data: &Path, cache: &Path) {
    tidal::load(data.join("tidal.json"));
    youtube::load(data.join("youtube.json"));
    let _ = DIRS.set(Dirs { cache: cache.join("streams") });
}

/// Where songs are downloaded to while they play.
pub fn cache_dir() -> PathBuf {
    DIRS.get().map_or_else(|| std::env::temp_dir().join("halcyn-streams"), |d| d.cache.clone())
}

/// ("tidal" | "ytm", id) of a streamed song's path.
pub fn parse(path: &str) -> Option<(&str, &str)> {
    let (service, id) = path.split_once(':')?;
    (matches!(service, "tidal" | "ytm")
        && !id.is_empty()
        && id.chars().all(|c| c.is_alphanumeric() || c == '-' || c == '_'))
    .then_some((service, id))
}

pub fn is_stream(path: &Path) -> bool {
    path.to_str().is_some_and(|p| parse(p).is_some())
}

/// The song at `path` for the decoder, and what kind of file it is.
pub fn open(path: &str) -> Result<(Box<dyn MediaSource>, &'static str)> {
    let (service, id) = parse(path).ok_or_else(|| anyhow!("{path} isn't a streamed song"))?;
    let dir = cache_dir();
    let key = format!("{service}-{id}");
    for ext in ["flac", "mp4", "m4a"] {
        if let Some(file) = download::cached(&dir, &key, ext) {
            let file = File::options().read(true).write(true).open(&file)?;
            // Played again: the last to go when the cache is full.
            let _ = file.set_modified(SystemTime::now());
            return Ok((Box::new(file), ext));
        }
    }
    let (parts, ext, total) = match service {
        "tidal" => {
            let plan = tidal::stream(id)?;
            (plan.parts, plan.ext, None)
        }
        _ => {
            std::fs::create_dir_all(&dir)?;
            let (parts, total) = youtube::ranges(&youtube::audio_url(id, &dir)?);
            (parts, "m4a", total)
        }
    };
    Ok((Box::new(download::start(&dir, &key, ext, parts, total)?), ext))
}

/// The whole song at `path`, downloaded into the stream cache (casting sends it on).
pub fn download(path: &str) -> Result<PathBuf> {
    let (service, id) = parse(path).ok_or_else(|| anyhow!("{path} isn't a streamed song"))?;
    let (mut media, ext) = open(path)?;
    // Reading to the end waits for the download to finish.
    std::io::copy(&mut media, &mut std::io::sink())?;
    drop(media);
    download::cached(&cache_dir(), &format!("{service}-{id}"), ext)
        .ok_or_else(|| anyhow!("the download didn't finish"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::source::{Samples, Source};

    /// Plays real Tidal streams with a session from HALCYN_TEST_TIDAL (a JSON file with
    /// access_token, refresh_token, token_type), held in memory only:
    /// `HALCYN_TEST_TIDAL=… cargo test live_tidal -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn live_tidal() {
        let file = std::env::var("HALCYN_TEST_TIDAL").expect("HALCYN_TEST_TIDAL");
        let saved: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(file).unwrap()).unwrap();
        let tmp = std::env::temp_dir().join(format!("halcyn-live-{}", std::process::id()));
        let _ = DIRS.set(Dirs { cache: tmp.join("streams") });
        // tidalapi's file: each value as { "data": … }.
        let get =
            |k: &str| saved[k]["data"].as_str().or(saved[k].as_str()).unwrap_or("").to_owned();
        let access = get("access_token");
        let kind =
            Some(get("token_type")).filter(|k| !k.is_empty()).unwrap_or_else(|| "Bearer".into());
        let session = tidal::Session {
            access,
            refresh: get("refresh_token"),
            kind,
            expiry: 0.0,
            session: String::new(),
            country: "US".into(),
            user: 0,
            name: None,
        };
        tidal::use_in_memory(session).unwrap();
        let s = tidal::session().unwrap();
        println!("signed in: {} {} {:?}", s.user, s.country, s.name);
        let found = tidal::search("daft punk get lucky").unwrap();
        println!(
            "search: {} songs, first {:?}",
            found.len(),
            found.first().map(|t| (&t.title, &t.quality))
        );
        let lists = tidal::playlists().unwrap();
        println!(
            "playlists: {}",
            lists.iter().map(|p| p.name.as_str()).collect::<Vec<_>>().join(", ")
        );
        println!("mixes: {:?}", tidal::mixes().map(|m| m.len()));
        for t in found
            .iter()
            .filter(|t| t.quality.as_deref() == Some("Hi-res"))
            .take(1)
            .chain(found.iter().filter(|t| t.quality.as_deref() == Some("Lossless")).take(1))
        {
            let plan = tidal::stream(t.path.strip_prefix("tidal:").unwrap()).unwrap();
            println!("{} → {} parts, .{}, {}", t.title, plan.parts.len(), plan.ext, plan.quality);
            let started = std::time::Instant::now();
            let mut source = Source::open(Path::new(&t.path)).unwrap();
            println!("  opened in {:?}: {:?}", started.elapsed(), source.info);
            let mut buf = Vec::new();
            let mut frames = 0;
            for _ in 0..50 {
                assert!(source.read(Samples::Int(&mut buf)).unwrap());
                frames += buf.len() / source.info.channels;
            }
            println!("  decoded {frames} frames in {:?}", started.elapsed());
            let at = source.seek(60.0).unwrap();
            assert!(source.read(Samples::Int(&mut buf)).unwrap());
            println!(
                "  seeked to frame {at} ({:.1}s) in {:?}",
                at as f64 / source.info.sample_rate as f64,
                started.elapsed()
            );
            let mut end = at;
            while source.read(Samples::Int(&mut buf)).unwrap() {
                end += (buf.len() / source.info.channels) as u64;
            }
            println!(
                "  ended at {:.1}s (Tidal says {:.0}s) in {:?}",
                end as f64 / source.info.sample_rate as f64,
                t.duration_secs,
                started.elapsed()
            );
        }
        let _ = std::fs::remove_dir_all(tmp);
    }

    /// Plays a real YouTube Music song (signed out; needs yt-dlp):
    /// `cargo test live_youtube -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn live_youtube() {
        let tmp = std::env::temp_dir().join(format!("halcyn-live-yt-{}", std::process::id()));
        let _ = DIRS.set(Dirs { cache: tmp.join("streams") });
        let found = youtube::search("daft punk get lucky").unwrap();
        println!("search: {} songs, first {:?}", found.len(), found.first());
        let home = youtube::home().unwrap();
        println!(
            "home: {:?}",
            home.iter()
                .map(|s| format!("{} ({}+{})", s.title, s.tracks.len(), s.lists.len()))
                .collect::<Vec<_>>()
        );
        let radio = youtube::radio(found[0].path.strip_prefix("ytm:").unwrap()).unwrap();
        println!("radio: {} songs", radio.len());
        let started = std::time::Instant::now();
        let mut source = Source::open(Path::new(&found[0].path)).unwrap();
        println!("opened in {:?}: {:?}", started.elapsed(), source.info);
        let mut buf = Vec::new();
        let at = source.seek(90.0).unwrap();
        assert!(source.read(Samples::Float(&mut buf)).unwrap());
        println!(
            "seeked to {:.1}s in {:?}",
            at as f64 / source.info.sample_rate as f64,
            started.elapsed()
        );
        let file = download(&found[0].path).unwrap();
        println!(
            "downloaded {} ({} bytes)",
            file.display(),
            std::fs::metadata(&file).unwrap().len()
        );
        let _ = std::fs::remove_dir_all(tmp);
    }
}
