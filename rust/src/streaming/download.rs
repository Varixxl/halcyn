//! A song from a service, played while it downloads. The parts (one file, or a DASH
//! stream's init and segments) are fetched in order into one cache file; the decoder reads
//! that file as it grows, waiting when it gets ahead. A finished download stays in the
//! cache, so playing the song again (or seeking back) needs no network.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, Weak};
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

#[derive(Default)]
struct Progress {
    written: u64,
    /// Known up front for a single file (its Content-Length); for DASH, once done.
    total: Option<u64>,
    done: bool,
    error: Option<String>,
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

/// Starts downloading `parts` into the cache as `<key>.<ext>` and returns a reader of it.
/// `total`: the whole length, when known before the download says.
pub fn start(
    dir: &Path,
    key: &str,
    ext: &str,
    parts: Vec<String>,
    total: Option<u64>,
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
    shared.0.lock().unwrap().total = total;
    active.insert(path.clone(), Arc::downgrade(&shared));

    let progress = shared.clone();
    let partial = path.clone();
    std::thread::Builder::new().name("stream download".into()).spawn(move || {
        let single = parts.len() == 1;
        let result = (|| -> Result<()> {
            let mut buf = vec![0u8; 64 << 10];
            for part in &parts {
                let (mut body, len) = http::get_reader(part)?;
                if single && total.is_none() {
                    progress.0.lock().unwrap().total = len;
                }
                loop {
                    let n = body.read(&mut buf)?;
                    if n == 0 {
                        break;
                    }
                    out.write_all(&buf[..n])?;
                    // Nobody's listening any more (the song was skipped): stop, and drop
                    // what's half there.
                    if Arc::strong_count(&progress) == 1 {
                        anyhow::bail!("abandoned");
                    }
                    let (lock, cond) = &*progress;
                    let mut p = lock.lock().unwrap();
                    p.written += n as u64;
                    cond.notify_all();
                }
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
                let _ = File::create(&done_marker);
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
