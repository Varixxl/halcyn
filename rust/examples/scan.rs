//! Scans folders into a library and prints a summary:
//! `cargo run --release --example scan -- <data dir> <cache dir> [folder...]`.

use std::path::Path;
use std::time::Instant;

use halcyn_core::library::Library;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut library = Library::open(Path::new(&args[0]), Path::new(&args[1])).unwrap();
    if args.len() > 2 {
        library.set_folders(&args[2..]).unwrap();
    }
    let started = Instant::now();
    library.scan(|_, _| {}).unwrap();
    let tracks = library.tracks().unwrap();
    println!("{} tracks in {:.2?}", tracks.len(), started.elapsed());
    let with_art = tracks.iter().filter(|t| t.art.is_some()).count();
    println!("{with_art} with art");
    for t in tracks.iter().take(3) {
        println!("{t:?}");
    }
}
