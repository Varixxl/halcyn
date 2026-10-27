import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A published version of Halcyn.
class Release {
  const Release({
    required this.version,
    required this.notes,
    required this.page,
    required this.assets,
  });

  /// From the tag: v1.2.3 is 1.2.3.
  final String version;
  final String notes;
  final Uri page;
  final List<ReleaseAsset> assets;

  factory Release.fromJson(Map json) => Release(
    version: (json['tag_name'] as String).replaceFirst(RegExp('^v'), ''),
    notes: json['body'] as String? ?? '',
    page: Uri.parse(json['html_url'] as String),
    assets: [
      for (final a in json['assets'] as List)
        ReleaseAsset(
          name: a['name'] as String,
          url: Uri.parse(a['browser_download_url'] as String),
          size: a['size'] as int,
          sha256: switch (a['digest']) {
            final String d when d.startsWith('sha256:') => d.substring(7),
            _ => null,
          },
        ),
    ],
  );
}

class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
    this.sha256,
  });

  final String name;
  final Uri url;
  final int size;

  /// Hex, when GitHub knows it (it does for anything uploaded since mid-2025).
  final String? sha256;
}

/// 1.10.0 > 1.9.2. Anything after a '-' or '+' is ignored.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
    for (final p in v.split(RegExp('[-+]')).first.split('.'))
      int.tryParse(p) ?? 0,
  ];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

enum UpdateStage {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  installing,

  /// Installed; restarting finishes it (desktop).
  ready,
  failed,
}

const _android = MethodChannel('halcyn/android');

/// Keeps Halcyn up to date from its GitHub releases: checks once a day (if on), offers
/// the new version, and installs it in place. On Android the system installer takes the
/// APK (signed with the same key, so it updates over the old one); on Linux and Windows
/// the bundle's folder is replaced and Halcyn restarts.
class Updater extends ChangeNotifier {
  Updater({
    required this.settings,
    required this.cacheDir,
    required this.current,
    String? bundleDir,
    Uri? api,
    String? platform,
    this.persist = true,
  }) : bundleDir = bundleDir ?? File(Platform.resolvedExecutable).parent.path,
       api =
           api ??
           Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
       platform = platform ?? Platform.operatingSystem;

  static const repo = 'Varixxl/halcyn';
  static final releasesPage = Uri.parse('https://github.com/$repo/releases');

  final File settings;
  final Directory cacheDir;

  /// The version running now.
  final String current;

  /// Where the running app's files are (Linux and Windows).
  final String bundleDir;
  final Uri api;
  final String platform;
  final bool persist;

  bool auto = true;

  /// A version the user said "later" to: not offered again on its own.
  String? dismissed;
  DateTime? lastCheck;

  UpdateStage stage = UpdateStage.idle;
  Release? latest;
  double progress = 0;
  String? error;

  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 15);

  /// The new version, if there is one.
  Release? get available => switch (latest) {
    final r? when compareVersions(r.version, current) > 0 => r,
    _ => null,
  };

  /// True when an automatic check found a version the user hasn't dismissed yet.
  bool offer = false;

  /// Why this copy can't update itself, if it can't. It can still say there's a new
  /// version.
  String? get unsupported {
    if (platform == 'android') return null;
    if (platform != 'linux' && platform != 'windows') {
      return 'Updates aren\'t supported here';
    }
    final dir = bundleDir.replaceAll('\\', '/');
    if (dir.contains('/build/linux/') || dir.contains('/build/windows/')) {
      return 'This copy was built from source; update it with git';
    }
    return null;
  }

  Future<void> load() async {
    try {
      final saved = jsonDecode(await settings.readAsString()) as Map;
      auto = saved['auto'] as bool? ?? true;
      dismissed = saved['dismissed'] as String?;
      lastCheck = DateTime.tryParse(saved['lastCheck'] as String? ?? '');
    } on Object {
      // Nothing saved yet.
    }
    if (platform != 'android') unawaited(_cleanUp());
  }

  void _save() {
    if (!persist) return;
    settings
        .writeAsString(
          jsonEncode({
            'auto': auto,
            'dismissed': dismissed,
            'lastCheck': lastCheck?.toIso8601String(),
          }),
        )
        .catchError((Object e) {
          debugPrint('saving update settings: $e');
          return settings;
        });
  }

  void setAuto(bool on) {
    auto = on;
    _save();
    notifyListeners();
  }

  /// A check a little after startup, at most once a day.
  void checkLater() {
    if (!auto) return;
    final last = lastCheck;
    if (last != null && DateTime.now().difference(last).inHours < 20) return;
    Timer(const Duration(seconds: 20), () async {
      await check();
      if (available case final r? when r.version != dismissed) {
        offer = true;
        notifyListeners();
      }
    });
  }

  /// "Later": stop offering this version.
  void dismiss() {
    offer = false;
    dismissed = available?.version;
    _save();
    notifyListeners();
  }

  Future<void> check() async {
    if (stage == UpdateStage.checking || stage == UpdateStage.downloading) {
      return;
    }
    stage = UpdateStage.checking;
    error = null;
    notifyListeners();
    try {
      final request = await _http.getUrl(api);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'Halcyn/$current');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('GitHub answered ${response.statusCode}');
      }
      latest = Release.fromJson(jsonDecode(body) as Map);
      lastCheck = DateTime.now();
      _save();
      stage = available == null ? UpdateStage.upToDate : UpdateStage.available;
    } on Object catch (e) {
      error = 'Couldn\'t check for updates: ${_describe(e)}';
      stage = UpdateStage.failed;
    }
    notifyListeners();
  }

  /// The file this platform installs from.
  Future<String?> _assetName() async => switch (platform) {
    'linux' => 'halcyn-linux-x64.tar.gz',
    'windows' => 'halcyn-windows-x64.zip',
    'android' =>
      'halcyn-android-${await _android.invokeMethod<String>('abi')}.apk',
    _ => null,
  };

  /// Downloads and installs the new version.
  Future<void> install() async {
    final release = available;
    if (release == null || unsupported != null) return;
    if (stage == UpdateStage.downloading || stage == UpdateStage.installing) {
      return;
    }
    offer = false;
    error = null;
    try {
      if (platform == 'android' &&
          await _android.invokeMethod<bool>('canInstall') != true) {
        // Android asks once whether Halcyn may install apps; then try again.
        await _android.invokeMethod('allowInstalls');
        error = 'Allow Halcyn to install updates, then tap Update again.';
        stage = UpdateStage.available;
        return notifyListeners();
      }
      final name = await _assetName();
      final asset = release.assets.where((a) => a.name == name).firstOrNull;
      if (asset == null) throw StateError('the release has no $name');
      stage = UpdateStage.downloading;
      progress = 0;
      notifyListeners();
      final file = await _download(asset);
      stage = UpdateStage.installing;
      notifyListeners();
      switch (platform) {
        case 'android':
          await _android.invokeMethod('installApk', {'path': file.path});
          // Android shows its own confirmation, then restarts Halcyn.
          stage = UpdateStage.available;
        case 'linux':
          await _installLinux(file);
          stage = UpdateStage.ready;
        case 'windows':
          await _stageWindows(file);
          stage = UpdateStage.ready;
      }
    } on Object catch (e) {
      error = 'The update didn\'t install: ${_describe(e)}';
      stage = UpdateStage.failed;
    }
    notifyListeners();
  }

  Future<File> _download(ReleaseAsset asset) async {
    final dir = Directory('${cacheDir.path}/update');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final file = File('${dir.path}/${asset.name}');
    final request = await _http.getUrl(asset.url);
    request.headers.set(HttpHeaders.userAgentHeader, 'Halcyn/$current');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('the download answered ${response.statusCode}');
    }
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    final sink = file.openWrite();
    var received = 0;
    var shown = 0.0;
    try {
      await for (final chunk in response) {
        received += chunk.length;
        hasher.add(chunk);
        sink.add(chunk);
        if (received / asset.size - shown >= 0.01) {
          shown = progress = received / asset.size;
          notifyListeners();
        }
      }
    } finally {
      await sink.close();
      hasher.close();
    }
    if (received != asset.size) {
      throw StateError('the download stopped early');
    }
    if (asset.sha256 case final expected?
        when digest.value.toString() != expected) {
      await file.delete();
      throw StateError('the download is damaged (its checksum doesn\'t match)');
    }
    return file;
  }

  /// Unpacks next to the bundle (same disk, so the swap is two renames), then swaps.
  /// The running copy keeps working from the old files until it restarts.
  Future<void> _installLinux(File archive) async {
    final bundle = Directory(bundleDir);
    final parent = bundle.parent.path;
    final staging = Directory('$parent/.halcyn-update');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create();
    final tar = await Process.run('tar', [
      '-xzf',
      archive.path,
      '-C',
      staging.path,
    ]);
    if (tar.exitCode != 0) throw StateError('unpacking failed: ${tar.stderr}');
    final unpacked = Directory('${staging.path}/halcyn');
    if (!await File('${unpacked.path}/halcyn').exists()) {
      throw StateError('the download doesn\'t contain Halcyn');
    }
    final old = Directory('$parent/.halcyn-old');
    if (await old.exists()) await old.delete(recursive: true);
    await bundle.rename(old.path);
    try {
      await unpacked.rename(bundle.path);
    } on Object {
      await old.rename(bundle.path);
      rethrow;
    }
    await staging.delete(recursive: true);
  }

  /// Windows can't replace files that are in use, so a script waits for Halcyn to
  /// close, copies the new files over and starts it again.
  Future<void> _stageWindows(File archive) async {
    final staging = Directory('${cacheDir.path}/update/unpacked');
    final expand = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Expand-Archive -LiteralPath "${archive.path}" '
          '-DestinationPath "${staging.path}" -Force',
    ]);
    if (expand.exitCode != 0) {
      throw StateError('unpacking failed: ${expand.stderr}');
    }
    final unpacked = '${staging.path}\\Halcyn';
    if (!await File('$unpacked\\halcyn.exe').exists()) {
      throw StateError('the download doesn\'t contain Halcyn');
    }
    // Fail now, not after quitting, if the folder can't be written (Program Files).
    final probe = File('$bundleDir\\.halcyn-write-test');
    await probe.writeAsString('');
    await probe.delete();
    await File('${cacheDir.path}/update/apply.ps1').writeAsString('''
Wait-Process -Id $pid -ErrorAction SilentlyContinue
robocopy "$unpacked" "$bundleDir" /E /R:10 /W:1 | Out-Null
Start-Process -FilePath "$bundleDir\\halcyn.exe"
''');
  }

  /// Starts the new version and quits this one. `beforeExit` saves what needs saving.
  Future<void> restart({Future<void> Function()? beforeExit}) async {
    if (stage != UpdateStage.ready) return;
    await beforeExit?.call();
    if (platform == 'windows') {
      await Process.start('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        '${cacheDir.path}\\update\\apply.ps1',
      ], mode: ProcessStartMode.detached);
    } else {
      // After this copy has gone, so the new one gets the casting ports.
      await Process.start('sh', [
        '-c',
        'sleep 1; exec "\$0"',
        '$bundleDir/halcyn',
      ], mode: ProcessStartMode.detached);
    }
    exit(0);
  }

  /// The previous version's files, kept until the new one starts.
  Future<void> _cleanUp() async {
    try {
      final old = Directory('${Directory(bundleDir).parent.path}/.halcyn-old');
      if (await old.exists()) await old.delete(recursive: true);
    } on Object {
      // Not ours to clean, or not there.
    }
  }

  String _describe(Object e) => switch (e) {
    SocketException() || TimeoutException() => 'no connection to GitHub',
    HttpException(:final message) => message,
    StateError(:final message) => message,
    PlatformException(:final message) => message ?? '$e',
    _ => '$e',
  };

  @override
  void dispose() {
    _http.close(force: true);
    super.dispose();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
