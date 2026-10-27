# Halcyn

A music player for Android, Linux and Windows. Flutter UI, Rust audio engine, bit-exact output where the device allows it, and its own high-quality resampling where it doesn't.

## Download

Get the latest version from [Releases](https://github.com/Varixxl/halcyn/releases/latest):

- **Linux:** `halcyn-linux-x64.tar.gz`. Unpack it anywhere and run `halcyn/halcyn`. Running `halcyn/install.sh` adds it to your app launcher (`--remove` takes it out). Uses PipeWire when it's there, ALSA otherwise.
- **Windows:** `halcyn-windows-x64.zip`. Unpack it and run `Halcyn\halcyn.exe`.
- **Android 8 or newer:** `halcyn-android-arm64-v8a.apk` fits almost every phone (`armeabi-v7a` is for old 32-bit phones, `x86_64` for emulators and Chromebooks). On first start it asks for access to your music files.
- **Streaming:** sign in to Tidal (lossless and hi-res, with a subscription) or YouTube Music in Settings. On Linux and Windows, YouTube Music songs need [yt-dlp](https://github.com/yt-dlp/yt-dlp) installed.
- **Halcyn account (optional):** keeps your linked services and playlists the same on every device. The service sign-ins are encrypted on your device with your password before they're uploaded; write down the recovery key it shows once, as nobody can reset the password for you.
- **Downloads:** streamed songs download from the best-quality service you're signed in to (Tidal's FLAC before YouTube Music's AAC) into `Music/Halcyn Downloads/Artist/Album`.
- **Discord:** shows what you're playing on your profile through the Discord app on your computer. A phone's songs show there too while you're signed in to your Halcyn account on both and Halcyn is open on the computer.

## Develop

- Rust (mise `rust@stable`) and `flutter_rust_bridge_codegen` 2.13.0 (`cargo install flutter_rust_bridge_codegen --version 2.13.0`).
- After changing anything in `rust/src/api`, run `flutter_rust_bridge_codegen generate`.
- Linux build: `flutter build linux` (needs cmake, ninja, clang, and the PipeWire and ALSA headers).
- Android build: `flutter build apk --release --split-per-abi`. Release signing reads `android/key.properties`; without it the debug key is used.
- Windows build: `flutter build windows` on Windows.
- Engine tests: `cd rust && cargo test` (the file tests need ffmpeg).
- App tests: `flutter test`, and `HALCYN_PW_TARGET=<null sink> flutter test integration_test -d linux` to drive the real app.
- Play a file without the UI: `cd rust && cargo run --example play -- <file>`.
- Tidal: `HALCYN_PYTHON=<a python with tidalapi> tools/tidal-keys.sh` writes the git-ignored `tidal.properties` with the app keys the Tidal sign-in needs; without it Halcyn builds without Tidal. YouTube Music songs play through `yt-dlp` on a computer (it must be installed) and NewPipe's extractor on Android. Live checks against the real services: `cd rust && cargo test live_youtube -- --ignored`, and `HALCYN_TEST_TIDAL=<tidalapi session JSON> cargo test live_tidal -- --ignored`.
- Account server: Supabase project `halcyn`; its schema is in `supabase/migrations` (`supabase db push`). Live check: `HALCYN_TEST_ACCOUNT=1 flutter test integration_test/account_test.dart -d linux` makes a throwaway account and deletes it.
- Icons: edit `assets/icon/*.svg`, then run `tool/icons.sh`.

## Releasing

Push a tag such as `v0.2.0`. GitHub Actions (`.github/workflows/release.yml`) builds all three platforms and publishes them as a release. Android signing comes from the `ANDROID_KEYSTORE` (base64 of the `.jks`) and `ANDROID_KEY_PASSWORD` secrets.

## Credits

- Headphone corrections from [AutoEq](https://github.com/jaakkopasanen/AutoEq) by Jaakko Pasanen (MIT).
- [Inter](https://rsms.me/inter/) typeface by Rasmus Andersson (SIL Open Font License, `assets/fonts/OFL.txt`).
