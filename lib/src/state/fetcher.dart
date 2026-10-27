import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../rust/api/library.dart';
import 'library.dart';
import 'player.dart';

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
    _later(const Duration(seconds: 5));
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
      final (status, body) = await _fetch(
        Uri.https('lrclib.net', '/api/get', {
          'artist_name': t.artists.first,
          'track_name': t.title,
          'album_name': ?t.album,
          'duration': '${t.durationSecs.round()}',
        }),
      );
      if (status == 200) {
        final json = jsonDecode(utf8.decode(body)) as Map;
        final text = switch (json) {
          {'syncedLyrics': final String s} when s.trim().isNotEmpty => s,
          {'plainLyrics': final String s} when s.trim().isNotEmpty => s,
          _ => null,
        };
        if (text != null) {
          await downloadedLyrics(t.path)!.writeAsString(text);
          got.add(t.path);
        }
      } else if (status >= 500 || status == 429) {
        // A hiccup: this song is asked about again next time. Several in a row: later.
        if (++failures >= 3) throw HttpException('LRCLIB answered $status');
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
    _http.close(force: true);
    super.dispose();
  }
}
