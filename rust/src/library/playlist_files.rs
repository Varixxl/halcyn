//! Playlist files in the music folders (.m3u, .m3u8, .pls, .xspf): reading their entries
//! and finding each one in the library, even when the file was written on another
//! computer (other drive letters, backslashes, `file://` links, a moved music folder).

use std::collections::{HashMap, HashSet};
use std::path::Path;

pub const EXTENSIONS: &[&str] = &["m3u", "m3u8", "pls", "xspf"];

/// What a playlist file says: its title, if it has one, and its entries as written.
#[derive(Debug, Default, PartialEq)]
pub struct Parsed {
    pub title: Option<String>,
    pub entries: Vec<String>,
}

pub fn is_playlist(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()))
}

/// Reads one playlist file. Text that isn't UTF-8 is read as Latin-1 (old .m3u files).
pub fn parse(path: &Path, bytes: &[u8]) -> Parsed {
    let text = match std::str::from_utf8(bytes) {
        Ok(s) => s.to_owned(),
        Err(_) => bytes.iter().map(|&b| b as char).collect(),
    };
    let text = text.trim_start_matches('\u{feff}');
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "pls" => parse_pls(text),
        "xspf" => parse_xspf(text),
        _ => parse_m3u(text),
    }
}

fn parse_m3u(text: &str) -> Parsed {
    let mut parsed = Parsed::default();
    for line in text.lines().map(str::trim).filter(|l| !l.is_empty()) {
        if let Some(title) = line.strip_prefix("#PLAYLIST:") {
            parsed.title = Some(title.trim().to_owned()).filter(|t| !t.is_empty());
        } else if !line.starts_with('#') {
            parsed.entries.push(line.to_owned());
        }
    }
    parsed
}

fn parse_pls(text: &str) -> Parsed {
    let mut files: Vec<(u32, String)> = Vec::new();
    let mut title = None;
    for line in text.lines().map(str::trim) {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim().to_ascii_lowercase();
        if let Some(n) = key.strip_prefix("file").and_then(|n| n.parse().ok()) {
            files.push((n, value.trim().to_owned()));
        } else if key == "x-playlist-title" || key == "playlisttitle" {
            title = Some(value.trim().to_owned()).filter(|t| !t.is_empty());
        }
    }
    files.sort_by_key(|(n, _)| *n);
    Parsed { title, entries: files.into_iter().map(|(_, f)| f).collect() }
}

fn parse_xspf(text: &str) -> Parsed {
    // The title before the track list is the playlist's; ones inside tracks aren't.
    let head = text.find("<trackList").map_or(text, |i| &text[..i]);
    let title = between(head, "<title>", "</title>").next().map(|t| xml_text(t.trim()));
    let entries = between(text, "<location>", "</location>").map(|l| xml_text(l.trim())).collect();
    Parsed { title: title.filter(|t| !t.is_empty()), entries }
}

fn between<'a>(text: &'a str, open: &'a str, close: &'a str) -> impl Iterator<Item = &'a str> {
    let mut rest = text;
    std::iter::from_fn(move || {
        let start = rest.find(open)? + open.len();
        let len = rest[start..].find(close)?;
        let found = &rest[start..start + len];
        rest = &rest[start + len + close.len()..];
        Some(found)
    })
}

fn xml_text(s: &str) -> String {
    let s = s.strip_prefix("<![CDATA[").and_then(|s| s.strip_suffix("]]>")).unwrap_or(s);
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let Some(end) = rest.find(';') else { break };
        let entity = &rest[1..end];
        let c = match entity {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            _ => entity
                .strip_prefix("#x")
                .and_then(|h| u32::from_str_radix(h, 16).ok())
                .or_else(|| entity.strip_prefix('#').and_then(|d| d.parse().ok()))
                .and_then(char::from_u32),
        };
        match c {
            Some(c) => {
                out.push(c);
                rest = &rest[end + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// Finds entries in the library. Built once per scan from every track's path.
pub struct Resolver {
    exact: HashSet<String>,
    /// Lowercased, forward slashes → the library's path.
    folded: HashMap<String, String>,
    /// Lowercased file name → the library paths with that name.
    by_name: HashMap<String, Vec<String>>,
}

impl Resolver {
    pub fn new<'a>(paths: impl IntoIterator<Item = &'a str>) -> Self {
        let mut r =
            Resolver { exact: HashSet::new(), folded: HashMap::new(), by_name: HashMap::new() };
        for path in paths {
            r.exact.insert(path.to_owned());
            let fold = fold(path);
            if let Some(name) = fold.rsplit('/').next() {
                r.by_name.entry(name.to_owned()).or_default().push(path.to_owned());
            }
            r.folded.insert(fold, path.to_owned());
        }
        r
    }

    /// The library path an entry of the playlist at `playlist` means, if any: the path
    /// itself, the same path ignoring case and slashes, or else the track whose path ends
    /// with the most of the entry's folders (a playlist from another computer).
    pub fn resolve(&self, playlist: &Path, entry: &str) -> Option<String> {
        let entry = entry_path(entry)?;
        let absolute = is_absolute(&entry);
        let full = if absolute {
            entry.clone()
        } else {
            let dir = playlist.parent().unwrap_or(Path::new(""));
            format!("{}/{}", dir.to_string_lossy().replace('\\', "/"), entry)
        };
        let full = normalize(&full);
        if self.exact.contains(&full) {
            return Some(full);
        }
        let native = full.replace('/', std::path::MAIN_SEPARATOR_STR);
        if self.exact.contains(&native) {
            return Some(native);
        }
        if let Some(found) = self.folded.get(&fold(&full)) {
            return Some(found.clone());
        }

        let parts: Vec<String> = fold(&entry)
            .split('/')
            .filter(|p| !p.is_empty() && *p != "..")
            .map(String::from)
            .collect();
        let name = parts.last()?;
        let candidates = self.by_name.get(name)?;
        let score = |path: &str| {
            let theirs: Vec<String> = fold(path).split('/').map(String::from).collect();
            parts.iter().rev().zip(theirs.iter().rev()).take_while(|(a, b)| a == b).count()
        };
        let mut best: Vec<(&String, usize)> = candidates.iter().map(|c| (c, score(c))).collect();
        best.sort_by(|a, b| b.1.cmp(&a.1));
        match best.as_slice() {
            // Just a file name in common is enough only when no other track shares it.
            [(only, _)] => Some((*only).clone()),
            [(first, a), (_, b), ..] if a > b && *a >= 2 => Some((*first).clone()),
            _ => None,
        }
    }
}

/// An entry as a path with forward slashes, or None for a web address.
fn entry_path(entry: &str) -> Option<String> {
    let entry = entry.trim();
    if entry.is_empty() {
        return None;
    }
    if let Some(rest) = strip_scheme(entry, "file:") {
        // file:///home/a.flac, file://localhost/home/a.flac, file:///C:/Music/a.flac
        let rest =
            rest.strip_prefix("//").map_or(rest, |r| r.strip_prefix("localhost").unwrap_or(r));
        let decoded = percent_decode(rest);
        let path = match decoded.as_bytes() {
            [b'/', d, b':', ..] if d.is_ascii_alphabetic() => decoded[1..].to_owned(),
            _ => decoded,
        };
        return Some(path.replace('\\', "/"));
    }
    if entry.contains("://") {
        return None;
    }
    Some(entry.replace('\\', "/"))
}

fn strip_scheme<'a>(s: &'a str, scheme: &str) -> Option<&'a str> {
    (s.len() >= scheme.len() && s[..scheme.len()].eq_ignore_ascii_case(scheme))
        .then(|| &s[scheme.len()..])
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = |b: u8| (b as char).to_digit(16);
        if let (b'%', Some(&h), Some(&l)) = (bytes[i], bytes.get(i + 1), bytes.get(i + 2)) {
            if let (Some(h), Some(l)) = (hex(h), hex(l)) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// `/x`, `C:/x`, `//server/x`.
fn is_absolute(path: &str) -> bool {
    let b = path.as_bytes();
    path.starts_with('/') || (b.len() >= 2 && b[0].is_ascii_alphabetic() && b[1] == b':')
}

/// Folds `.` and `..` away, keeping forward slashes.
fn normalize(path: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "." => {}
            "" if !out.is_empty() => {}
            ".." => {
                if out.len() > 1 {
                    out.pop();
                }
            }
            p => out.push(p),
        }
    }
    let joined = out.join("/");
    if joined.is_empty() {
        "/".into()
    } else {
        joined
    }
}

fn fold(path: &str) -> String {
    path.replace('\\', "/").to_lowercase()
}

/// The name a playlist file gets when it has no title of its own: its file name.
pub fn default_name(path: &Path) -> String {
    path.file_stem().map_or_else(|| "Playlist".into(), |s| s.to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn resolver() -> Resolver {
        Resolver::new([
            "/home/me/Music/Glass Beach/the first glass beach album/01 cold weather.flac",
            "/home/me/Music/JID/The Forever Story/02 Raydar.flac",
            "/home/me/Music/Joji/SMITHEREENS/01 Glimpse of Us.flac",
            "/home/me/Music/Other/01 Glimpse of Us.flac",
            "/home/me/Music/Café Tacvba/Re/Las Flores.mp3",
        ])
    }

    #[test]
    fn m3u_keeps_entries_and_title() {
        let p = parse(
            Path::new("a.m3u8"),
            "\u{feff}#EXTM3U\n#PLAYLIST:Mine\n#EXTINF:1,x\na.flac\n\n b.mp3 \n".as_bytes(),
        );
        assert_eq!(
            p,
            Parsed { title: Some("Mine".into()), entries: vec!["a.flac".into(), "b.mp3".into()] }
        );
    }

    #[test]
    fn latin1_m3u_is_read() {
        let p = parse(Path::new("a.m3u"), b"Caf\xe9.mp3\n");
        assert_eq!(p.entries, vec!["Café.mp3"]);
    }

    #[test]
    fn pls_is_ordered_by_number() {
        let p = parse(
            Path::new("a.pls"),
            b"[playlist]\nFile2=b.flac\nTitle2=B\nFile1=a.flac\nNumberOfEntries=2\nVersion=2\n",
        );
        assert_eq!(p.entries, vec!["a.flac", "b.flac"]);
    }

    #[test]
    fn xspf_reads_locations_and_the_playlist_title() {
        let p = parse(
            Path::new("a.xspf"),
            br#"<?xml version="1.0"?><playlist><title>Road &amp; trip</title><trackList>
                <track><title>no</title><location>file:///home/me/Music/A%20B/c.flac</location></track>
                <track><location>http://example.com/x.mp3</location></track>
            </trackList></playlist>"#,
        );
        assert_eq!(p.title.as_deref(), Some("Road & trip"));
        assert_eq!(p.entries.len(), 2);
        assert_eq!(entry_path(&p.entries[0]).unwrap(), "/home/me/Music/A B/c.flac");
        assert_eq!(entry_path(&p.entries[1]), None);
    }

    #[test]
    fn entries_resolve_relative_absolute_and_from_elsewhere() {
        let r = resolver();
        let list = Path::new("/home/me/Music/lists/mine.m3u");
        // Relative to the playlist's folder.
        assert_eq!(
            r.resolve(list, "../JID/The Forever Story/02 Raydar.flac").as_deref(),
            Some("/home/me/Music/JID/The Forever Story/02 Raydar.flac")
        );
        // A file:// link with escapes.
        assert_eq!(
            r.resolve(list, "file:///home/me/Music/Caf%C3%A9%20Tacvba/Re/Las%20Flores.mp3")
                .as_deref(),
            Some("/home/me/Music/Café Tacvba/Re/Las Flores.mp3")
        );
        // Written on Windows: the folders after the drive still match.
        assert_eq!(
            r.resolve(list, r"D:\Music\Joji\SMITHEREENS\01 Glimpse of Us.flac").as_deref(),
            Some("/home/me/Music/Joji/SMITHEREENS/01 Glimpse of Us.flac")
        );
        // A shared file name with nothing else to tell them apart: not guessed.
        assert_eq!(r.resolve(list, r"E:\01 Glimpse of Us.flac"), None);
        // A name only one track has is enough.
        assert_eq!(
            r.resolve(list, "C:/old/02 raydar.FLAC").as_deref(),
            Some("/home/me/Music/JID/The Forever Story/02 Raydar.flac")
        );
        assert_eq!(r.resolve(list, "https://example.com/a.mp3"), None);
        assert_eq!(r.resolve(list, "missing.flac"), None);
    }
}
