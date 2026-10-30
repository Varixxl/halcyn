//! A song from a service, played while it downloads. The parts (one file, or a DASH
//! stream's init and segments, or a long file in ranges) are fetched several at once and
//! written in order into one cache file; the decoder reads that file as it grows, waiting
//! when it gets ahead. A finished download stays in the
//! cache, so playing the song again (or seeking back) needs no network.

use std::collections::{BTreeMap, HashMap};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex, Weak};
use std::time::{Duration, SystemTime};

use anyhow::Result;
use symphonia::core::io::MediaSource;

use super::http;

/// How much the stream cache may hold before the oldest songs go.
const CACHE_LIMIT: u64 = 2 << 30;
/// The length given for a stream still downloading whose length isn't known yet.
const UNKNOWN_END: u64 = 1 << 40;
/// How long a read waits for the network before giving up.
const STALL: Duration = Duration::from_secs(45);
/// Parts fetched at once: one at a time, each waits a round trip for nothing.
const AHEAD: usize = 8;

#[derive(Default)]
struct Progress {
    written: u64,
    /// Known up front for a single file (its Content-Length); for DASH, once done.
    total: Option<u64>,
    done: bool,
    error: Option<String>,
    parts: usize,
    parts_done: usize,
}

type Shared = Arc<(Mutex<Progress>, Condvar)>;

/// Downloads under way, by cache file: opening a song again while it downloads reads the
/// same download.
static ACTIVE: Mutex<Option<HashMap<PathBuf, Weak<(Mutex<Progress>, Condvar)>>>> = Mutex::new(None);

/// What `open` reads: the cache file, as far as it's been written.
pub struct Growing {
    file: File,
    pos: u64,
    shared: Shared,
}

/// The finished cache file for `key`, if there is one.
pub fn cached(dir: &Path, key: &str, ext: &str) -> Option<PathBuf> {
    let file = dir.join(format!("{key}.{ext}"));
    dir.join(format!("{key}.done")).exists().then_some(file).filter(|f| f.exists())
}

/// The length the service gave a finished download (kept in its `.done` marker), in seconds.
pub fn length(dir: &Path, key: &str) -> Option<f64> {
    let text = std::fs::read_to_string(dir.join(format!("{key}.done"))).ok()?;
    text.trim().parse().ok().filter(|s: &f64| *s > 0.0)
}

/// How far along the download into the cache as `<key>.*` is, from 0 to 1; None when
/// there's none under way.
pub fn progress(dir: &Path, key: &str) -> Option<f64> {
    let active = ACTIVE.lock().unwrap();
    let shared = active.as_ref()?.iter().find_map(|(path, d)| {
        (path.parent() == Some(dir) && path.file_stem().is_some_and(|s| s == key)).then(|| d.upgrade()).flatten()
    })?;
    let p = shared.0.lock().unwrap();
    Some(match (p.total, p.parts) {
        (_, _) if p.done => 1.0,
        (Some(total), _) if total > 0 && total < UNKNOWN_END => p.written as f64 / total as f64,
        (_, parts) if parts > 1 => p.parts_done as f64 / parts as f64,
        _ => 0.0,
    })
}

/// Starts downloading `parts` into the cache as `<key>.<ext>` and returns a reader of it.
/// `total`: the whole length, when known before the download says. `secs`: the song's
/// length, remembered with the finished download (see [length]).
pub fn start(
    dir: &Path,
    key: &str,
    ext: &str,
    parts: Vec<String>,
    total: Option<u64>,
    secs: Option<f64>,
) -> Result<Growing> {
    std::fs::create_dir_all(dir)?;
    let path = dir.join(format!("{key}.{ext}"));
    let mut active = ACTIVE.lock().unwrap();
    let active = active.get_or_insert_with(HashMap::new);
    active.retain(|_, d| d.strong_count() > 0);
    if let Some(shared) = active.get(&path).and_then(Weak::upgrade) {
        if shared.0.lock().unwrap().error.is_none() {
            return Ok(Growing { file: File::open(&path)?, pos: 0, shared });
        }
    }
    prune(dir);
    let done_marker = dir.join(format!("{key}.done"));
    let _ = std::fs::remove_file(&done_marker);
    let mut out = OpenOptions::new().create(true).write(true).truncate(true).open(&path)?;
    let file = File::open(&path)?;
    let shared: Shared = Arc::default();
    {
        let mut p = shared.0.lock().unwrap();
        p.total = total;
        p.parts = parts.len();
    }
    active.insert(path.clone(), Arc::downgrade(&shared));

    let progress = shared.clone();
    let partial = path.clone();
    std::thread::Builder::new().name("stream download".into()).spawn(move || {
        let result = (|| -> Result<()> {
            // Nobody's listening any more (the song was skipped): stop, and drop what's
            // half there.
            let abandoned = || Arc::strong_count(&progress) == 1;
            let mut wrote = |bytes: &[u8], part_done: bool| -> Result<()> {
                out.write_all(bytes)?;
                if abandoned() {
                    anyhow::bail!("abandoned");
                }
                let (lock, cond) = &*progress;
                let mut p = lock.lock().unwrap();
                p.written += bytes.len() as u64;
                p.parts_done += part_done as usize;
                cond.notify_all();
                Ok(())
            };
            if let [part] = &parts[..] {
                // One file: written as it comes, so playing can start at once.
                let (mut body, len) = http::get_reader(part)?;
                if total.is_none() {
                    progress.0.lock().unwrap().total = len;
                }
                let mut buf = vec![0u8; 64 << 10];
                loop {
                    let n = body.read(&mut buf)?;
                    if n == 0 {
                        break;
                    }
                    wrote(&buf[..n], false)?;
                }
            } else {
                in_order(&parts, AHEAD, fetch_part, abandoned, |bytes| wrote(bytes, true))?;
            }
            out.flush()?;
            Ok(())
        })();
        let (lock, cond) = &*progress;
        let mut p = lock.lock().unwrap();
        p.done = true;
        match result {
            Ok(()) => {
                p.total = Some(p.written);
                let _ = std::fs::write(&done_marker, secs.map(|s| s.to_string()).unwrap_or_default());
            }
            Err(e) => {
                let _ = std::fs::remove_file(&partial);
                p.error = Some(e.to_string());
            }
        }
        cond.notify_all();
    })?;

    Ok(Growing { file, pos: 0, shared })
}

/// Fetches `parts` up to `ahead` at a time, handing each whole to `take` in their order.
fn in_order(
    parts: &[String],
    ahead: usize,
    fetch: impl Fn(&str) -> Result<Vec<u8>> + Sync,
    abandoned: impl Fn() -> bool,
    mut take: impl FnMut(&[u8]) -> Result<()>,
) -> Result<()> {
    let next = AtomicUsize::new(0);
    let stop = AtomicBool::new(false);
    // How many parts have been taken: a fetcher waits rather than get more than `ahead`
    // past it, so memory stays small.
    let taken = (Mutex::new(0usize), Condvar::new());
    let (tx, rx) = mpsc::channel::<(usize, Result<Vec<u8>>)>();
    std::thread::scope(|scope| {
        for _ in 0..ahead.min(parts.len()) {
            let (tx, next, stop, taken, fetch) = (tx.clone(), &next, &stop, &taken, &fetch);
            scope.spawn(move || loop {
                let i = next.fetch_add(1, Ordering::SeqCst);
                if i >= parts.len() {
                    break;
                }
                {
                    let mut n = taken.0.lock().unwrap();
                    while i >= *n + ahead && !stop.load(Ordering::SeqCst) {
                        n = taken.1.wait(n).unwrap();
                    }
                }
                if stop.load(Ordering::SeqCst) || tx.send((i, fetch(&parts[i]))).is_err() {
                    break;
                }
            });
        }
        drop(tx);
        let result = (|| -> Result<()> {
            let mut waiting = BTreeMap::new();
            let mut want = 0;
            for (i, part) in rx.iter() {
                waiting.insert(i, part);
                while let Some(part) = waiting.remove(&want) {
                    take(&part?)?;
                    want += 1;
                    *taken.0.lock().unwrap() = want;
                    taken.1.notify_all();
                }
                if abandoned() {
                    anyhow::bail!("abandoned");
                }
            }
            if want < parts.len() {
                anyhow::bail!("the download stopped early");
            }
            Ok(())
        })();
        if result.is_err() {
            stop.store(true, Ordering::SeqCst);
            taken.1.notify_all();
        }
        result
    })
}

/// One part, whole. The CDN sometimes drops a connection halfway: tried again.
fn fetch_part(url: &str) -> Result<Vec<u8>> {
    let mut last = None;
    for attempt in 0..3 {
        if attempt > 0 {
            std::thread::sleep(Duration::from_millis(500 * attempt));
        }
        let result = http::get_reader(url).and_then(|(mut body, len)| {
            let mut bytes = Vec::with_capacity(len.unwrap_or(0).min(16 << 20) as usize);
            body.read_to_end(&mut bytes)?;
            Ok(bytes)
        });
        match result {
            Ok(bytes) => return Ok(bytes),
            // A refusal won't change.
            Err(e) if e.downcast_ref::<http::Status>().is_some() => return Err(e),
            Err(e) => last = Some(e),
        }
    }
    Err(last.unwrap())
}

/// Drops the oldest finished songs once the cache is over its limit.
fn prune(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut files: Vec<(PathBuf, u64, SystemTime)> = entries
        .flatten()
        .filter_map(|e| {
            let meta = e.metadata().ok()?;
            let path = e.path();
            (path.extension()? != "done")
                .then(|| (path, meta.len(), meta.modified().unwrap_or(SystemTime::UNIX_EPOCH)))
        })
        .collect();
    let mut total: u64 = files.iter().map(|f| f.1).sum();
    files.sort_by_key(|f| f.2);
    for (path, len, _) in files {
        if total <= CACHE_LIMIT {
            break;
        }
        if std::fs::remove_file(&path).is_ok() {
            let _ = std::fs::remove_file(path.with_extension("done"));
            total -= len;
        }
    }
}

impl Growing {
    /// Waits until byte `upto` is written (or the download ends). Returns how much is.
    fn wait_for(&self, upto: u64) -> std::io::Result<u64> {
        let (lock, cond) = &*self.shared;
        let mut p = lock.lock().unwrap();
        loop {
            if p.written >= upto || p.done {
                if let (Some(e), true) = (&p.error, p.written < upto) {
                    return Err(std::io::Error::other(e.clone()));
                }
                return Ok(p.written);
            }
            let (next, timeout) = cond.wait_timeout(p, STALL).unwrap();
            p = next;
            if timeout.timed_out() && p.written < upto && !p.done {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "the stream stalled",
                ));
            }
        }
    }

    fn total(&self) -> Option<u64> {
        self.shared.0.lock().unwrap().total
    }
}

impl Read for Growing {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let available = self.wait_for(self.pos + 1)?;
        if available <= self.pos {
            return Ok(0);
        }
        let n = ((available - self.pos) as usize).min(buf.len());
        self.file.seek(SeekFrom::Start(self.pos))?;
        let n = self.file.read(&mut buf[..n])?;
        self.pos += n as u64;
        Ok(n)
    }
}

impl Seek for Growing {
    fn seek(&mut self, to: SeekFrom) -> std::io::Result<u64> {
        let pos = match to {
            SeekFrom::Start(n) => n as i64,
            SeekFrom::Current(d) => self.pos as i64 + d,
            SeekFrom::End(d) => {
                // The end of a DASH stream is known once it's all here. Until then, a far end
                // lets the MP4 reader start at once (it asks first thing); reading past the
                // real one finds the end of the stream.
                let end = self.total().unwrap_or(UNKNOWN_END);
                end as i64 + d
            }
        };
        if pos < 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "seek before the start",
            ));
        }
        self.pos = pos as u64;
        Ok(self.pos)
    }
}

impl MediaSource for Growing {
    fn is_seekable(&self) -> bool {
        true
    }

    fn byte_len(&self) -> Option<u64> {
        self.total()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    /// Parts that take different times arrive in order, several fetched at once, never
    /// more than `ahead` past what's written.
    #[test]
    fn parts_are_fetched_together_and_kept_in_order() {
        let parts: Vec<String> = (0..24).map(|i| i.to_string()).collect();
        let started = Instant::now();
        let fetched = Mutex::new(vec![]);
        let mut got = vec![];
        in_order(
            &parts,
            8,
            |p| {
                let i: u64 = p.parse()?;
                fetched.lock().unwrap().push(i);
                std::thread::sleep(Duration::from_millis(20 + (i * 7) % 30));
                Ok(i.to_le_bytes().to_vec())
            },
            || false,
            |bytes| {
                let i = u64::from_le_bytes(bytes.try_into()?);
                // Nothing fetched further ahead than allowed.
                assert!(fetched.lock().unwrap().iter().all(|&f| f < i + 8 + 1));
                got.push(i);
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(got, (0..24).collect::<Vec<_>>());
        // One at a time takes over 24 * 20 ms.
        assert!(started.elapsed() < Duration::from_millis(250), "{:?}", started.elapsed());
    }

    #[test]
    fn a_part_that_fails_stops_the_rest() {
        let parts: Vec<String> = (0..50).map(|i| i.to_string()).collect();
        let fetched = AtomicUsize::new(0);
        let result = in_order(
            &parts,
            4,
            |p| {
                fetched.fetch_add(1, Ordering::SeqCst);
                if p == "3" {
                    anyhow::bail!("gone");
                }
                Ok(vec![1])
            },
            || false,
            |_| Ok(()),
        );
        assert_eq!(result.unwrap_err().to_string(), "gone");
        assert!(fetched.load(Ordering::SeqCst) < 12);
    }
}
