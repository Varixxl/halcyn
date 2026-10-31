//! Tidal and YouTube Music: signing in, searching, the accounts' playlists and home pages,
//! and remembering their songs so they can sit in playlists and the queue like files.

use std::collections::{HashMap, HashSet};

use anyhow::{anyhow, Result};
use flutter_rust_bridge::DartFnFuture;
use rayon::prelude::*;

use crate::api::library::{with, Track};
use crate::streaming::{self, http, tidal, youtube};

/// A song on a service, before it's remembered (see `streaming_remember`).
#[derive(Clone, Debug)]
pub struct RemoteTrack {
    /// `tidal:<id>` or `ytm:<videoId>`.
    pub path: String,
    pub title: String,
    pub artists: Vec<String>,
    pub album: Option<String>,
    pub duration_secs: f64,
    pub art_url: Option<String>,
    /// "Hi-res", "Lossless" or "AAC": the best the service lists it in.
    pub quality: Option<String>,
    pub isrc: Option<String>,
}

#[derive(Clone, Debug)]
pub struct RemotePlaylist {
    /// "tidal" or "ytm".
    pub service: String,
    /// Tidal: a playlist's uuid, `favorites`, `mix:<id>` or `album:<id>`. YouTube Music: a
    /// playlist id, "LM" (liked songs) or an album's "MPREb_…".
    pub id: String,
    pub name: String,
    pub count: Option<u32>,
    pub art_url: Option<String>,
}

/// A row of a service's home page: songs, or playlists, mixes and albums to open.
#[derive(Clone, Debug)]
pub struct RemoteShelf {
    pub service: String,
    pub title: String,
    pub tracks: Vec<RemoteTrack>,
    pub lists: Vec<RemotePlaylist>,
}

/// An album on a service. Open it as the `RemotePlaylist` with the same service and id.
#[derive(Clone, Debug)]
pub struct RemoteAlbum {
    pub service: String,
    /// Tidal: `album:<id>`. YouTube Music: `MPREb_…`.
    pub id: String,
    pub title: String,
    pub artists: Vec<String>,
    pub year: Option<u32>,
    /// "Album", "EP" or "Single", when the service says.
    pub kind: Option<String>,
    pub art_url: Option<String>,
}

#[derive(Clone, Debug)]
pub struct RemoteArtist {
    pub service: String,
    /// Tidal: the artist's number. YouTube Music: a channel id, `UC…`.
    pub id: String,
    pub name: String,
    pub art_url: Option<String>,
}

/// What a service has of an artist: their popular songs, albums, singles and EPs, and
/// artists like them.
#[derive(Clone, Debug)]
pub struct RemoteArtistPage {
    pub artist: RemoteArtist,
    pub tracks: Vec<RemoteTrack>,
    pub albums: Vec<RemoteAlbum>,
    pub singles: Vec<RemoteAlbum>,
    pub similar: Vec<RemoteArtist>,
}

pub struct StreamingAccounts {
    /// Whether this build can sign in to Tidal (it has the app keys).
    pub tidal_available: bool,
    /// The signed-in account's name ("" when unknown), or None.
    pub tidal: Option<String>,
    pub youtube: Option<String>,
    /// Whether YouTube Music songs can play here: yt-dlp on a computer, the app's own
    /// extractor on a phone.
    pub youtube_playable: bool,
}

/// Reads the saved sign-ins. Call once at startup, after `library_open`.
pub fn streaming_init(data_dir: String, cache_dir: String) {
    streaming::init(std::path::Path::new(&data_dir), std::path::Path::new(&cache_dir));
}

pub fn streaming_accounts() -> StreamingAccounts {
    StreamingAccounts {
        tidal_available: tidal::available(),
        tidal: tidal::session().map(|s| s.name.unwrap_or_default()),
        youtube: youtube::account(),
        youtube_playable: youtube::has_resolver() || which("yt-dlp"),
    }
}

fn which(program: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|paths| {
        std::env::split_paths(&paths)
            .any(|dir| dir.join(program).is_file() || dir.join(format!("{program}.exe")).is_file())
    })
}

/// The Tidal page to sign in on. Tidal then sends the browser to `streaming_tidal_redirect`.
pub fn streaming_tidal_login_url() -> Result<String> {
    tidal::login_url()
}

#[flutter_rust_bridge::frb(sync)]
pub fn streaming_tidal_redirect() -> String {
    tidal::REDIRECT.into()
}

/// Finishes signing in with the address Tidal sent the browser to. Returns the name.
pub fn streaming_tidal_finish_login(redirected: String) -> Result<String> {
    Ok(tidal::finish_login(&redirected)?.name.unwrap_or_default())
}

pub fn streaming_tidal_sign_out() {
    tidal::sign_out();
}

/// Signs in to YouTube Music with a browser's cookie header. Returns the name.
pub fn streaming_youtube_sign_in(cookie: String) -> Result<String> {
    youtube::sign_in(&cookie)
}

/// Signs in to YouTube Music with the cookies of a browser on this computer (`firefox`,
/// `chrome`, `chromium`, `brave`, …), through yt-dlp.
pub fn streaming_youtube_sign_in_from_browser(browser: String) -> Result<String> {
    let dir = streaming::cache_dir();
    std::fs::create_dir_all(&dir)?;
    youtube::sign_in_from_browser(&browser, &dir)
}

pub fn streaming_youtube_sign_out() {
    youtube::sign_out();
}

/// The service's sign-in as JSON (for the Halcyn account's vault), or None when signed out.
pub fn streaming_export(service_name: String) -> Result<Option<String>> {
    Ok(match service(&service_name)? {
        "tidal" => tidal::export(),
        _ => youtube::export(),
    })
}

/// Signs in with a sign-in from `streaming_export` on another device.
pub fn streaming_import(service_name: String, saved: String) -> Result<()> {
    match service(&service_name)? {
        "tidal" => tidal::import(&saved),
        _ => youtube::import(&saved),
    }
}

/// The cover addresses of remembered streamed songs (None for a song without one), so a
/// playlist synced to another device can bring them along.
pub fn streaming_art_urls(paths: Vec<String>) -> Result<Vec<Option<String>>> {
    with(|l| l.stream_art_urls(&paths))
}

/// How far along the streamed song at `path` is downloading, from 0 to 1; None when it
/// isn't.
#[flutter_rust_bridge::frb(sync)]
pub fn streaming_download_progress(path: String) -> Option<f64> {
    let (service, id) = streaming::parse(&path)?;
    streaming::download::progress(&streaming::cache_dir(), &format!("{service}-{id}"))
}

/// Lets the app find YouTube audio addresses itself (the phone's extractor). The function
/// returns the address, or "" when it couldn't.
pub fn streaming_set_youtube_resolver(
    resolve: impl Fn(String) -> DartFnFuture<String> + Send + Sync + 'static,
) {
    youtube::set_resolver(Box::new(move |id: &str| {
        let url =
            flutter_rust_bridge::for_generated::futures::executor::block_on(resolve(id.to_owned()));
        if url.starts_with("http") {
            Ok(url)
        } else {
            Err(anyhow!(
                "YouTube wouldn't send the audio{}",
                if url.is_empty() { String::new() } else { format!(": {url}") }
            ))
        }
    }));
}

fn service(name: &str) -> Result<&str> {
    match name {
        "tidal" | "ytm" => Ok(name),
        _ => Err(anyhow!("no service called {name}")),
    }
}

pub fn streaming_search(service_name: String, query: String) -> Result<Vec<RemoteTrack>> {
    match service(&service_name)? {
        "tidal" => tidal::search(&query),
        _ => youtube::search(&query),
    }
}

/// The songs on a service that are the recording with this ISRC: Tidal looks it up; on
/// YouTube Music, searching for it finds the song first (the rest are unrelated).
pub fn streaming_by_isrc(service_name: String, isrc: String) -> Result<Vec<RemoteTrack>> {
    match service(&service_name)? {
        "tidal" => tidal::by_isrc(&isrc),
        _ => Ok(youtube::search(&isrc)?.into_iter().take(1).collect()),
    }
}

pub fn streaming_search_albums(service_name: String, query: String) -> Result<Vec<RemoteAlbum>> {
    match service(&service_name)? {
        "tidal" => tidal::search_albums(&query),
        _ => youtube::search_albums(&query),
    }
}

pub fn streaming_search_artists(service_name: String, query: String) -> Result<Vec<RemoteArtist>> {
    match service(&service_name)? {
        "tidal" => tidal::search_artists(&query),
        _ => youtube::search_artists(&query),
    }
}

pub fn streaming_artist(service_name: String, id: String) -> Result<RemoteArtistPage> {
    match service(&service_name)? {
        "tidal" => tidal::artist(&id),
        _ => youtube::artist(&id),
    }
}

pub fn streaming_playlists(service_name: String) -> Result<Vec<RemotePlaylist>> {
    match service(&service_name)? {
        "tidal" => tidal::playlists(),
        _ => youtube::playlists(),
    }
}

pub fn streaming_playlist_tracks(service_name: String, id: String) -> Result<Vec<RemoteTrack>> {
    match service(&service_name)? {
        "tidal" => match id.split_once(':') {
            Some(("mix", mix)) => tidal::mix(mix),
            Some(("album", album)) => tidal::album(album),
            _ => tidal::playlist(&id),
        },
        _ => youtube::playlist(&id),
    }
}

/// The service's suggestions for the user: YouTube Music's home page; Tidal's mixes.
pub fn streaming_home(service_name: String) -> Result<Vec<RemoteShelf>> {
    match service(&service_name)? {
        "tidal" => {
            let lists = tidal::mixes()?
                .into_iter()
                .map(|(name, sub, art, id)| RemotePlaylist {
                    service: "tidal".into(),
                    id: format!("mix:{id}"),
                    name: if sub.is_empty() { name } else { format!("{name} · {sub}") },
                    count: None,
                    art_url: art,
                })
                .collect::<Vec<_>>();
            Ok(if lists.is_empty() {
                vec![]
            } else {
                vec![RemoteShelf {
                    service: "tidal".into(),
                    title: "Your mixes".into(),
                    tracks: vec![],
                    lists,
                }]
            })
        }
        _ => youtube::home(),
    }
}

/// Songs like the streamed song at `path`.
pub fn streaming_radio(path: String) -> Result<Vec<RemoteTrack>> {
    match streaming::parse(&path) {
        Some(("tidal", id)) => tidal::radio(id),
        Some((_, id)) => youtube::radio(id),
        None => Err(anyhow!("{path} isn't a streamed song")),
    }
}

/// Adds a listen of a YouTube Music song to the account's history. (Tidal has no way to.)
pub fn streaming_record_listen(path: String) -> Result<()> {
    match streaming::parse(&path) {
        Some(("ytm", id)) => youtube::record_listen(id),
        _ => Ok(()),
    }
}

/// Likes the song on its service (Tidal: a favourite), or takes it back.
pub fn streaming_like(path: String, liked: bool) -> Result<()> {
    match streaming::parse(&path) {
        Some(("tidal", id)) => tidal::favourite(id, liked),
        Some((_, id)) => youtube::like(id, liked),
        None => Err(anyhow!("{path} isn't a streamed song")),
    }
}

/// Remembers streamed songs, downloading their covers, and returns them as tracks (in the
/// same order) for playlists and the queue.
pub fn streaming_remember(tracks: Vec<RemoteTrack>) -> Result<Vec<Track>> {
    let urls: Vec<String> = tracks
        .iter()
        .filter_map(|t| t.art_url.clone())
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    let (mut art, dir) = with(|l| Ok((l.known_stream_art(&urls)?, l.art_dir().to_path_buf())))?;
    let missing: Vec<&String> = urls.iter().filter(|u| !art.contains_key(*u)).collect();
    let pool = rayon::ThreadPoolBuilder::new().num_threads(8).build()?;
    let fetched: HashMap<String, String> = pool.install(|| {
        missing
            .par_iter()
            .filter_map(|url| {
                let (mut body, _) = http::get_reader(url).ok()?;
                let mut bytes = Vec::new();
                std::io::Read::read_to_end(
                    &mut std::io::Read::take(&mut body, 20 << 20),
                    &mut bytes,
                )
                .ok()?;
                crate::library::store_art(&dir, &bytes).map(|key| ((*url).clone(), key))
            })
            .collect()
    });
    art.extend(fetched);
    with(|l| l.remember_streams(&tracks, &art))
}

/// Downloads the whole streamed song at `path` (for casting it) and returns the file.
pub fn streaming_download(path: String) -> Result<String> {
    Ok(streaming::download(&path)?.to_string_lossy().into_owned())
}

/// Saves the streamed song at `path` in `folder` as `Artist/Album/Title.flac` (or `.m4a`)
/// with its tags and cover (`art`, from the art cache) written in. Returns the file; a song
/// already saved there is kept as it is.
pub fn streaming_save(
    path: String,
    folder: String,
    title: String,
    artists: Vec<String>,
    album: Option<String>,
    art: Option<String>,
    isrc: Option<String>,
) -> Result<String> {
    let cover = match art {
        Some(key) => {
            let dir = with(|l| Ok(l.art_dir().to_path_buf()))?;
            std::fs::read(dir.join(format!("{key}-full.jpg"))).ok()
        }
        None => None,
    };
    let tags =
        streaming::Tags { title: &title, artists: &artists, album: album.as_deref(), isrc: isrc.as_deref(), cover };
    Ok(streaming::save(&path, std::path::Path::new(&folder), &tags)?.to_string_lossy().into_owned())
}

/// Every streamed song remembered.
pub fn streaming_tracks() -> Result<Vec<Track>> {
    with(|l| l.stream_tracks())
}
