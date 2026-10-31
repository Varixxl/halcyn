//! YouTube Music through the API its web player uses (what ytmusicapi speaks), signed in
//! with the cookies of a browser that is. The answers are read by looking for the song and
//! playlist entries wherever they sit, so a reshuffle of YouTube's layout doesn't lose them.
//! The audio itself comes from yt-dlp on a computer, NewPipe's extractor on a phone (the
//! app registers it, see `set_resolver`): Premium's 256 kbps AAC when the account gets it,
//! else Opus (in WebM), which beats the 128 kbps AAC everyone gets.

use std::path::PathBuf;
use std::process::Command;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, Result};
use serde_json::{json, Value};
use sha1::{Digest, Sha1};

use super::http::{self, Body, Get, AGENT};
use super::{RemoteAlbum, RemoteArtist, RemoteArtistPage, RemotePlaylist, RemoteShelf, RemoteTrack};

const ORIGIN: &str = "https://music.youtube.com";
const DESKTOP_UA: &str = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0";

/// Finds a video's audio address: the phone's extractor, when the app has one.
type Resolver = Box<dyn Fn(&str) -> Result<String> + Send + Sync>;

struct State {
    /// `<data>/youtube.json`; None keeps the sign-in in memory only (tests).
    file: Option<PathBuf>,
    cookie: Option<String>,
    name: Option<String>,
    resolver: Option<Resolver>,
}

static STATE: Mutex<State> =
    Mutex::new(State { file: None, cookie: None, name: None, resolver: None });

pub fn load(file: PathBuf) {
    let saved =
        std::fs::read_to_string(&file).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok());
    let mut state = STATE.lock().unwrap();
    state.cookie = saved.as_ref().and_then(|v| v.s("cookie"));
    state.name = saved.as_ref().and_then(|v| v.s("name"));
    state.file = Some(file);
}

pub fn has_resolver() -> bool {
    STATE.lock().unwrap().resolver.is_some()
}

pub fn set_resolver(resolver: Resolver) {
    STATE.lock().unwrap().resolver = Some(resolver);
}

/// The signed-in account's name, or Some("") when it couldn't be read; None: signed out.
pub fn account() -> Option<String> {
    let state = STATE.lock().unwrap();
    state.cookie.as_ref().map(|_| state.name.clone().unwrap_or_default())
}

fn cookie() -> Option<String> {
    STATE.lock().unwrap().cookie.clone()
}

fn sapisid(cookie: &str) -> Option<String> {
    cookie.split(';').map(str::trim).find_map(|c| {
        c.strip_prefix("__Secure-3PAPISID=")
            .or_else(|| c.strip_prefix("SAPISID="))
            .map(String::from)
    })
}

/// Signs in with a browser's cookies for music.youtube.com (the `Cookie` header of any of
/// its requests). Returns the account's name.
pub fn sign_in(cookie: &str) -> Result<String> {
    let cookie = cookie.trim().trim_start_matches("Cookie:").trim().to_owned();
    if sapisid(&cookie).is_none() {
        bail!("those cookies aren't from a signed-in YouTube Music (no SAPISID)");
    }
    let name = account_name(&cookie)?;
    save(cookie, Some(name.clone()))?;
    Ok(name)
}

fn save(cookie: String, name: Option<String>) -> Result<()> {
    let mut state = STATE.lock().unwrap();
    if let Some(file) = &state.file {
        let tmp = file.with_extension("json.tmp");
        std::fs::write(&tmp, json!({ "cookie": cookie, "name": name }).to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
        }
        std::fs::rename(&tmp, file)?;
    }
    state.cookie = Some(cookie);
    state.name = name;
    Ok(())
}

/// The sign-in as JSON, for the Halcyn account's vault.
pub fn export() -> Option<String> {
    let state = STATE.lock().unwrap();
    state.cookie.as_ref().map(|c| json!({ "cookie": c, "name": state.name }).to_string())
}

/// Signs in with a sign-in exported on another device.
pub fn import(saved: &str) -> Result<()> {
    let saved: Value = serde_json::from_str(saved)?;
    let cookie = saved.s("cookie").filter(|c| sapisid(c).is_some());
    save(cookie.ok_or_else(|| anyhow!("that isn't a YouTube Music sign-in"))?, saved.s("name"))
}

/// Signs in with the cookies of a browser on this computer (yt-dlp reads them).
pub fn sign_in_from_browser(browser: &str, scratch: &std::path::Path) -> Result<String> {
    let jar = scratch.join("yt-cookies-import.txt");
    let out = Command::new("yt-dlp")
        .args(["--cookies-from-browser", browser, "--cookies"])
        .arg(&jar)
        // Any video will do: yt-dlp refuses the home page, and then saves no cookies.
        .args(["--skip-download", "--no-warnings", "https://music.youtube.com/watch?v=jNQXAC9IVRw"])
        .output()
        .map_err(|_| anyhow!("yt-dlp isn't installed"))?;
    let text = std::fs::read_to_string(&jar).unwrap_or_default();
    let _ = std::fs::remove_file(&jar);
    let cookies: Vec<String> = text
        .lines()
        .filter(|l| !l.starts_with('#') || l.starts_with("#HttpOnly_"))
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            (f.len() >= 7 && f[0].ends_with("youtube.com")).then(|| format!("{}={}", f[5], f[6]))
        })
        .collect();
    if cookies.is_empty() {
        let said = String::from_utf8_lossy(&out.stderr);
        bail!(
            "couldn't read {browser}'s cookies: {}",
            said.lines().last().unwrap_or("no YouTube sign-in found")
        );
    }
    sign_in(&cookies.join("; "))
}

pub fn sign_out() {
    let mut state = STATE.lock().unwrap();
    if let Some(file) = &state.file {
        let _ = std::fs::remove_file(file);
    }
    state.cookie = None;
    state.name = None;
}

fn client_version() -> String {
    let days = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() / 86_400;
    // The date, a few days back (YouTube rejects versions from the future).
    let (y, m, d) = civil(days as i64 - 3);
    format!("1.{y:04}{m:02}{d:02}.01.00")
}

/// Days since 1970 → (year, month, day).
fn civil(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

fn call_as(cookie: Option<&str>, endpoint: &str, body: Value) -> Result<Value> {
    let mut payload = json!({
        "context": {
            "client": { "clientName": "WEB_REMIX", "clientVersion": client_version(), "hl": "en", "gl": "US" },
            "user": {},
        }
    });
    if let (Value::Object(p), Value::Object(b)) = (&mut payload, body) {
        p.extend(b);
    }
    let mut request = AGENT
        .post(&format!("{ORIGIN}/youtubei/v1/{endpoint}?alt=json&prettyPrint=false"))
        .set("User-Agent", DESKTOP_UA)
        .set("Origin", ORIGIN)
        .set("X-Origin", ORIGIN)
        .set("Referer", &format!("{ORIGIN}/"));
    if let Some((cookie, id)) = cookie.and_then(|c| sapisid(c).map(|s| (c, s))) {
        let ts = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
        let hash: String = Sha1::digest(format!("{ts} {id} {ORIGIN}"))
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        request = request
            .set("Cookie", cookie)
            .set("Authorization", &format!("SAPISIDHASH {ts}_{hash}"))
            .set("X-Goog-AuthUser", "0");
    }
    http::json(request, Some(Body::Json(payload)))
}

fn call(endpoint: &str, body: Value) -> Result<Value> {
    call_as(cookie().as_deref(), endpoint, body)
}

fn signed_in() -> Result<()> {
    cookie().map(|_| ()).ok_or_else(|| anyhow!("sign in to YouTube Music first"))
}

fn account_name(cookie: &str) -> Result<String> {
    let menu = call_as(Some(cookie), "account/account_menu", json!({}))?;
    let header = find(&menu, "activeAccountHeaderRenderer");
    if header.is_empty() {
        bail!("YouTube didn't accept those cookies");
    }
    Ok(text(&header[0]["accountName"]))
}

fn browse(id: &str) -> Result<Value> {
    call("browse", json!({ "browseId": id }))
}

/// Every page of a browse: its continuations followed (playlists of over 100 songs).
fn browse_all(id: &str) -> Result<Vec<Value>> {
    let mut pages = vec![browse(id)?];
    let mut seen = std::collections::HashSet::new();
    while let Some(token) = continuation(pages.last().unwrap()) {
        if !seen.insert(token.clone()) || pages.len() >= 100 {
            break;
        }
        pages.push(call("browse", json!({ "continuation": token }))?);
    }
    Ok(pages)
}

// ---- reading the answers ----

fn walk<'a>(v: &'a Value, key: &str, out: &mut Vec<&'a Value>) {
    match v {
        Value::Object(o) => {
            for (k, v) in o {
                if k == key {
                    out.push(v);
                } else {
                    walk(v, key, out);
                }
            }
        }
        Value::Array(a) => a.iter().for_each(|v| walk(v, key, out)),
        _ => {}
    }
}

fn find<'a>(v: &'a Value, key: &str) -> Vec<&'a Value> {
    let mut out = Vec::new();
    walk(v, key, &mut out);
    out
}

fn continuation(v: &Value) -> Option<String> {
    find(v, "continuationCommand")
        .iter()
        .find_map(|c| c.s("token"))
        .or_else(|| find(v, "nextContinuationData").iter().find_map(|c| c.s("continuation")))
}

fn runs(v: &Value) -> Vec<Value> {
    v.list("runs")
}

fn text(v: &Value) -> String {
    let joined: String = runs(v).iter().filter_map(|r| r.s("text")).collect();
    if joined.is_empty() {
        v.s("simpleText").unwrap_or_default()
    } else {
        joined
    }
}

/// The largest thumbnail, scaled up to 544 px when YouTube says how.
fn thumb(v: &Value) -> Option<String> {
    let url = find(v, "thumbnails").first().and_then(|t| t.as_array()?.last()?.s("url"))?;
    // Song covers come as …=w120-h120-…: ask for a bigger one.
    Some(match url.find("=w") {
        Some(at) if url.contains("googleusercontent") => format!("{}=w544-h544-l90-rj", &url[..at]),
        _ => url,
    })
}

fn page_type(run: &Value) -> String {
    run["navigationEndpoint"]["browseEndpoint"]["browseEndpointContextSupportedConfigs"]
        ["browseEndpointContextMusicConfig"]
        .s("pageType")
        .unwrap_or_default()
}

fn seconds(s: &str) -> f64 {
    let s = s.trim();
    if s.is_empty() || !s.contains(':') || !s.chars().all(|c| c.is_ascii_digit() || c == ':') {
        return 0.0;
    }
    s.split(':').fold(0.0, |acc, p| acc * 60.0 + p.parse::<f64>().unwrap_or(0.0))
}

/// (artists, album, duration) from a line of runs: "Artist, Artist • Album • 3:12".
fn credits(rs: &[Value]) -> (Vec<String>, Option<String>, f64) {
    let artists: Vec<String> = rs
        .iter()
        .filter(|r| {
            matches!(
                page_type(r).as_str(),
                "MUSIC_PAGE_TYPE_ARTIST" | "MUSIC_PAGE_TYPE_USER_CHANNEL"
            )
        })
        .filter_map(|r| r.s("text"))
        .collect();
    let album =
        rs.iter().find(|r| page_type(r) == "MUSIC_PAGE_TYPE_ALBUM").and_then(|r| r.s("text"));
    let duration = rs
        .iter()
        .filter_map(|r| r.s("text"))
        .map(|t| seconds(&t))
        .find(|s| *s > 0.0)
        .unwrap_or(0.0);
    let artists = if artists.is_empty() {
        // Not linked (uploads, some album pages): the first part, before " • ".
        let line: String = rs.iter().filter_map(|r| r.s("text")).collect();
        line.split(" • ")
            .map(str::trim)
            .find(|p| {
                !p.is_empty()
                    && !["Song", "Video", "Single", "EP", "Album"].contains(p)
                    && !p.ends_with(" plays")
                    && !p.ends_with(" views")
                    && seconds(p) == 0.0
            })
            .map(|p| vec![p.to_owned()])
            .unwrap_or_default()
    } else {
        artists
    };
    (artists, album, duration)
}

fn song(
    id: String,
    title: String,
    artists: Vec<String>,
    album: Option<String>,
    duration: f64,
    art: Option<String>,
) -> RemoteTrack {
    RemoteTrack {
        path: format!("ytm:{id}"),
        title,
        artists,
        album,
        duration_secs: duration,
        art_url: art,
        quality: Some("AAC".into()),
        isrc: None,
    }
}

fn from_list_item(r: &Value, fallback_art: Option<&String>) -> Option<RemoteTrack> {
    let cols: Vec<Value> = r
        .list("flexColumns")
        .iter()
        .map(|c| c["musicResponsiveListItemFlexColumnRenderer"]["text"].clone())
        .collect();
    let first = cols.first().cloned().unwrap_or(Value::Null);
    let id = r["playlistItemData"]
        .s("videoId")
        .or_else(|| find(&r["overlay"], "watchEndpoint").iter().find_map(|w| w.s("videoId")))
        .or_else(|| {
            runs(&first)
                .iter()
                .find_map(|run| run["navigationEndpoint"]["watchEndpoint"].s("videoId"))
        })?;
    let title = runs(&first).first()?.s("text")?;
    let rest: Vec<Value> = cols.iter().skip(1).flat_map(runs).collect();
    let (artists, album, d) = credits(&rest);
    let fixed = r
        .list("fixedColumns")
        .iter()
        .map(|c| seconds(&text(&c["musicResponsiveListItemFixedColumnRenderer"]["text"])))
        .find(|s| *s > 0.0);
    let art = thumb(&r["thumbnail"]).or_else(|| fallback_art.cloned());
    Some(song(id, title, artists, album, fixed.unwrap_or(d), art))
}

fn from_panel(r: &Value) -> Option<RemoteTrack> {
    let id = r.s("videoId")?;
    let (artists, album, _) = credits(&runs(&r["longBylineText"]));
    let title =
        Some(text(&r["title"])).filter(|t| !t.is_empty()).unwrap_or_else(|| "Unknown".into());
    Some(song(id, title, artists, album, seconds(&text(&r["lengthText"])), thumb(&r["thumbnail"])))
}

fn songs(v: &Value, fallback_art: Option<&String>) -> Vec<RemoteTrack> {
    let mut seen = std::collections::HashSet::new();
    find(v, "musicResponsiveListItemRenderer")
        .into_iter()
        .filter_map(|r| from_list_item(r, fallback_art))
        .chain(find(v, "playlistPanelVideoRenderer").into_iter().filter_map(from_panel))
        .filter(|t| seen.insert(t.path.clone()))
        .collect()
}

// ---- as a library ----

/// Songs matching `query`, or what a pasted YouTube link (video, playlist) points to.
pub fn search(query: &str) -> Result<Vec<RemoteTrack>> {
    if let Some(list) = param(query, "list") {
        return playlist(&list);
    }
    if let Some(id) = param(query, "v")
        .or_else(|| query.split("youtu.be/").nth(1).map(|r| r.chars().take(11).collect()))
    {
        return Ok(radio(&id)?.into_iter().take(1).collect());
    }
    // Songs only, not videos.
    let found =
        call("search", json!({ "query": query, "params": "EgWKAQIIAWoMEA4QChADEAQQCRAF" }))?;
    Ok(songs(&found, None))
}

fn param(url: &str, key: &str) -> Option<String> {
    let query = url.split_once('?')?.1;
    query
        .split('&')
        .filter_map(|p| p.split_once('='))
        .find(|(k, _)| *k == key)
        .map(|(_, v)| {
            v.chars().take_while(|c| c.is_alphanumeric() || *c == '-' || *c == '_').collect()
        })
        .filter(|v: &String| !v.is_empty())
}

/// Songs like video `id`, starting with it.
pub fn radio(id: &str) -> Result<Vec<RemoteTrack>> {
    let next = call(
        "next",
        json!({
            "videoId": id, "playlistId": format!("RDAMVM{id}"), "isAudioOnly": true,
            "enablePersistentPlaylistPanel": true, "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        }),
    )?;
    Ok(songs(&next, None).into_iter().take(50).collect())
}

/// An artist's picture, cropped square (their page's header is a wide banner).
fn portrait(v: &Value) -> Option<String> {
    let url = find(v, "thumbnails").first().and_then(|t| t.as_array()?.last()?.s("url"))?;
    Some(match url.find("=w") {
        Some(at) if url.contains("googleusercontent") => {
            format!("{}=w544-h544-p-l90-rj", &url[..at])
        }
        _ => url,
    })
}

fn browse_id(r: &Value) -> Option<String> {
    r["navigationEndpoint"]["browseEndpoint"].s("browseId")
}

/// An album from a search result or an artist page's card: its title, then a line like
/// "Album • Radiohead • 1997" (search) or "Single • 2021" (the artist's own page).
fn album_from(id: String, title: String, line: &[Value], art: Option<String>) -> RemoteAlbum {
    let (artists, _, _) = credits(line);
    let parts: Vec<String> = line
        .iter()
        .filter_map(|r| r.s("text"))
        .collect::<String>()
        .split(" • ")
        .map(|p| p.trim().to_owned())
        .collect();
    let kind = parts.first().filter(|p| ["Album", "EP", "Single"].contains(&p.as_str())).cloned();
    let year = parts.iter().rev().find_map(|p| p.parse().ok().filter(|y| (1900..2200).contains(y)));
    // With no linked artist, credits() takes the kind or the year for one.
    let artists = artists
        .into_iter()
        .filter(|a| Some(a) != kind.as_ref() && a.parse::<u32>().is_err())
        .collect();
    RemoteAlbum { service: "ytm".into(), id, title, artists, year, kind, art_url: art }
}

fn first_column(r: &Value) -> (String, Vec<Value>) {
    let cols: Vec<Value> = r
        .list("flexColumns")
        .iter()
        .map(|c| c["musicResponsiveListItemFlexColumnRenderer"]["text"].clone())
        .collect();
    let first = cols.first().map(text).unwrap_or_default();
    (first, cols.iter().skip(1).flat_map(runs).collect())
}

pub fn search_albums(query: &str) -> Result<Vec<RemoteAlbum>> {
    // Albums only.
    let found =
        call("search", json!({ "query": query, "params": "EgWKAQIYAWoMEA4QChADEAQQCRAF" }))?;
    Ok(find(&found, "musicResponsiveListItemRenderer")
        .into_iter()
        .filter_map(|r| {
            let id = browse_id(r).filter(|i| i.starts_with("MPRE"))?;
            let (title, line) = first_column(r);
            Some(album_from(id, title, &line, thumb(&r["thumbnail"])))
        })
        .collect())
}

pub fn search_artists(query: &str) -> Result<Vec<RemoteArtist>> {
    // Artists only.
    let found =
        call("search", json!({ "query": query, "params": "EgWKAQIgAWoMEA4QChADEAQQCRAF" }))?;
    Ok(find(&found, "musicResponsiveListItemRenderer")
        .into_iter()
        .filter_map(|r| {
            let id = browse_id(r).filter(|i| i.starts_with("UC"))?;
            let (name, _) = first_column(r);
            let art_url = portrait(&r["thumbnail"]);
            Some(RemoteArtist { service: "ytm".into(), id, name, art_url })
        })
        .collect())
}

/// An artist's channel page: top songs, albums, singles and EPs, and "Fans might also like".
pub fn artist(id: &str) -> Result<RemoteArtistPage> {
    let page = browse(id)?;
    let kinds =
        ["musicImmersiveHeaderRenderer", "musicVisualHeaderRenderer", "musicHeaderRenderer"];
    let header = kinds
        .iter()
        .find_map(|k| find(&page["header"], k).first().copied())
        .ok_or_else(|| anyhow!("YouTube Music has no artist {id}"))?;
    let artist = RemoteArtist {
        service: "ytm".into(),
        id: id.to_owned(),
        name: text(&header["title"]),
        art_url: portrait(&header["thumbnail"]),
    };
    let mut tracks = Vec::new();
    if let Some(shelf) = find(&page, "musicShelfRenderer").first() {
        tracks = songs(shelf, None);
        // The shelf shows five: its playlist has the rest, most played first.
        if let Some(list) = shelf["bottomEndpoint"]["browseEndpoint"].s("browseId") {
            if let Ok(more) = browse(&list).map(|p| songs(&p, None)) {
                if more.len() > tracks.len() {
                    tracks = more.into_iter().take(20).collect();
                }
            }
        }
    }
    let (mut albums, mut singles, mut similar) = (Vec::new(), Vec::new(), Vec::new());
    for shelf in find(&page, "musicCarouselShelfRenderer") {
        let head = &shelf["header"]["musicCarouselShelfBasicHeaderRenderer"];
        let single = text(&head["title"]).contains("Single");
        let cards = |v: &Value| -> Vec<RemoteAlbum> {
            find(v, "musicTwoRowItemRenderer")
                .into_iter()
                .filter_map(|r| {
                    let id = browse_id(r).filter(|i| i.starts_with("MPRE"))?;
                    let art = thumb(&r["thumbnailRenderer"]);
                    let mut a = album_from(id, text(&r["title"]), &runs(&r["subtitle"]), art);
                    if a.artists.is_empty() {
                        a.artists = vec![artist.name.clone()];
                    }
                    Some(a)
                })
                .collect()
        };
        let mut found = cards(shelf);
        if found.is_empty() {
            similar.extend(find(shelf, "musicTwoRowItemRenderer").into_iter().filter_map(|r| {
                let id = browse_id(r).filter(|i| i.starts_with("UC"))?;
                Some(RemoteArtist {
                    service: "ytm".into(),
                    id,
                    name: text(&r["title"]),
                    art_url: portrait(&r["thumbnailRenderer"]),
                })
            }));
            continue;
        }
        // "More" opens the whole discography; the shelf only has the first ten.
        let more =
            &head["moreContentButton"]["buttonRenderer"]["navigationEndpoint"]["browseEndpoint"];
        if let (Some(more_id), Some(params)) = (more.s("browseId"), more.s("params")) {
            let params = params.replace("%3D", "=");
            if let Ok(all) = call("browse", json!({ "browseId": more_id, "params": params })) {
                let all = cards(&all);
                if all.len() > found.len() {
                    found = all;
                }
            }
        }
        if single { &mut singles } else { &mut albums }.extend(found);
    }
    Ok(RemoteArtistPage { artist, tracks, albums, singles, similar })
}

/// Liked songs, then the user's playlists and the ones they saved.
pub fn playlists() -> Result<Vec<RemotePlaylist>> {
    signed_in()?;
    let mut out = vec![RemotePlaylist {
        service: "ytm".into(),
        id: "LM".into(),
        name: "Liked songs".into(),
        count: None,
        art_url: None,
    }];
    for r in find(&browse("FEmusic_liked_playlists")?, "musicTwoRowItemRenderer") {
        let Some(id) = r["navigationEndpoint"]["browseEndpoint"].s("browseId") else {
            continue;
        };
        let Some(id) = id.strip_prefix("VL").map(String::from) else {
            continue;
        };
        if id == "LM" || out.iter().any(|p| p.id == id) {
            continue;
        }
        let sub = text(&r["subtitle"]);
        let count = sub
            .split(" • ")
            .find_map(|p| p.strip_suffix(" songs").or_else(|| p.strip_suffix(" tracks")))
            .and_then(|n| n.replace(',', "").parse().ok());
        out.push(RemotePlaylist {
            service: "ytm".into(),
            id,
            name: Some(text(&r["title"]))
                .filter(|t| !t.is_empty())
                .unwrap_or_else(|| "Playlist".into()),
            count,
            art_url: thumb(&r["thumbnailRenderer"]),
        });
    }
    Ok(out)
}

/// A playlist's (or, for an `MPREb_…` id, an album's) songs.
pub fn playlist(id: &str) -> Result<Vec<RemoteTrack>> {
    if id.starts_with("MPRE") {
        let page = browse(id)?;
        let cover = find(&page, "musicThumbnailRenderer").first().and_then(|t| thumb(t));
        let header = find(&page, "musicResponsiveHeaderRenderer");
        let album = header.first().map(|h| text(&h["title"]));
        // An album's rows name no artist when it's the album's own: the header does.
        let by =
            header.first().map(|h| credits(&runs(&h["straplineTextOne"])).0).unwrap_or_default();
        return Ok(songs(&page, cover.as_ref())
            .into_iter()
            .map(|mut t| {
                t.album = t.album.or_else(|| album.clone());
                if t.artists.is_empty() {
                    t.artists = by.clone();
                }
                t
            })
            .collect());
    }
    let id = id.strip_prefix("VL").unwrap_or(id);
    let mut seen = std::collections::HashSet::new();
    Ok(browse_all(&format!("VL{id}"))?
        .iter()
        .flat_map(|p| songs(p, None))
        .filter(|t| seen.insert(t.path.clone()))
        .collect())
}

/// The rows of the user's YouTube Music home page.
pub fn home() -> Result<Vec<RemoteShelf>> {
    let page = browse("FEmusic_home")?;
    let mut shelves = Vec::new();
    for shelf in find(&page, "musicCarouselShelfRenderer") {
        let title = text(&shelf["header"]["musicCarouselShelfBasicHeaderRenderer"]["title"]);
        let mut tracks = songs(shelf, None);
        let mut lists = Vec::new();
        for r in find(shelf, "musicTwoRowItemRenderer") {
            let nav = &r["navigationEndpoint"];
            if let Some(id) = nav["watchEndpoint"].s("videoId") {
                let (artists, album, _) = credits(&runs(&r["subtitle"]));
                tracks.push(song(
                    id,
                    text(&r["title"]),
                    artists,
                    album,
                    0.0,
                    thumb(&r["thumbnailRenderer"]),
                ));
                continue;
            }
            let id = nav["browseEndpoint"]
                .s("browseId")
                .or_else(|| nav["watchPlaylistEndpoint"].s("playlistId"));
            let Some(id) = id.filter(|i| {
                i.starts_with("VL")
                    || i.starts_with("MPRE")
                    || i.starts_with("RD")
                    || i.starts_with("PL")
            }) else {
                continue;
            };
            lists.push(RemotePlaylist {
                service: "ytm".into(),
                id: id.strip_prefix("VL").unwrap_or(&id).to_owned(),
                name: text(&r["title"]),
                count: None,
                art_url: thumb(&r["thumbnailRenderer"]),
            });
        }
        if !title.is_empty() && (!tracks.is_empty() || !lists.is_empty()) {
            shelves.push(RemoteShelf { service: "ytm".into(), title, tracks, lists });
        }
    }
    Ok(shelves)
}

/// Likes a song (or takes the like back).
pub fn like(id: &str, on: bool) -> Result<()> {
    signed_in()?;
    call(if on { "like/like" } else { "like/removelike" }, json!({ "target": { "videoId": id } }))?;
    Ok(())
}

/// Adds a listen to the account's history, as YouTube Music's own player does.
pub fn record_listen(id: &str) -> Result<()> {
    let Some(cookie) = cookie() else {
        return Ok(());
    };
    let player = call("player", json!({ "videoId": id }))?;
    let base = player["playbackTracking"]["videostatsPlaybackUrl"]
        .s("baseUrl")
        .ok_or_else(|| anyhow!("YouTube gave no way to record the listen"))?;
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut random = [0u8; 16];
    getrandom::fill(&mut random).map_err(|e| anyhow!("{e}"))?;
    let cpn: String = random.iter().map(|b| ALPHABET[(*b & 63) as usize] as char).collect();
    AGENT
        .get(&format!("{base}&ver=2&c=WEB_REMIX&cpn={cpn}"))
        .set("User-Agent", DESKTOP_UA)
        .set("Cookie", &cookie)
        .call()
        .map_err(|e| anyhow!("{e}"))?;
    Ok(())
}

// ---- playing ----

/// The address of video `id`'s audio.
pub fn audio_url(id: &str, scratch: &std::path::Path) -> Result<String> {
    {
        let state = STATE.lock().unwrap();
        if let Some(resolve) = &state.resolver {
            return resolve(id);
        }
    }
    let mut command = Command::new("yt-dlp");
    // 141 is 256 kbps AAC, for Premium accounts; 251 is Opus at about 160 kbps; 140 is
    // 128 kbps AAC.
    command.args(["-f", "141/251/140/bestaudio", "-g", "--no-playlist", "--no-warnings"]);
    let jar = scratch.join("yt-cookies.txt");
    if let Some(cookie) = cookie() {
        if write_jar(&jar, &cookie).is_ok() {
            command.arg("--cookies").arg(&jar);
        }
    }
    let out = command
        .arg(format!("https://music.youtube.com/watch?v={id}"))
        .output()
        .map_err(|_| anyhow!("YouTube Music songs need yt-dlp installed"))?;
    let _ = std::fs::remove_file(&jar);
    let url = String::from_utf8_lossy(&out.stdout).lines().next().unwrap_or("").trim().to_owned();
    if !out.status.success() || !url.starts_with("http") {
        let said = String::from_utf8_lossy(&out.stderr);
        bail!(
            "YouTube wouldn't send the audio: {}",
            said.lines().last().unwrap_or("no reason given")
        );
    }
    Ok(url)
}

/// What kind of file the audio at `url` is: "webm" (Opus) or "m4a" (AAC).
pub fn kind(url: &str) -> &'static str {
    if url.contains("mime=audio%2Fwebm") || url.contains("mime=audio/webm") { "webm" } else { "m4a" }
}

/// How long the audio at `url` is, in seconds, when the address says (`dur`). WebM and a
/// stream still downloading don't, so this is how the song's length is known.
pub fn duration(url: &str) -> Option<f64> {
    let query = url.split_once('?')?.1;
    let dur = query.split('&').find_map(|p| p.strip_prefix("dur="))?;
    dur.parse().ok().filter(|d: &f64| *d > 0.0)
}

/// YouTube sends one long download at about the speed it plays; pieces of a couple of MB
/// come at full speed. The address says the length (`clen`), so it's split into ranges.
pub fn ranges(url: &str) -> (Vec<String>, Option<u64>) {
    const PIECE: u64 = 2 << 20;
    let Some(len) = param(url, "clen").and_then(|l| l.parse::<u64>().ok()).filter(|l| *l > 0)
    else {
        return (vec![url.to_owned()], None);
    };
    let parts = (0..len.div_ceil(PIECE))
        .map(|i| format!("{url}&range={}-{}", i * PIECE, ((i + 1) * PIECE).min(len) - 1))
        .collect();
    (parts, Some(len))
}

/// A cookie header as a Netscape cookie file, for yt-dlp.
fn write_jar(path: &std::path::Path, cookie: &str) -> Result<()> {
    let mut jar = String::from("# Netscape HTTP Cookie File\n");
    for pair in cookie.split(';') {
        if let Some((k, v)) = pair.trim().split_once('=') {
            jar.push_str(&format!(".youtube.com\tTRUE\t/\tTRUE\t0\t{k}\t{v}\n"));
        }
    }
    std::fs::write(path, jar)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_its_answers() {
        assert_eq!(civil(0), (1970, 1, 1));
        assert_eq!(civil(20_753), (2026, 10, 27));
        assert_eq!(seconds("3:12"), 192.0);
        assert_eq!(seconds("1:02:03"), 3723.0);
        assert_eq!(seconds("Album"), 0.0);
        assert_eq!(sapisid("a=1; __Secure-3PAPISID=xyz; b=2").as_deref(), Some("xyz"));
        assert_eq!(
            param("https://music.youtube.com/watch?v=abcdefghijk&list=PL1", "list").as_deref(),
            Some("PL1")
        );
        let (parts, len) =
            ranges("https://r1.googlevideo.com/videoplayback?itag=140&clen=5000000&x=1");
        assert_eq!(len, Some(5_000_000));
        assert_eq!(parts.len(), 3);
        assert!(parts[2].ends_with("&range=4194304-4999999"));
        let opus = "https://r1.googlevideo.com/videoplayback?itag=251&mime=audio%2Fwebm&dur=212.441&clen=1";
        assert_eq!(kind(opus), "webm");
        assert_eq!(duration(opus), Some(212.441));
        assert_eq!(kind("https://r1.googlevideo.com/videoplayback?itag=140&mime=audio%2Fmp4"), "m4a");
    }
}

