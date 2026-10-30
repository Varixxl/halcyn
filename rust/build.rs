//! Builds Signalsmith Stretch (vendor/signalsmith, C++) for pitch and speed and libopus
//! (vendor/opus, C) for Opus, and bakes
//! Tidal's app keys into the core when ../tidal.properties (see tools/tidal-keys.sh)
//! or the TIDAL_CLIENT_ID / TIDAL_CLIENT_SECRET variables provide them. Without them the
//! keys are empty and Halcyn offers no Tidal.

use std::collections::HashMap;

fn main() {
    stretch();
    opus();
    let file = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../tidal.properties");
    println!("cargo:rerun-if-changed={}", file.display());
    println!("cargo:rerun-if-env-changed=TIDAL_CLIENT_ID");
    println!("cargo:rerun-if-env-changed=TIDAL_CLIENT_SECRET");
    let props: HashMap<String, String> = std::fs::read_to_string(&file)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.split_once('='))
        .map(|(k, v)| (k.trim().to_owned(), v.trim().to_owned()))
        .collect();
    for (env, key) in [("TIDAL_CLIENT_ID", "client_id"), ("TIDAL_CLIENT_SECRET", "client_secret")] {
        let value = std::env::var(env).ok().or_else(|| props.get(key).cloned()).unwrap_or_default();
        println!("cargo:rustc-env={env}={value}");
    }
}

fn stretch() {
    println!("cargo:rerun-if-changed=vendor/signalsmith");
    let mut build = cc::Build::new();
    build
        .cpp(true)
        .std("c++14")
        .file("vendor/signalsmith/wrapper.cpp")
        .include("vendor/signalsmith")
        // It runs per audio buffer: fast even in a debug build.
        .opt_level(3)
        .warnings(false);
    // Linked in, so the APK needs no libc++_shared.so of its own. libc++abi too: it has
    // the exceptions' type info (std::length_error...), and without it the core won't
    // load on Android at all.
    let android = std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android");
    if android {
        build.cpp_link_stdlib("c++_static");
    }
    build.compile("halcyn_stretch");
    if android {
        println!("cargo:rustc-link-lib=c++abi");
    }
}

/// libopus's plain C, without its CPU-specific extras: decoding needs little, and it builds
/// the same everywhere (no CMake, which Android and Windows would each need set up).
fn opus() {
    println!("cargo:rerun-if-changed=vendor/opus");
    let sources = std::fs::read_to_string("vendor/opus/sources.txt").expect("vendor/opus/sources.txt");
    let mut build = cc::Build::new();
    for file in sources.lines().filter(|l| !l.trim().is_empty()) {
        build.file(format!("vendor/opus/{file}"));
    }
    for dir in ["include", "celt", "silk", "silk/float", "src"] {
        build.include(format!("vendor/opus/{dir}"));
    }
    build
        .define("OPUS_BUILD", None)
        // MSVC has no variable-length arrays; alloca works everywhere.
        .define("USE_ALLOCA", None)
        .define("HAVE_LRINT", None)
        .define("HAVE_LRINTF", None)
        .define("PACKAGE_VERSION", "\"1.5.2\"")
        .opt_level(2)
        .warnings(false)
        .compile("halcyn_opus");
}
