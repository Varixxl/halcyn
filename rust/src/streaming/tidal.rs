//! Tidal: the browser ("PKCE") sign-in, the only one Tidal streams lossless to; the
//! account's playlists and favourites; search; and each song's stream, in the best
//! quality the account gets (FLAC up to 24-bit/192 kHz, AAC when that's all there is).

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, Result};
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use super::http::{self, Body, Get, Status, AGENT};
use super::{RemotePlaylist, RemoteTrack};

const CLIENT_ID: &str = env!("TIDAL_CLIENT_ID");
const CLIENT_SECRET: &str = env!("TIDAL_CLIENT_SECRET");
pub const REDIRECT: &str = "https://tidal.com/android/login/auth";
const V1: &str = "https://api.tidal.com/v1/";
/// The newer API, which finds songs by ISRC.
const V2: &str = "https://openapi.tidal.com/v2/";
const CLIENT_VERSION: &str = "2025.7.16";

#[derive(Clone, Debug, PartialEq)]
pub struct Session {
    pub access: String,
    pub refresh: String,
    pub kind: String,
    /// Unix seconds.
    pub expiry: f64,
    pub session: String,
    pub country: String,
    pub user: i64,
    pub name: Option<String>,
}

impl Session {
    fn to_json(&self) -> Value {
        json!({
            "access": self.access, "refresh": self.refresh, "type": self.kind, "expiry": self.expiry,
            "session": self.session, "country": self.country, "user": self.user, "name": self.name,
        })
    }

    fn from_json(v: &Value) -> Option<Session> {
        Some(Session {
            access: v.s("access")?,
            refresh: v.s("refresh").unwrap_or_default(),
            kind: v.s("type").unwrap_or_else(|| "Bearer".into()),
            expiry: v.n("expiry").unwrap_or(0.0),
            session: v.s("session").unwrap_or_default(),
            country: v.s("country").unwrap_or_else(|| "US".into()),
            user: v.n("user").unwrap_or(0.0) as i64,
            name: v.s("name"),
        })
    }
}

struct State {
    /// `<data>/tidal.json`; None keeps the session in memory only (tests).
    file: Option<PathBuf>,
    session: Option<Session>,
    /// The sign-in under way: its PKCE verifier and client key.
    pending: Option<(String, String)>,
    /// After a "too many requests": no calls before this.
    quiet_until: Option<Instant>,
}

static STATE: Mutex<State> =
    Mutex::new(State { file: None, session: None, pending: None, quiet_until: None });

/// Whether this build has Tidal's app keys (see tools/tidal-keys.sh).
pub fn available() -> bool {
    !CLIENT_ID.is_empty()
}

pub fn load(file: PathBuf) {
    let session = std::fs::read_to_string(&file)
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| Session::from_json(&v));
    let mut state = STATE.lock().unwrap();
    state.file = Some(file);
    state.session = session;
}

/// Uses `session` without saving it anywhere (tests).
/// Uses `session` without saving it anywhere (tests): renews it (the saved one may have
/// run out), then reads whose it is.
#[cfg(test)]
pub fn use_in_memory(saved: Session) -> Result<()> {
    {
        let mut state = STATE.lock().unwrap();
        state.file = None;
        state.session = Some(saved);
    }
    refresh()?;
    let s = session().unwrap();
    let mut full = describe(&s.access, &s.kind)?;
    full.refresh = s.refresh;
    full.expiry = s.expiry;
    set_session(Some(full));
    Ok(())
}

pub fn session() -> Option<Session> {
    STATE.lock().unwrap().session.clone()
}

/// The sign-in as JSON, for the Halcyn account's vault.
pub fn export() -> Option<String> {
    session().map(|s| s.to_json().to_string())
}

/// Signs in with a sign-in exported on another device.
pub fn import(saved: &str) -> Result<()> {
    let session = serde_json::from_str::<Value>(saved)
        .ok()
        .and_then(|v| Session::from_json(&v))
        .ok_or_else(|| anyhow!("that isn't a Tidal sign-in"))?;
    set_session(Some(session));
    Ok(())
}

fn set_session(session: Option<Session>) {
    let mut state = STATE.lock().unwrap();
    if let Some(file) = &state.file {
        match &session {
            Some(s) => {
                let tmp = file.with_extension("json.tmp");
                if std::fs::write(&tmp, s.to_json().to_string()).is_ok() {
                    restrict(&tmp);
                    let _ = std::fs::rename(&tmp, file);
                }
            }
            None => {
                let _ = std::fs::remove_file(file);
            }
        }
    }
    state.session = session;
}

/// The session file holds the account's keys: only the user may read it.
fn restrict(file: &std::path::Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o600));
    }
    #[cfg(not(unix))]
    let _ = file;
}

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs_f64()
}

fn random(bytes: usize) -> Vec<u8> {
    let mut buf = vec![0u8; bytes];
    getrandom::fill(&mut buf).expect("no randomness");
    buf
}

// ---- signing in ----

/// Step 1: the page to sign in on. Tidal then sends the browser to [REDIRECT] with a
/// code, which [finish_login] takes.
pub fn login_url() -> Result<String> {
    if !available() {
        bail!("this build of Halcyn has no Tidal keys");
    }
    let verifier = URL_SAFE_NO_PAD.encode(random(32));
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    let unique: String = random(8).iter().map(|b| format!("{b:02x}")).collect();
    let url = format!(
        "https://login.tidal.com/authorize?response_type=code&redirect_uri={}&client_id={CLIENT_ID}\
         &lang=EN&appMode=android&client_unique_key={unique}&code_challenge={challenge}\
         &code_challenge_method=S256&restrict_signup=true",
        encode(REDIRECT)
    );
    STATE.lock().unwrap().pending = Some((verifier, unique));
    Ok(url)
}

/// Step 2: the address Tidal sent the browser to (or just its code).
pub fn finish_login(redirected: &str) -> Result<Session> {
    let code = query_param(redirected, "code")
        .or_else(|| (!redirected.contains(['/', '?', '='])).then(|| redirected.trim().to_owned()))
        .filter(|c| !c.is_empty())
        .ok_or_else(|| anyhow!("that address has no sign-in code in it"))?;
    let (verifier, unique) =
        STATE.lock().unwrap().pending.clone().ok_or_else(|| anyhow!("start signing in again"))?;
    let token = http::json(
        AGENT.post("https://auth.tidal.com/v1/oauth2/token"),
        Some(Body::Form(form(&[
            ("code", &code),
            ("client_id", CLIENT_ID),
            ("grant_type", "authorization_code"),
            ("redirect_uri", REDIRECT),
            ("scope", "r_usr+w_usr+w_sub"),
            ("code_verifier", &verifier),
            ("client_unique_key", &unique),
        ]))),
    )?;
    let access = token.s("access_token").ok_or_else(|| anyhow!("Tidal didn't sign you in"))?;
    let kind = token.s("token_type").unwrap_or_else(|| "Bearer".into());
    let mut session = describe(&access, &kind)?;
    session.refresh = token.s("refresh_token").unwrap_or_default();
    session.expiry = now() + token.n("expires_in").unwrap_or(3600.0);
    STATE.lock().unwrap().pending = None;
    set_session(Some(session.clone()));
    Ok(session)
}

/// The session, user and country an access token belongs to.
fn describe(access: &str, kind: &str) -> Result<Session> {
    let info = http::json(
        AGENT.get(&format!("{V1}sessions")).set("Authorization", &format!("{kind} {access}")),
        None,
    )?;
    let user = info.n("userId").unwrap_or(0.0) as i64;
    let country = info.s("countryCode").unwrap_or_else(|| "US".into());
    let name = http::json(
        AGENT
            .get(&format!("{V1}users/{user}?countryCode={country}"))
            .set("Authorization", &format!("{kind} {access}")),
        None,
    )
    .ok()
    .and_then(|u| u.s("firstName").or_else(|| u.s("username")).or_else(|| u.s("email")));
    Ok(Session {
        access: access.into(),
        refresh: String::new(),
        kind: kind.into(),
        expiry: 0.0,
        session: info.s("sessionId").unwrap_or_default(),
        country,
        user,
        name,
    })
}

pub fn sign_out() {
    set_session(None);
}

fn refresh() -> Result<()> {
    let current = session().ok_or_else(|| anyhow!("sign in to Tidal first"))?;
    let token = http::json(
        AGENT.post("https://auth.tidal.com/v1/oauth2/token"),
        Some(Body::Form(form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", &current.refresh),
            ("client_id", CLIENT_ID),
            ("client_secret", CLIENT_SECRET),
        ]))),
    )
    .map_err(|e| match e.downcast_ref::<Status>() {
        // The sign-in was revoked or has run out: it's gone.
        Some(s) if s.code == 400 || s.code == 401 => {
            set_session(None);
            anyhow!("Tidal signed you out; sign in again in Settings")
        }
        _ => e,
    })?;
    let access =
        token.s("access_token").ok_or_else(|| anyhow!("Tidal didn't renew the sign-in"))?;
    let mut next = session().unwrap_or(current);
    next.access = access;
    next.expiry = now() + token.n("expires_in").unwrap_or(3600.0);
    if let Some(r) = token.s("refresh_token") {
        next.refresh = r;
    }
    set_session(Some(next));
    Ok(())
}

// ---- the API ----

fn encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn form(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

/// One query parameter of an address, decoded.
fn query_param(url: &str, key: &str) -> Option<String> {
    let query = url.split_once('?')?.1.split('#').next()?;
    query.split('&').filter_map(|p| p.split_once('=')).find(|(k, _)| *k == key).map(|(_, v)| {
        let bytes = v.as_bytes();
        let mut out = Vec::new();
        let mut i = 0;
        while i < bytes.len() {
            match bytes[i] {
                b'%' if i + 2 < bytes.len() => {
                    let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok();
                    match hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                        Some(b) => {
                            out.push(b);
                            i += 3;
                            continue;
                        }
                        None => out.push(b'%'),
                    }
                }
                b'+' => out.push(b' '),
                b => out.push(b),
            }
            i += 1;
        }
        String::from_utf8_lossy(&out).into_owned()
    })
}

enum Method {
    Get,
    Post(Vec<(String, String)>),
    Delete,
}

/// A call to Tidal's API as the signed-in user: renews the sign-in when it runs out, and
/// waits and tries again (longer each time) when Tidal says there are too many requests.
fn api(path: &str, params: &[(&str, String)], method: Method) -> Result<Value> {
    api_at(V1, path, params, method)
}

fn api_at(base: &str, path: &str, params: &[(&str, String)], method: Method) -> Result<Value> {
    let mut s = session().ok_or_else(|| anyhow!("sign in to Tidal first"))?;
    if now() > s.expiry - 60.0 && !s.refresh.is_empty() {
        refresh()?;
        s = session().ok_or_else(|| anyhow!("sign in to Tidal first"))?;
    }
    let mut renewed = false;
    let mut attempt = 0;
    loop {
        let quiet = STATE.lock().unwrap().quiet_until;
        if let Some(wait) = quiet.and_then(|q| q.checked_duration_since(Instant::now())) {
            std::thread::sleep(wait);
        }
        let mut query = vec![("countryCode", s.country.clone())];
        if base == V1 {
            query.push(("sessionId", s.session.clone()));
        }
        query.extend(params.iter().cloned());
        let query: Vec<String> = query.iter().map(|(k, v)| format!("{}={}", encode(k), encode(v))).collect();
        let url = format!("{base}{path}?{}", query.join("&"));
        let request = match &method {
            Method::Get => AGENT.get(&url),
            Method::Post(_) => AGENT.post(&url),
            Method::Delete => AGENT.delete(&url),
        }
        .set("Authorization", &format!("{} {}", s.kind, s.access))
        .set("x-tidal-client-version", CLIENT_VERSION);
        let body = match &method {
            Method::Post(form) => Some(Body::Form(form.clone())),
            _ => None,
        };
        match http::json(request, body) {
            Err(e) => match e.downcast_ref::<Status>().map(|s| s.code) {
                Some(401) if !renewed && !s.refresh.is_empty() => {
                    renewed = true;
                    refresh()?;
                    s = session().ok_or_else(|| anyhow!("sign in to Tidal first"))?;
                }
                Some(429) if attempt < 5 => {
                    let pause = Duration::from_millis(1000 << attempt);
                    attempt += 1;
                    let mut state = STATE.lock().unwrap();
                    let until = Instant::now() + pause;
                    state.quiet_until = Some(state.quiet_until.map_or(until, |q| q.max(until)));
                }
                _ => return Err(e),
            },
            ok => return ok,
        }
    }
}

fn get(path: &str, params: &[(&str, String)]) -> Result<Value> {
    api(path, params, Method::Get)
}

/// Every page of a list, up to 10 000 entries. `item`: the entries are `{ item: … }`.
fn paged(path: &str, page: usize, item: bool) -> Result<Vec<Value>> {
    let mut out = Vec::new();
    while out.len() < 10_000 {
        let items = get(path, &[("limit", page.to_string()), ("offset", out.len().to_string())])?
            .list("items");
        let n = items.len();
        out.extend(items.into_iter().filter_map(|i| {
            if item {
                i.get("item").cloned()
            } else {
                Some(i)
            }
        }));
        if n < page {
            break;
        }
    }
    Ok(out)
}

pub fn image(uuid: Option<String>, px: u32) -> Option<String> {
    uuid.filter(|u| !u.is_empty()).map(|u| {
        format!("https://resources.tidal.com/images/{}/{px}x{px}.jpg", u.replace('-', "/"))
    })
}

fn title(c: &Value) -> String {
    let t = c.s("title").unwrap_or_default();
    match c.s("version") {
        Some(v) if v != "null" && !v.trim().is_empty() => format!("{t} ({v})"),
        _ => t,
    }
}

fn track(c: &Value) -> Option<RemoteTrack> {
    if c["allowStreaming"] == Value::Bool(false) || c["duration"].is_null() {
        return None;
    }
    let tags: Vec<String> = c["mediaMetadata"]
        .list("tags")
        .iter()
        .filter_map(|t| t.as_str().map(String::from))
        .collect();
    let quality = if tags.iter().any(|t| t == "HIRES_LOSSLESS") {
        "Hi-res"
    } else if tags.iter().any(|t| t == "LOSSLESS")
        || c.s("audioQuality").as_deref() == Some("LOSSLESS")
    {
        "Lossless"
    } else {
        "AAC"
    };
    let album = &c["album"];
    Some(RemoteTrack {
        path: format!("tidal:{}", c.s("id")?),
        title: title(c),
        artists: c.list("artists").iter().filter_map(|a| a.s("name")).collect(),
        album: album.s("title"),
        duration_secs: c.n("duration").unwrap_or(0.0),
        art_url: image(album.s("cover"), 1280),
        quality: Some(quality.into()),
        isrc: c.s("isrc"),
    })
}

fn tracks(items: &[Value]) -> Vec<RemoteTrack> {
    items.iter().filter_map(track).collect()
}

/// Songs matching `query`, or the songs a pasted Tidal link (track, album, playlist, mix)
/// points to.
pub fn search(query: &str) -> Result<Vec<RemoteTrack>> {
    if let Some((kind, id)) = link(query) {
        return match kind {
            "track" => Ok(tracks(&[get(&format!("tracks/{id}"), &[])?])),
            "album" => album(&id),
            "playlist" => playlist(&id),
            _ => Ok(tracks(
                &get(&format!("mixes/{id}/items"), &[])?
                    .list("items")
                    .iter()
                    .filter_map(|i| i.get("item").cloned())
                    .collect::<Vec<_>>(),
            )),
        };
    }
    let found = get(
        "search",
        &[("query", query.into()), ("types", "TRACKS".into()), ("limit", "40".into())],
    )?;
    Ok(tracks(&found["tracks"].list("items")))
}

/// ("track" | "album" | "playlist" | "mix", id) of a Tidal link.
fn link(text: &str) -> Option<(&'static str, String)> {
    let at = text.find("tidal.com/")?;
    let rest = &text[at + "tidal.com/".len()..];
    let rest = rest.strip_prefix("browse/").unwrap_or(rest);
    for kind in ["track", "album", "playlist", "mix"] {
        if let Some(id) = rest.strip_prefix(kind).and_then(|r| r.strip_prefix('/')) {
            let id: String = id.chars().take_while(|c| c.is_alphanumeric() || *c == '-').collect();
            if !id.is_empty() {
                return Some((kind, id));
            }
        }
    }
    None
}

/// The songs with this ISRC (one recording, on its single, its album, compilations…).
pub fn by_isrc(isrc: &str) -> Result<Vec<RemoteTrack>> {
    let found = api_at(V2, "tracks", &[("filter[isrc]", isrc.to_uppercase())], Method::Get)?;
    let mut out = Vec::new();
    for id in found.list("data").iter().filter_map(|t| t.s("id")).take(5) {
        // The new API's answer lacks what a song needs (album, cover, quality): the old one's.
        if let Ok(track) = get(&format!("tracks/{id}"), &[]) {
            out.extend(self::track(&track));
        }
    }
    Ok(out)
}

pub fn album(id: &str) -> Result<Vec<RemoteTrack>> {
    Ok(tracks(&paged(&format!("albums/{id}/tracks"), 100, false)?))
}

/// The user's playlists and the ones they follow, after their favourite tracks.
pub fn playlists() -> Result<Vec<RemotePlaylist>> {
    let user = session().ok_or_else(|| anyhow!("sign in to Tidal first"))?.user;
    let mut out = vec![RemotePlaylist {
        service: "tidal".into(),
        id: "favorites".into(),
        name: "Favourite tracks".into(),
        count: None,
        art_url: None,
    }];
    let own = paged(&format!("users/{user}/playlists"), 50, false)?;
    let followed = paged(&format!("users/{user}/favorites/playlists"), 50, true)?;
    for p in own.iter().chain(&followed) {
        let Some(id) = p.s("uuid") else { continue };
        if out.iter().any(|o| o.id == id) {
            continue;
        }
        out.push(RemotePlaylist {
            service: "tidal".into(),
            id,
            name: p.s("title").unwrap_or_else(|| "Playlist".into()),
            count: p.n("numberOfTracks").map(|n| n as u32),
            art_url: image(p.s("squareImage").or_else(|| p.s("image")), 320),
        });
    }
    Ok(out)
}

pub fn playlist(id: &str) -> Result<Vec<RemoteTrack>> {
    if id == "favorites" {
        let user = session().ok_or_else(|| anyhow!("sign in to Tidal first"))?.user;
        return Ok(tracks(&paged(&format!("users/{user}/favorites/tracks"), 50, true)?));
    }
    Ok(tracks(&paged(&format!("playlists/{id}/tracks"), 100, false)?))
}

/// Songs like `id`.
pub fn radio(id: &str) -> Result<Vec<RemoteTrack>> {
    Ok(tracks(&get(&format!("tracks/{id}/radio"), &[("limit", "40".into())])?.list("items")))
}

/// The mixes Tidal made for the user: (title, subtitle, art, tracks).
pub fn mixes() -> Result<Vec<(String, String, Option<String>, String)>> {
    let page = get("pages/my_collection_my_mixes", &[("deviceType", "BROWSER".into())])?;
    let mut out = Vec::new();
    let mut walk = vec![&page];
    while let Some(v) = walk.pop() {
        match v {
            Value::Object(o) => {
                if o.get("mixType").is_some() {
                    if let Some(id) = v.s("id") {
                        let art = v["images"]["MEDIUM"]
                            .s("url")
                            .or_else(|| v["images"]["SMALL"].s("url"));
                        out.push((
                            v.s("title").unwrap_or_default(),
                            v.s("subTitle").unwrap_or_default(),
                            art,
                            id,
                        ));
                    }
                } else {
                    walk.extend(o.values());
                }
            }
            Value::Array(a) => walk.extend(a.iter().rev()),
            _ => {}
        }
    }
    Ok(out)
}

pub fn mix(id: &str) -> Result<Vec<RemoteTrack>> {
    let items = get(&format!("mixes/{id}/items"), &[("limit", "100".into())])?.list("items");
    Ok(tracks(&items.iter().filter_map(|i| i.get("item").cloned()).collect::<Vec<_>>()))
}

/// Adds a song to (or takes it out of) the user's favourites.
pub fn favourite(id: &str, on: bool) -> Result<()> {
    let user = session().ok_or_else(|| anyhow!("sign in to Tidal first"))?.user;
    if on {
        api(
            &format!("users/{user}/favorites/tracks"),
            &[],
            Method::Post(form(&[("trackIds", id)])),
        )?;
    } else {
        api(&format!("users/{user}/favorites/tracks/{id}"), &[], Method::Delete)?;
    }
    Ok(())
}

// ---- playing ----

/// How to fetch one song: its parts (one file, or a DASH init and segments) in order,
/// what kind of file they make, and how good it is ("24-bit/96 kHz FLAC").
pub struct Plan {
    pub parts: Vec<String>,
    pub ext: &'static str,
    pub quality: String,
    /// The length a DASH stream's manifest gives, in seconds (its MP4 says 0).
    pub secs: Option<f64>,
}

pub fn stream(id: &str) -> Result<Plan> {
    let info = get(
        &format!("tracks/{id}/playbackinfopostpaywall"),
        &[
            ("playbackmode", "STREAM".into()),
            ("audioquality", "HI_RES_LOSSLESS".into()),
            ("assetpresentation", "FULL".into()),
        ],
    )?;
    let manifest = String::from_utf8(STANDARD.decode(info.s("manifest").unwrap_or_default())?)?;
    let mime = info.s("manifestMimeType").unwrap_or_default();
    let level = info.s("audioQuality").unwrap_or_default();
    if mime.contains("dash") {
        let dash = dash_parts(&manifest)?;
        let flac = manifest.to_lowercase().contains("codecs=\"flac\"");
        let rate = attr(&manifest, "audioSamplingRate")
            .and_then(|r| r.parse().ok())
            .or(info.n("sampleRate").map(|r| r as u32));
        let mut bits = info.n("bitDepth").map(|b| b as u32).unwrap_or(16);
        // Tidal leaves the depth out of hi-res answers.
        if bits == 16 && rate.is_some_and(|r| r > 48_000) {
            bits = 24;
        }
        let quality = if flac { flac_quality(bits, rate) } else { lossy_quality(&level) };
        let secs = attr(&manifest, "mediaPresentationDuration").and_then(|d| iso_secs(&d));
        return Ok(Plan { parts: dash, ext: "mp4", quality, secs });
    }
    let bts: Value = serde_json::from_str(&manifest)?;
    if bts.s("encryptionType").is_some_and(|e| e != "NONE") {
        bail!("Tidal sent an encrypted stream");
    }
    let url = bts
        .list("urls")
        .first()
        .and_then(|u| u.as_str().map(String::from))
        .ok_or_else(|| anyhow!("Tidal sent no stream"))?;
    let codec = bts.s("codecs").unwrap_or_default().to_uppercase();
    if codec.starts_with("FLAC") {
        let bits = info.n("bitDepth").map(|b| b as u32).unwrap_or(16);
        let rate = info.n("sampleRate").map(|r| r as u32);
        Ok(Plan { parts: vec![url], ext: "flac", quality: flac_quality(bits, rate), secs: None })
    } else {
        Ok(Plan { parts: vec![url], ext: "m4a", quality: lossy_quality(&level), secs: None })
    }
}

fn flac_quality(bits: u32, rate: Option<u32>) -> String {
    let khz = rate.unwrap_or(44_100) as f64 / 1000.0;
    format!("{bits}-bit/{} kHz FLAC", format!("{khz:.1}").trim_end_matches(".0"))
}

fn lossy_quality(level: &str) -> String {
    match level {
        "LOW" => "AAC 96 kbps".into(),
        _ => "AAC 320 kbps".into(),
    }
}

/// Seconds in an ISO 8601 duration like "PT3M45.123S".
fn iso_secs(d: &str) -> Option<f64> {
    let rest = d.strip_prefix("PT")?;
    let mut secs = 0.0;
    let mut number = String::new();
    for c in rest.chars() {
        match c {
            'H' => secs += number.parse::<f64>().ok()? * 3600.0,
            'M' => secs += number.parse::<f64>().ok()? * 60.0,
            'S' => secs += number.parse::<f64>().ok()?,
            _ => {
                number.push(c);
                continue;
            }
        }
        number.clear();
    }
    (secs > 0.0).then_some(secs)
}

fn attr(xml: &str, name: &str) -> Option<String> {
    let start = xml.find(&format!("{name}=\""))? + name.len() + 2;
    let end = xml[start..].find('"')? + start;
    Some(xml[start..end].replace("&amp;", "&"))
}

/// The init segment and each media segment of a DASH manifest's (single) representation.
fn dash_parts(mpd: &str) -> Result<Vec<String>> {
    let init = attr(mpd, "initialization")
        .ok_or_else(|| anyhow!("the stream's manifest has no init segment"))?;
    let media =
        attr(mpd, "media").ok_or_else(|| anyhow!("the stream's manifest lists no segments"))?;
    let start: u64 = attr(mpd, "startNumber").and_then(|s| s.parse().ok()).unwrap_or(1);
    let mut count = 0u64;
    let mut rest = mpd;
    while let Some(at) = rest.find("<S ") {
        let end = rest[at..].find('>').map_or(rest.len(), |e| at + e);
        let tag = &rest[at..end];
        count += 1 + attr(tag, "r").and_then(|r| r.parse::<u64>().ok()).unwrap_or(0);
        rest = &rest[end..];
    }
    if count == 0 {
        bail!("the stream's manifest lists no segments");
    }
    let mut parts = vec![init];
    parts.extend((start..start + count).map(|n| media.replace("$Number$", &n.to_string())));
    Ok(parts)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_dash_manifest() {
        let mpd = r#"<MPD><Period><AdaptationSet><Representation codecs="flac" audioSamplingRate="96000">
            <SegmentTemplate timescale="96000" initialization="https://x/i.mp4?a=1&amp;b=2" media="https://x/$Number$.mp4?a=1&amp;b=2" startNumber="1">
            <SegmentTimeline><S d="384000" r="2"/><S d="1000"/></SegmentTimeline></SegmentTemplate>
            </Representation></AdaptationSet></Period></MPD>"#;
        assert_eq!(
            dash_parts(mpd).unwrap(),
            [
                "https://x/i.mp4?a=1&b=2",
                "https://x/1.mp4?a=1&b=2",
                "https://x/2.mp4?a=1&b=2",
                "https://x/3.mp4?a=1&b=2",
                "https://x/4.mp4?a=1&b=2"
            ]
        );
        assert_eq!(flac_quality(24, Some(96_000)), "24-bit/96 kHz FLAC");
        assert_eq!(flac_quality(16, Some(44_100)), "16-bit/44.1 kHz FLAC");
        assert_eq!(iso_secs("PT3M45.5S"), Some(225.5));
        assert_eq!(iso_secs("PT1H0M2S"), Some(3602.0));
    }

    #[test]
    fn reads_links_and_codes() {
        assert_eq!(link("https://tidal.com/browse/track/12345?u"), Some(("track", "12345".into())));
        assert_eq!(
            link("https://listen.tidal.com/playlist/ab-cd"),
            Some(("playlist", "ab-cd".into()))
        );
        assert_eq!(link("blur song 2"), None);
        assert_eq!(
            query_param("https://tidal.com/android/login/auth?code=a%2Bb&state=x", "code")
                .as_deref(),
            Some("a+b")
        );
    }
}
