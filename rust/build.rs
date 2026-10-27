//! Builds Signalsmith Stretch (vendor/signalsmith, C++) for pitch and speed, and bakes
//! Tidal's app keys into the core when ../tidal.properties (see tools/tidal-keys.sh)
//! or the TIDAL_CLIENT_ID / TIDAL_CLIENT_SECRET variables provide them. Without them the
//! keys are empty and Halcyn offers no Tidal.

use std::collections::HashMap;

fn main() {
    stretch();
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
    // Linked in, so the APK needs no libc++_shared.so of its own.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        build.cpp_link_stdlib("c++_static");
    }
    build.compile("halcyn_stretch");
}
