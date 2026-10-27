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

/// What a saved song is tagged with.
pub struct Tags<'a> {
    pub title: &'a str,
    pub artists: &'a [String],
    pub album: Option<&'a str>,
    /// The cover, as JPEG.
    pub cover: Option<Vec<u8>>,
}

/// Saves the streamed song at `path` in `folder` as `Artist/Album/Title.flac` (or `.m4a`),
/// tags and cover written in. A song without an album gets a folder of its own name. A
/// song already saved there is left as it is. Returns the file.
pub fn save(path: &str, folder: &Path, tags: &Tags) -> Result<PathBuf> {
    let artist = tags.artists.first().map_or("Unknown artist", String::as_str);
    let album = tags.album.filter(|a| !a.trim().is_empty()).unwrap_or(tags.title);
    let dir = folder.join(safe_name(artist)).join(safe_name(album));
    let name = safe_name(tags.title);
    for ext in ["flac", "m4a"] {
        let saved = dir.join(format!("{name}.{ext}"));
        if saved.exists() {
            return Ok(saved);
        }
    }
    let cached = download(path)?;
    std::fs::create_dir_all(&dir)?;
    // Tidal sends most FLAC inside MP4: unwrapped into a .flac file like any other. What
    // isn't FLAC (YouTube's AAC) stays an .m4a.
    let flac = dir.join(format!(".{name}.part.flac"));
    let ext = if cached.extension().is_some_and(|e| e == "flac") {
        std::fs::copy(&cached, &flac)?;
        "flac"
    } else if unwrap_flac(&cached, &flac).unwrap_or(false) {
        "flac"
    } else {
        let _ = std::fs::remove_file(&flac);
        std::fs::copy(&cached, dir.join(format!(".{name}.part.m4a")))?;
        "m4a"
    };
    let part = dir.join(format!(".{name}.part.{ext}"));
    if let Err(e) = write_tags(&part, tags) {
        // The song is still worth having untagged.
        eprintln!("tagging {}: {e}", part.display());
    }
    let saved = dir.join(format!("{name}.{ext}"));
    std::fs::rename(&part, &saved)?;
    Ok(saved)
}

/// Copies the FLAC stream out of an MP4 into a plain FLAC file: its STREAMINFO, then the
/// frames as they are (each MP4 sample is one). False when the MP4 holds something else.
fn unwrap_flac(mp4: &Path, out: &Path) -> Result<bool> {
    use std::io::Write;
    use symphonia::core::codecs::audio::well_known::CODEC_ID_FLAC;
    use symphonia::core::formats::probe::Hint;
    use symphonia::core::formats::{FormatOptions, TrackType};
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;

    let stream = MediaSourceStream::new(Box::new(File::open(mp4)?), Default::default());
    let mut format = symphonia::default::get_probe().probe(
        Hint::new().with_extension("mp4"),
        stream,
        FormatOptions::default(),
        MetadataOptions::default(),
    )?;
    let Some(track) = format.default_track(TrackType::Audio) else { return Ok(false) };
    let id = track.id;
    let Some(params) = track.codec_params.as_ref().and_then(|p| p.audio()) else { return Ok(false) };
    let Some(info) = params.extra_data.clone().filter(|i| params.codec == CODEC_ID_FLAC && i.len() == 34)
    else {
        return Ok(false);
    };
    let mut info = info.to_vec();
    let mut file = std::io::BufWriter::new(File::create(out)?);
    // "fLaC", then STREAMINFO as the only (last) metadata block; its length is filled in
    // below once the frames are counted.
    file.write_all(b"fLaC\x80\x00\x00\x22")?;
    file.write_all(&info)?;
    let mut samples = 0u64;
    loop {
        let packet = match format.next_packet() {
            Ok(Some(packet)) => packet,
            Ok(None) => break,
            Err(symphonia::core::errors::Error::IoError(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(e.into()),
        };
        if packet.track_id == id {
            samples += packet.dur.get();
            file.write_all(&packet.data)?;
        }
    }
    // The total length (a DASH stream's STREAMINFO says 0, which players read as 0:00):
    // the low 36 bits of bytes 10..18.
    let packed = u64::from_be_bytes(info[10..18].try_into()?);
    let packed = (packed & !((1u64 << 36) - 1)) | (samples & ((1u64 << 36) - 1));
    info[10..18].copy_from_slice(&packed.to_be_bytes());
    let mut file = file.into_inner().map_err(|e| e.into_error())?;
    use std::io::{Seek, SeekFrom};
    file.seek(SeekFrom::Start(8))?;
    file.write_all(&info)?;
    Ok(samples > 0)
}

fn write_tags(file: &Path, tags: &Tags) -> Result<()> {
    use lofty::config::WriteOptions;
    use lofty::picture::{MimeType, Picture, PictureType};
    use lofty::prelude::*;
    use lofty::tag::{ItemKey, Tag};

    let mut tagged = lofty::read_from_path(file)?;
    if tagged.primary_tag().is_none() {
        tagged.insert_tag(Tag::new(tagged.primary_tag_type()));
    }
    let tag = tagged.primary_tag_mut().ok_or_else(|| anyhow!("no tag"))?;
    tag.set_title(tags.title.to_owned());
    tag.set_artist(tags.artists.join(", "));
    if let Some(album) = tags.album {
        tag.set_album(album.to_owned());
    }
    if let Some(lead) = tags.artists.first() {
        tag.insert_text(ItemKey::AlbumArtist, lead.clone());
    }
    if let Some(cover) = &tags.cover {
        tag.remove_picture_type(PictureType::CoverFront);
        tag.push_picture(
            Picture::unchecked(cover.clone()).pic_type(PictureType::CoverFront).mime_type(MimeType::Jpeg).build(),
        );
    }
    tag.save_to_path(file, WriteOptions::default())?;
    Ok(())
}

/// A file or folder name from a title: no characters any of Linux, Windows or Android
/// refuse, not too long, and no trailing dots or spaces (Windows drops them).
pub fn safe_name(text: &str) -> String {
    let cleaned: String = text
        .chars()
        .map(|c| if c.is_control() || r#"/\:*?"<>|"#.contains(c) { '_' } else { c })
        .take(120)
        .collect();
    let cleaned = cleaned.trim().trim_end_matches(['.', ' ']).to_owned();
    if cleaned.is_empty() { "_".into() } else { cleaned }
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
        // Saved as a tagged file of its own, Artist/Album/Title.
        let song = found.iter().find(|t| t.quality.as_deref() == Some("Lossless")).unwrap();
        let tags = Tags { title: &song.title, artists: &song.artists, album: song.album.as_deref(), cover: None };
        let saved = save(&song.path, &tmp.join("Downloads"), &tags).unwrap();
        let tagged = lofty::read_from_path(&saved).unwrap();
        use lofty::prelude::*;
        println!(
            "saved {} ({} bytes, {:?}, title {:?})",
            saved.display(),
            std::fs::metadata(&saved).unwrap().len(),
            tagged.file_type(),
            tagged.primary_tag().and_then(|t| t.title()),
        );
        assert_eq!(tagged.primary_tag().and_then(|t| t.title()).as_deref(), Some(song.title.as_str()));
        if let Ok(keep) = std::env::var("HALCYN_KEEP_SAVED") {
            std::fs::copy(&saved, keep).unwrap();
        }
        let _ = std::fs::remove_dir_all(tmp);
    }

    #[test]
    fn names_are_safe_everywhere() {
        assert_eq!(safe_name("AC/DC: Live?"), "AC_DC_ Live_");
        assert_eq!(safe_name("Vol. 2..."), "Vol. 2");
        assert_eq!(safe_name("  "), "_");
        assert_eq!(safe_name(&"x".repeat(300)).len(), 120);
    }

    #[test]
    fn a_saved_song_is_tagged_and_kept() {
        let tmp = std::env::temp_dir().join(format!("halcyn-save-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        let _ = DIRS.set(Dirs { cache: tmp.join("streams") });
        // A finished download in the stream cache, as `open` leaves it.
        let cache = cache_dir();
        std::fs::create_dir_all(&cache).unwrap();
        // The smallest FLAC there is: its STREAMINFO (44.1 kHz, stereo, 16-bit), no audio.
        let info = (44_100u64 << 44) | (1 << 41) | (15 << 36);
        let flac = [
            &b"fLaC\x80\x00\x00\x22\x10\x00\x10\x00\x00\x00\x00\x00\x00\x00"[..],
            &info.to_be_bytes(),
            &[0; 16],
        ]
        .concat();
        std::fs::write(cache.join("tidal-1.flac"), flac).unwrap();
        std::fs::write(cache.join("tidal-1.done"), b"").unwrap();
        let artists = vec!["Daft Punk".to_owned(), "Pharrell Williams".to_owned()];
        let tags = Tags { title: "Get Lucky", artists: &artists, album: Some("R.A.M."), cover: None };
        let saved = save("tidal:1", &tmp.join("Downloads"), &tags).unwrap();
        assert_eq!(saved, tmp.join("Downloads/Daft Punk/R.A.M/Get Lucky.flac"));
        let tagged = lofty::read_from_path(&saved).unwrap();
        use lofty::prelude::*;
        let tag = tagged.primary_tag().unwrap();
        assert_eq!(tag.title().as_deref(), Some("Get Lucky"));
        assert_eq!(tag.artist().as_deref(), Some("Daft Punk, Pharrell Williams"));
        // Saving it again keeps the file.
        assert_eq!(save("tidal:1", &tmp.join("Downloads"), &tags).unwrap(), saved);
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
        let song = &found[0];
        let tags = Tags { title: &song.title, artists: &song.artists, album: song.album.as_deref(), cover: None };
        let saved = save(&song.path, &tmp.join("Downloads"), &tags).unwrap();
        let tagged = lofty::read_from_path(&saved).unwrap();
        use lofty::prelude::*;
        println!("saved {} ({:?})", saved.display(), tagged.primary_tag().and_then(|t| t.title()));
        assert_eq!(tagged.primary_tag().and_then(|t| t.title()).as_deref(), Some(song.title.as_str()));
        let _ = std::fs::remove_dir_all(tmp);
    }
}
