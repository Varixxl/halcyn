import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../rust/api/library.dart';
import 'library.dart';
import 'player.dart';
import 'streaming.dart' show bareTitle, isStream;

/// An HTTP GET: the status and body.
typedef Get = Future<(int, Uint8List)> Function(Uri url);

/// Downloads what the library is missing, in the background: covers for albums without
/// one (MusicBrainz finds the album, the Cover Art Archive has the picture) and lyrics
/// for songs without (LRCLIB, synced when it has them). Each can be turned off in
/// Settings. Something not found is asked about again after [retryAfter].
class Fetcher extends ChangeNotifier {
  Fetcher({
    required this.library,
    required this.player,
    required this.settings,
    required this.userAgent,
    this.online = true,
    this.persist = true,
    this._get,
    Future<String?> Function(List<String> paths, Uint8List image)? storeArt,
    this.musicBrainzGap = const Duration(milliseconds: 1100),
    Future<void> Function()? reload,
  }) : _reloadLibrary = reload,
       _storeArt =
           storeArt ??
           ((paths, image) =>
               libraryStoreFetchedArt(paths: paths, image: image));

  final LibraryController library;
  final PlayerController player;

  /// `fetch.json`: the two switches, and when each album or song was last looked for.
  final File settings;
  final String userAgent;

  /// False under test: nothing is downloaded.
  final bool online;
  final bool persist;

  /// MusicBrainz asks for at most one request a second.
  final Duration musicBrainzGap;
  static const retryAfter = Duration(days: 30);

  final Get? _get;
  final Future<void> Function()? _reloadLibrary;
  final Future<String?> Function(List<String> paths, Uint8List image) _storeArt;

  bool art = true;
  bool lyrics = true;

  /// What it's doing, for Settings: "Looking for covers: 3 of 20", or null.
  String? status;

  /// Albums ("artist\u0000title", lowercased) and track paths → when last looked for,
  /// in Unix seconds.
  final _artTried = <String, int>{};
  final _lyricsTried = <String, int>{};

  bool _running = false;
  bool _again = false;
  Timer? _soon;
  DateTime _lastMusicBrainz = DateTime(2000);
  final _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 5);

  Future<void> load() async {
    try {
      final json = jsonDecode(await settings.readAsString()) as Map;
      art = json['art'] != false;
      lyrics = json['lyrics'] != false;
      _artTried.addAll(((json['artTried'] as Map?) ?? {}).cast<String, int>());
      _lyricsTried.addAll(
        ((json['lyricsTried'] as Map?) ?? {}).cast<String, int>(),
      );
    } on Object {
      // Nothing saved yet.
    }
  }

  /// Looks for what's missing a little after startup, and after each rescan.
  void start() {
    library.addListener(_libraryChanged);
    player.addListener(_playerChanged);
    _later(const Duration(seconds: 5));
  }

  String? _playing;

  /// A song starts: its lyrics now, if it has none yet (streamed songs, songs not looked
  /// for yet), so they're there when the lyrics are opened.
  void _playerChanged() {
    final track = player.current;
    if (track == null || track.path == _playing) return;
    _playing = track.path;
    if (!isStream(track.path) && File(lyricsPath(track.path)).existsSync()) {
      return;
    }
    unawaited(lyricsNow(track));
  }

  /// Lookups under way, and songs LRCLIB didn't have, while the app runs.
  final _asked = <String, Future<String?>>{};

  /// The song's downloaded lyrics, looked up on LRCLIB first if there are none (once
  /// per song while the app runs). Reading them counts as using them: see
  /// [clearUnusedLyrics].
  Future<String?> lyricsNow(Track track) async {
    final file = downloadedLyrics(track.path);
    if (file == null) return null;
    try {
      final text = await file.readAsString();
      await touchLyrics(file);
      return text;
    } on Object {
      // Not downloaded yet.
    }
    if (!online || !lyrics || track.artists.isEmpty) return null;
    return _asked[track.path] ??= _download(track, file);
  }

  Future<String?> _download(Track track, File file) async {
    try {
      final text = await _lookUpLyrics(track, search: true);
      _lyricsTried[track.path] = _now();
      if (text == null) return null;
      await file.parent.create(recursive: true);
      await file.writeAsString(text);
      _asked.remove(track.path);
      library.addLyrics({track.path});
      unawaited(_save());
      return text;
    } on Object catch (e) {
      // Offline or LRCLIB trouble: ask again next time it plays.
      _asked.remove(track.path);
      debugPrint('fetcher: lyrics for ${track.path}: $e');
      return null;
    }
  }

  /// Deletes the downloaded lyrics that haven't been shown or played for [unused]
  /// (never `.lrc` files beside the music). Returns how many went.
  Future<int> clearUnusedLyrics([
    Duration unused = const Duration(days: 7),
  ]) async {
    final dir = downloadedLyricsDir;
    if (dir == null || !await dir.exists()) return 0;
    final before = DateTime.now().subtract(unused);
    final gone = <String>{};
    await for (final entry in dir.list()) {
      if (entry is! File || !entry.path.endsWith('.lrc')) continue;
      try {
        if ((await entry.lastModified()).isBefore(before)) {
          await entry.delete();
          gone.add(entry.uri.pathSegments.last);
        }
      } on Object {
        // Gone already, or in use.
      }
    }
    if (gone.isEmpty) return 0;
    // Not downloaded again in the background for a while; playing them still does.
    final paths = [
      for (final t in [...library.tracks, ...library.streams.values])
        if (gone.contains(downloadedLyrics(t.path)!.uri.pathSegments.last))
          t.path,
    ];
    for (final path in paths) {
      _lyricsTried[path] = _now();
      _asked.remove(path);
    }
    library.removeLyrics(paths.toSet());
    await _save();
    return gone.length;
  }

  void setArt(bool on) {
    art = on;
    _changed();
  }

  void setLyrics(bool on) {
    lyrics = on;
    _changed();
  }

  void _changed() {
    notifyListeners();
    _save();
    _later(Duration.zero);
  }

  void _libraryChanged() {
    // Its own reloads (new covers) aren't news.
    if (library.scanning == null && !_running) {
      _later(const Duration(seconds: 3));
    }
  }

  void _later(Duration wait) {
    _soon?.cancel();
    _soon = Timer(wait, run);
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  bool _due(Map<String, int> tried, String key) =>
      _now() - (tried[key] ?? 0) > retryAfter.inSeconds;

  static String albumKey(Album a) =>
      '${a.artist.toLowerCase()}\u0000${a.title.toLowerCase()}';

  /// Albums with tags enough to look up, no cover, and not looked for lately.
  List<Album> get missingArt => [
    for (final a in library.albums)
      if (a.art == null &&
          a.tracks.any((t) => t.album != null) &&
          a.artist != 'Unknown artist' &&
          _due(_artTried, albumKey(a)))
        a,
  ];

  List<Track> get missingLyrics => [
    for (final t in library.tracks)
      if (!library.withLyrics.contains(t.path) &&
          t.artists.isNotEmpty &&
          _due(_lyricsTried, t.path))
        t,
  ];

  /// One pass over what's missing. Stops early (to try again later) when offline.
  Future<void> run() async {
    if (!online || library.scanning != null) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        if (art) await _fetchArt();
        if (lyrics) await _fetchLyrics();
      } while (_again);
    } on SocketException catch (e) {
      debugPrint('fetcher: offline ($e)');
    } on HttpException catch (e) {
      debugPrint('fetcher: $e');
    } on TimeoutException catch (e) {
      debugPrint('fetcher: $e');
    } finally {
      _running = false;
      _setStatus(null);
      await _save();
    }
  }

  Future<void> _fetchArt() async {
    final albums = missingArt;
    var found = 0;
    for (final (i, album) in albums.indexed) {
      if (!art) return;
      _setStatus('Looking for covers: ${i + 1} of ${albums.length}');
      final image = await _cover(album);
      if (image != null) {
        final key = await _storeArt([
          for (final t in album.tracks) t.path,
        ], image);
        if (key != null) found++;
      }
      _artTried[albumKey(album)] = _now();
      // Show them as they come, a few at a time.
      if (found > 0 && found % 5 == 0) await _reload();
      if (i % 10 == 9) await _save();
    }
    if (found % 5 != 0) await _reload();
  }

  /// The album's front cover, 500 px, or null if there isn't one to be found.
  Future<Uint8List?> _cover(Album album) async {
    String quote(String s) =>
        '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
    final query =
        'releasegroup:${quote(album.title)} AND artist:${quote(album.artist)}';
    final wait = _lastMusicBrainz
        .add(musicBrainzGap)
        .difference(DateTime.now());
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    _lastMusicBrainz = DateTime.now();
    final (status, body) = await _fetch(
      Uri.https('musicbrainz.org', '/ws/2/release-group/', {
        'query': query,
        'fmt': 'json',
        'limit': '5',
      }),
    );
    if (status == 503) throw const HttpException('MusicBrainz is busy');
    if (status != 200) return null;
    final groups = (jsonDecode(utf8.decode(body)) as Map)['release-groups'];
    for (final group in (groups as List?) ?? const []) {
      if (group is! Map || ((group['score'] as num?) ?? 0) < 90) continue;
      final (status, image) = await _fetch(
        Uri.https(
          'coverartarchive.org',
          '/release-group/${group['id']}/front-500',
        ),
      );
      if (status == 200 && image.isNotEmpty) return image;
    }
    return null;
  }

  Future<void> _fetchLyrics() async {
    final dir = downloadedLyricsDir;
    if (dir == null) return;
    await dir.create(recursive: true);
    final tracks = missingLyrics;
    final got = <String>{};
    var failures = 0;
    for (final (i, t) in tracks.indexed) {
      if (!lyrics) break;
      _setStatus('Looking for lyrics: ${i + 1} of ${tracks.length}');
      try {
        if (await _lookUpLyrics(t) case final text?) {
          await downloadedLyrics(t.path)!.writeAsString(text);
          got.add(t.path);
        }
      } on _Busy {
        // A hiccup: this song is asked about again next time. Several in a row: later.
        if (++failures >= 3) rethrow;
        continue;
      }
      failures = 0;
      _lyricsTried[t.path] = _now();
      if (got.length >= 10) {
        library.addLyrics(got);
        got.clear();
      }
      if (i % 20 == 19) await _save();
    }
    if (got.isNotEmpty) library.addLyrics(got);
  }

  /// The song's lyrics on LRCLIB (synced if it has them), or null. With [search], a song
  /// it doesn't know by exactly these tags is searched for (streamed songs' tags differ
  /// from the ones LRCLIB has more often). Throws [_Busy] when LRCLIB is struggling.
  Future<String?> _lookUpLyrics(Track t, {bool search = false}) async {
    String? lyricsOf(Object? json) => switch (json) {
      {'syncedLyrics': final String s} when s.trim().isNotEmpty => s,
      {'plainLyrics': final String s} when s.trim().isNotEmpty => s,
      _ => null,
    };
    final (status, body) = await _fetch(
      Uri.https('lrclib.net', '/api/get', {
        'artist_name': t.artists.first,
        'track_name': t.title,
        'album_name': ?t.album,
        'duration': '${t.durationSecs.round()}',
      }),
    );
    if (status >= 500 || status == 429) throw _Busy(status);
    if (status == 200) return lyricsOf(jsonDecode(utf8.decode(body)));
    if (!search) return null;
    final (found, results) = await _fetch(
      Uri.https('lrclib.net', '/api/search', {
        'artist_name': t.artists.first,
        'track_name': bareTitle(t.title),
      }),
    );
    if (found >= 500 || found == 429) throw _Busy(found);
    if (found != 200) return null;
    // The same length, give or take a few seconds: the same recording.
    final close = [
      for (final r in (jsonDecode(utf8.decode(results)) as List?) ?? const [])
        if (r case {'duration': final num d}
            when (d - t.durationSecs).abs() <= 3)
          r,
    ];
    final synced = close.where((r) => r['syncedLyrics'] is String).firstOrNull;
    return lyricsOf(synced ?? close.firstOrNull);
  }

  /// The library again, with the new covers, and the queue's copies of its tracks.
  Future<void> _reload() async {
    if (_reloadLibrary case final reload?) return reload();
    await library.load();
    final byPath = {for (final t in library.tracks) t.path: t};
    player.updateTracks((t) => byPath[t.path] ?? t);
  }

  Future<(int, Uint8List)> _fetch(Uri url) async {
    if (_get case final get?) return get(url);
    final request = await _http.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json, image/*');
    final response = await request.close().timeout(const Duration(seconds: 30));
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      bytes.add(chunk);
      if (bytes.length > 20 << 20) throw const HttpException('Too large');
    }
    return (response.statusCode, bytes.takeBytes());
  }

  void _setStatus(String? text) {
    if (text == status) return;
    status = text;
    notifyListeners();
  }

  Future<void> _save() async {
    if (!persist) return;
    try {
      await settings.writeAsString(
        jsonEncode({
          'art': art,
          'lyrics': lyrics,
          'artTried': _artTried,
          'lyricsTried': _lyricsTried,
        }),
      );
    } on Object catch (e) {
      debugPrint('saving fetch settings: $e');
    }
  }

  @override
  void dispose() {
    _soon?.cancel();
    library.removeListener(_libraryChanged);
    player.removeListener(_playerChanged);
    _http.close(force: true);
    super.dispose();
  }
}

/// LRCLIB answered 429 or 5xx.
class _Busy extends HttpException {
  _Busy(int status) : super('LRCLIB answered $status');
}

/// Marks downloaded lyrics as used just now (see [Fetcher.clearUnusedLyrics]).
Future<void> touchLyrics(File file) async {
  try {
    await file.setLastModified(DateTime.now());
  } on Object {
    // Read-only, or gone: it'll just be cleared sooner.
  }
}
