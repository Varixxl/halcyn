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

pub use crate::api::streaming::{
    RemoteAlbum, RemoteArtist, RemoteArtistPage, RemotePlaylist, RemoteShelf, RemoteTrack,
};

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

/// A streamed song, opened for the decoder.
pub struct Opened {
    pub media: Box<dyn MediaSource>,
    /// What kind of file it is.
    pub ext: &'static str,
    /// Its length in seconds, when the service says: a DASH stream's or WebM's container
    /// doesn't, and the player needs it to show progress and seek.
    pub secs: Option<f64>,
}

/// The song at `path` for the decoder.
pub fn open(path: &str) -> Result<Opened> {
    let (service, id) = parse(path).ok_or_else(|| anyhow!("{path} isn't a streamed song"))?;
    let dir = cache_dir();
    let key = format!("{service}-{id}");
    for ext in ["flac", "mp4", "m4a", "webm"] {
        if let Some(file) = download::cached(&dir, &key, ext) {
            let file = File::options().read(true).write(true).open(&file)?;
            // Played again: the last to go when the cache is full.
            let _ = file.set_modified(SystemTime::now());
            return Ok(Opened { media: Box::new(file), ext, secs: download::length(&dir, &key) });
        }
    }
    let (parts, ext, total, secs) = match service {
        "tidal" => {
            let plan = tidal::stream(id)?;
            (plan.parts, plan.ext, None, plan.secs)
        }
        _ => {
            std::fs::create_dir_all(&dir)?;
            let url = youtube::audio_url(id, &dir)?;
            let (parts, total) = youtube::ranges(&url);
            (parts, youtube::kind(&url), total, youtube::duration(&url))
        }
    };
    let media = download::start(&dir, &key, ext, parts, total, secs)?;
    Ok(Opened { media: Box::new(media), ext, secs })
}

/// The whole song at `path`, downloaded into the stream cache (casting sends it on).
pub fn download(path: &str) -> Result<PathBuf> {
    let (service, id) = parse(path).ok_or_else(|| anyhow!("{path} isn't a streamed song"))?;
    let Opened { mut media, ext, .. } = open(path)?;
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
    /// The recording's ISRC, so the file is known as the same song on any service.
    pub isrc: Option<&'a str>,
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
    for ext in ["flac", "m4a", "opus"] {
        let saved = dir.join(format!("{name}.{ext}"));
        if saved.exists() {
            return Ok(saved);
        }
    }
    let cached = download(path)?;
    std::fs::create_dir_all(&dir)?;
    // Tidal sends most FLAC inside MP4: unwrapped into a .flac file like any other.
    // YouTube's Opus comes in WebM, which taggers and players mostly don't take: moved into
    // an .opus file as it is. What's left (YouTube's AAC) stays an .m4a.
    let flac = dir.join(format!(".{name}.part.flac"));
    let ext = if cached.extension().is_some_and(|e| e == "flac") {
        std::fs::copy(&cached, &flac)?;
        "flac"
    } else if unwrap_flac(&cached, &flac).unwrap_or(false) {
        "flac"
    } else if cached.extension().is_some_and(|e| e == "webm") {
        let _ = std::fs::remove_file(&flac);
        let opus = dir.join(format!(".{name}.part.opus"));
        if let Err(e) = webm_to_ogg(&cached, &opus) {
            let _ = std::fs::remove_file(&opus);
            return Err(e);
        }
        "opus"
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

/// Moves the Opus stream out of a WebM into an Ogg Opus file (RFC 7845), packets as they are.
fn webm_to_ogg(webm: &Path, out: &Path) -> Result<()> {
    use std::io::Write;
    use symphonia::core::formats::probe::Hint;
    use symphonia::core::formats::{FormatOptions, TrackType};
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;

    let stream = MediaSourceStream::new(Box::new(File::open(webm)?), Default::default());
    let mut format = symphonia::default::get_probe().probe(
        Hint::new().with_extension("webm"),
        stream,
        FormatOptions::default(),
        MetadataOptions::default(),
    )?;
    let track = format.default_track(TrackType::Audio).ok_or_else(|| anyhow!("no audio in the WebM"))?;
    let id = track.id;
    let params = track.codec_params.as_ref().and_then(|p| p.audio()).ok_or_else(|| anyhow!("no audio in the WebM"))?;
    if params.codec != symphonia::core::codecs::audio::well_known::CODEC_ID_OPUS {
        anyhow::bail!("the WebM isn't Opus");
    }
    let head = params
        .extra_data
        .as_deref()
        .filter(|h| h.starts_with(b"OpusHead"))
        .ok_or_else(|| anyhow!("the WebM has no OpusHead"))?
        .to_vec();
    let pre_skip = u16::from_le_bytes([head[10], head[11]]) as u64;

    let mut ogg = OggWriter { file: std::io::BufWriter::new(File::create(out)?), serial: 0x4861_6c63, sequence: 0 };
    ogg.page(&[&head], 0, 0x02)?;
    let vendor = b"Halcyn";
    let mut tags = b"OpusTags".to_vec();
    tags.extend((vendor.len() as u32).to_le_bytes());
    tags.extend(vendor);
    tags.extend(0u32.to_le_bytes());
    ogg.page(&[&tags], 0, 0)?;

    // Audio pages of about 4 KB, each marked with where its last packet ends.
    let mut granule = pre_skip;
    let mut pending: Vec<Vec<u8>> = Vec::new();
    let mut size = 0;
    loop {
        let packet = match format.next_packet() {
            Ok(Some(packet)) => packet,
            Ok(None) => break,
            Err(symphonia::core::errors::Error::IoError(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(e.into()),
        };
        if packet.track_id != id || packet.data.is_empty() {
            continue;
        }
        let frames = unsafe { crate::engine::opus::ffi::opus_packet_get_nb_samples(packet.data.as_ptr(), packet.data.len() as i32, 48_000) };
        if frames <= 0 {
            continue;
        }
        if size + packet.data.len() > 4096 && !pending.is_empty() {
            let parts: Vec<&[u8]> = pending.iter().map(Vec::as_slice).collect();
            ogg.page(&parts, granule, 0)?;
            pending.clear();
            size = 0;
        }
        granule += frames as u64;
        size += packet.data.len();
        pending.push(packet.data.to_vec());
    }
    let parts: Vec<&[u8]> = pending.iter().map(Vec::as_slice).collect();
    ogg.page(&parts, granule, 0x04)?;
    ogg.file.flush()?;
    Ok(())
}

struct OggWriter<W: std::io::Write> {
    file: W,
    serial: u32,
    sequence: u32,
}

impl<W: std::io::Write> OggWriter<W> {
    /// One page holding whole `packets` (each under 64 KB, at most 255 lacing values in all).
    fn page(&mut self, packets: &[&[u8]], granule: u64, flags: u8) -> Result<()> {
        let mut lacing = Vec::new();
        for p in packets {
            lacing.extend(std::iter::repeat_n(255u8, p.len() / 255));
            lacing.push((p.len() % 255) as u8);
        }
        if lacing.len() > 255 {
            anyhow::bail!("an Ogg page can't hold that much");
        }
        let mut page = b"OggS\0".to_vec();
        page.push(flags);
        page.extend(granule.to_le_bytes());
        page.extend(self.serial.to_le_bytes());
        page.extend(self.sequence.to_le_bytes());
        page.extend([0; 4]);
        page.push(lacing.len() as u8);
        page.extend(&lacing);
        for p in packets {
            page.extend_from_slice(p);
        }
        let crc = ogg_crc(&page);
        page[22..26].copy_from_slice(&crc.to_le_bytes());
        self.file.write_all(&page)?;
        self.sequence += 1;
        Ok(())
    }
}

/// Ogg's CRC-32: polynomial 0x04c11db7, not reflected, starting at 0.
fn ogg_crc(data: &[u8]) -> u32 {
    let mut crc = 0u32;
    for &b in data {
        crc ^= (b as u32) << 24;
        for _ in 0..8 {
            crc = if crc & 0x8000_0000 != 0 { (crc << 1) ^ 0x04c1_1db7 } else { crc << 1 };
        }
    }
    crc
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
    if let Some(isrc) = tags.isrc {
        tag.insert_text(ItemKey::Isrc, isrc.to_owned());
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
        print_artist(&tidal::search_artists("radiohead").unwrap(), tidal::artist);
        let albums = tidal::search_albums("radiohead ok computer").unwrap();
        println!("albums: {:?}", albums.iter().take(3).collect::<Vec<_>>());
        let id = albums[0].id.strip_prefix("album:").unwrap();
        println!("album: {} songs", tidal::album(id).unwrap().len());
        let isrc = found.iter().find_map(|t| t.isrc.clone()).unwrap();
        let same = tidal::by_isrc(&isrc).unwrap();
        println!(
            "by ISRC {isrc}: {:?}",
            same.iter().map(|t| (&t.path, &t.title, &t.album, &t.quality)).collect::<Vec<_>>()
        );
        assert!(!same.is_empty());
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
        let tags = Tags { title: &song.title, artists: &song.artists, album: song.album.as_deref(), isrc: song.isrc.as_deref(), cover: None };
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

    /// Moves HALCYN_TEST_WEBM (YouTube's Opus) into an Ogg file, tags it, and leaves it at
    /// HALCYN_TEST_OGG for checking with ffmpeg.
    #[test]
    #[ignore]
    fn webm_becomes_ogg() {
        let webm = std::env::var("HALCYN_TEST_WEBM").expect("HALCYN_TEST_WEBM");
        let out = PathBuf::from(std::env::var("HALCYN_TEST_OGG").expect("HALCYN_TEST_OGG"));
        webm_to_ogg(Path::new(&webm), &out).unwrap();
        let artists = vec!["Someone".to_owned()];
        write_tags(&out, &Tags { title: "A song", artists: &artists, album: Some("An album"), isrc: None, cover: None }).unwrap();
        let tagged = lofty::read_from_path(&out).unwrap();
        use lofty::prelude::*;
        assert_eq!(tagged.primary_tag().and_then(|t| t.title()).as_deref(), Some("A song"));
        let mut source = Source::open(&out).unwrap();
        let mut buf = Vec::new();
        let mut frames = 0;
        while source.read(Samples::Float(&mut buf)).unwrap() {
            frames += buf.len() / 2;
        }
        println!("{:?}, decoded {frames} frames", source.info);
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
        let tags = Tags { title: "Get Lucky", artists: &artists, album: Some("R.A.M."), isrc: Some("USQX91300108"), cover: None };
        let saved = save("tidal:1", &tmp.join("Downloads"), &tags).unwrap();
        assert_eq!(saved, tmp.join("Downloads/Daft Punk/R.A.M/Get Lucky.flac"));
        let tagged = lofty::read_from_path(&saved).unwrap();
        use lofty::prelude::*;
        let tag = tagged.primary_tag().unwrap();
        assert_eq!(tag.title().as_deref(), Some("Get Lucky"));
        assert_eq!(tag.artist().as_deref(), Some("Daft Punk, Pharrell Williams"));
        assert_eq!(tag.get_string(lofty::tag::ItemKey::Isrc), Some("USQX91300108"));
        // Saving it again keeps the file.
        assert_eq!(save("tidal:1", &tmp.join("Downloads"), &tags).unwrap(), saved);
        let _ = std::fs::remove_dir_all(tmp);
    }

    /// Plays a real YouTube Music song (signed out; needs yt-dlp):
    fn print_artist(found: &[RemoteArtist], page: fn(&str) -> Result<RemoteArtistPage>) {
        let names: Vec<_> = found.iter().take(3).map(|a| (&a.id, &a.name)).collect();
        println!("artists: {names:?}");
        let p = page(&found[0].id).unwrap();
        println!(
            "artist {:?}: {} songs (first {:?}), albums {:?}, singles {}, similar {:?}",
            p.artist,
            p.tracks.len(),
            p.tracks.first().map(|t| &t.title),
            p.albums.iter().map(|a| (&a.title, a.year, &a.kind, &a.artists)).collect::<Vec<_>>(),
            p.singles.len(),
            p.similar.iter().map(|a| &a.name).collect::<Vec<_>>()
        );
        assert!(!p.tracks.is_empty() && !p.albums.is_empty());
    }

    /// `cargo test live_youtube_artists -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn live_youtube_artists() {
        print_artist(&youtube::search_artists("radiohead").unwrap(), youtube::artist);
        let albums = youtube::search_albums("radiohead ok computer").unwrap();
        println!("albums: {:?}", albums.iter().take(3).collect::<Vec<_>>());
        let songs = youtube::playlist(&albums[0].id).unwrap();
        let first = songs.first().map(|t| (&t.title, &t.artists));
        println!("album: {} songs, first {first:?}", songs.len());
        assert_eq!(songs[0].artists, ["Radiohead"]);
    }

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
        let tags = Tags { title: &song.title, artists: &song.artists, album: song.album.as_deref(), isrc: song.isrc.as_deref(), cover: None };
        let saved = save(&song.path, &tmp.join("Downloads"), &tags).unwrap();
        let tagged = lofty::read_from_path(&saved).unwrap();
        use lofty::prelude::*;
        println!("saved {} ({:?})", saved.display(), tagged.primary_tag().and_then(|t| t.title()));
        assert_eq!(tagged.primary_tag().and_then(|t| t.title()).as_deref(), Some(song.title.as_str()));
        let _ = std::fs::remove_dir_all(tmp);
    }
}
