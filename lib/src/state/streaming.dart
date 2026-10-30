import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../rust/api/library.dart';
import '../rust/api/streaming.dart';
import 'library.dart';
import 'player.dart';
import 'playlists.dart';

export 'library.dart' show isStream;

/// The services Halcyn streams from, by key.
const serviceNames = {'tidal': 'Tidal', 'ytm': 'YouTube Music'};

String serviceOf(String path) => path.startsWith('tidal:')
    ? 'tidal'
    : path.startsWith('ytm:')
    ? 'ytm'
    : 'local';

/// Tidal and YouTube Music: the accounts, finding songs, importing playlists, the Home
/// page, and sending listens back. Streamed songs are tracks like files (their paths are
/// `tidal:<id>` and `ytm:<id>`), remembered in the library so playlists and the queue keep
/// them. A file of the user's own that's as good as the stream plays instead of it.
class StreamingController extends ChangeNotifier {
  StreamingController({
    required this.library,
    required this.player,
    required this.playlists,
    required this.settings,
    this.persist = true,
  });

  final LibraryController library;
  final PlayerController player;
  final PlaylistsController playlists;

  /// `streaming.json`: the switches and the services' order.
  final File settings;
  final bool persist;

  StreamingAccounts? accounts;

  /// The order songs are looked for in when importing from another service.
  List<String> order = const ['tidal', 'ytm'];

  /// Plays a file of the user's own instead of a stream when it's as good.
  bool preferLocal = true;

  /// Adds what's listened to (streamed or not) to the YouTube Music account's history.
  bool shareHistory = true;

  /// The Home page's rows, once loaded.
  List<RemoteShelf>? home;
  bool loadingHome = false;
  String? homeError;

  /// Local tracks by [matchKey], for [preferred].
  Map<String, List<Track>> _local = const {};

  /// Local tracks by ISRC: the same recording, however it's titled.
  Map<String, List<Track>> _localIsrc = const {};

  /// YouTube Music's id for local songs, found when sharing history ('' = not there).
  final _ytmIds = <String, String>{};

  bool get tidal => accounts?.tidal != null;
  bool get youtube => accounts?.youtube != null;
  bool get linked => tidal || youtube;
  List<String> get services => [
    for (final s in order)
      if (s == 'tidal' ? tidal : youtube) s,
  ];

  Future<void> load() async {
    try {
      final json = jsonDecode(await settings.readAsString()) as Map;
      preferLocal = json['preferLocal'] != false;
      shareHistory = json['shareHistory'] != false;
      final saved = (json['order'] as List?)?.cast<String>();
      if (saved != null && saved.toSet().containsAll(['tidal', 'ytm'])) {
        order = saved.where(serviceNames.containsKey).toList();
      }
    } on Object {
      // Nothing saved yet.
    }
    accounts = await streamingAccounts();
    library.addStreams(await streamingTracks());
    library.addListener(_indexLocal);
    _indexLocal();
    player.substitute = preferred;
    notifyListeners();
  }

  /// After signing in or out elsewhere (the Halcyn account brought a sign-in).
  Future<void> refreshAccounts() => _refreshAccounts();

  Future<void> _refreshAccounts() async {
    accounts = await streamingAccounts();
    home = null;
    notifyListeners();
  }

  // ---- accounts ----

  Future<String> tidalLoginUrl() => streamingTidalLoginUrl();

  String get tidalRedirect => streamingTidalRedirect();

  Future<void> tidalFinishLogin(String redirected) async {
    await streamingTidalFinishLogin(redirected: redirected.trim());
    await _refreshAccounts();
  }

  Future<void> tidalSignOut() async {
    await streamingTidalSignOut();
    await _refreshAccounts();
  }

  Future<void> youtubeSignIn(String cookie) async {
    await streamingYoutubeSignIn(cookie: cookie);
    await _refreshAccounts();
  }

  Future<void> youtubeSignInFromBrowser(String browser) async {
    await streamingYoutubeSignInFromBrowser(browser: browser);
    await _refreshAccounts();
  }

  Future<void> youtubeSignOut() async {
    await streamingYoutubeSignOut();
    await _refreshAccounts();
  }

  // ---- settings ----

  void setOrder(List<String> order) {
    this.order = order;
    _changed();
  }

  void setPreferLocal(bool on) {
    preferLocal = on;
    _changed();
  }

  void setShareHistory(bool on) {
    shareHistory = on;
    _changed();
  }

  void _changed() {
    notifyListeners();
    _save();
  }

  Future<void> _save() async {
    if (!persist) return;
    try {
      await settings.writeAsString(
        jsonEncode({
          'order': order,
          'preferLocal': preferLocal,
          'shareHistory': shareHistory,
        }),
      );
    } on Object catch (e) {
      debugPrint('saving streaming settings: $e');
    }
  }

  // ---- finding songs ----

  Future<List<Track>> _remember(List<RemoteTrack> found) async {
    if (found.isEmpty) return const [];
    final tracks = await streamingRemember(tracks: found);
    library.addStreams(tracks);
    return tracks;
  }

  Future<List<Track>> search(String service, String query) async =>
      _remember(await streamingSearch(serviceName: service, query: query));

  Future<List<RemotePlaylist>> playlistsOf(String service) =>
      streamingPlaylists(serviceName: service);

  Future<List<Track>> tracksOf(RemotePlaylist list) async => _remember(
    await streamingPlaylistTracks(serviceName: list.service, id: list.id),
  );

  Future<List<Track>> radio(Track track) async =>
      _remember(await streamingRadio(path: track.path));

  /// [track] got its length while playing: remembered, so lists show it too.
  Future<void> rememberLength(Track track) async {
    if (!isStream(track.path)) return;
    try {
      await _remember([
        RemoteTrack(
          path: track.path,
          title: track.title,
          artists: track.artists,
          album: track.album,
          durationSecs: track.durationSecs,
          quality: track.codec,
          isrc: track.isrc,
        ),
      ]);
    } on Object catch (e) {
      debugPrint('remembering a length: $e');
    }
  }

  Future<void> like(Track track, bool on) =>
      streamingLike(path: track.path, liked: on);

  /// The rows of every linked service's home page, mixed: one of each in turn.
  Future<void> loadHome({bool again = false}) async {
    if (loadingHome || (home != null && !again)) return;
    loadingHome = true;
    homeError = null;
    // Pages ask for it while they build: tell them after.
    scheduleMicrotask(notifyListeners);
    try {
      final rows = await Future.wait([
        for (final s in services)
          streamingHome(serviceName: s).catchError((Object e) {
            homeError = '${serviceNames[s]}: ${_reason(e)}';
            return <RemoteShelf>[];
          }),
      ]);
      final mixed = <RemoteShelf>[];
      for (var i = 0; rows.any((r) => i < r.length); i++) {
        for (final r in rows) {
          if (i < r.length) mixed.add(r[i]);
        }
      }
      // Their covers, ready for the rows.
      await _remember([for (final s in mixed) ...s.tracks]);
      home = mixed;
    } on Object catch (e) {
      // Not again on every rebuild: the page offers pulling down to try again.
      homeError ??= _reason(e);
      home ??= const [];
    } finally {
      loadingHome = false;
      notifyListeners();
    }
  }

  // ---- importing ----

  /// Copies a service's playlist into Halcyn. Each song comes from the first service in
  /// [order] that has it (the playlist's own, failing that). `progress(done, total)`.
  Future<Playlist> import(
    RemotePlaylist list, {
    void Function(int done, int total)? progress,
  }) async {
    final tracks = await tracksOf(list);
    final first = order.firstWhere(
      (s) => s == list.service || services.contains(s),
      orElse: () => list.service,
    );
    final chosen = <Track>[];
    for (final (i, t) in tracks.indexed) {
      progress?.call(i, tracks.length);
      var pick = t;
      // A better copy on the service that comes first (Tidal's FLAC for a YouTube song).
      if (first != list.service && _rank(t) < 3) {
        pick = await _find(t, first) ?? t;
      }
      chosen.add(pick);
    }
    progress?.call(tracks.length, tracks.length);
    return playlists.create(list.name, [for (final t in chosen) t.path]);
  }

  /// The best copy of a streamed song on the linked services: Tidal's FLAC for a
  /// YouTube Music song when Tidal has the same recording, else the song itself.
  Future<Track> best(Track track) async {
    if (_rank(track) >= 3) return track;
    for (final service in services) {
      if (service == serviceOf(track.path)) continue;
      final found = await _find(track, service);
      if (found != null && _rank(found) > _rank(track)) return found;
    }
    return track;
  }

  /// A file of the user's own that's as good as [track], whatever [preferLocal] says.
  Track? localCopy(Track track) {
    for (final local in _localCandidates(track)) {
      if (_rank(local) >= _rank(track)) return local;
    }
    return null;
  }

  /// Files of the user's own that are [track]'s recording: the ones with its ISRC, then
  /// the ones with its title, lead artist and length.
  Iterable<Track> _localCandidates(Track track) sync* {
    final isrc = track.isrc;
    final seen = <String>{};
    if (isrc != null) {
      for (final local in _localIsrc[isrc] ?? const <Track>[]) {
        if (seen.add(local.path)) yield local;
      }
    }
    for (final local in _local[matchKey(track.title, track.artists)] ?? const <Track>[]) {
      if (track.durationSecs > 0 &&
          (local.durationSecs - track.durationSecs).abs() > 4) {
        continue;
      }
      if (seen.add(local.path)) yield local;
    }
  }

  /// The same song on `service`, if it's there and at least as good.
  Future<Track?> _find(Track t, String service) async {
    final isrc = t.isrc;
    if (isrc != null) {
      final found = await _findByIsrc(t, isrc, service);
      if (found != null) return found;
    }
    final lead = t.artists.firstOrNull ?? '';
    final List<RemoteTrack> found;
    try {
      found = await streamingSearch(
        serviceName: service,
        query: '$lead ${bareTitle(t.title)}',
      );
    } on Object {
      return null;
    }
    RemoteTrack? best;
    var bestScore = 0.0;
    for (final c in found) {
      // The same ISRC is the same recording, whatever the titles say.
      final score = isrc != null && c.isrc == isrc ? 2.0 : sameSong(
        t.title,
        t.artists,
        t.durationSecs,
        c.title,
        c.artists,
        c.durationSecs,
      );
      if (score > bestScore) {
        best = c;
        bestScore = score;
      }
    }
    if (best == null) return null;
    final [track] = await _remember([best]);
    return _rank(track) >= _rank(t) ? track : null;
  }

  /// The recording with this ISRC on `service`: Tidal's best copy (on [t]'s album, when
  /// it's on several), or the song YouTube Music finds for it, if it's plausibly [t].
  Future<Track?> _findByIsrc(Track t, String isrc, String service) async {
    final List<RemoteTrack> found;
    try {
      found = await streamingByIsrc(serviceName: service, isrc: isrc);
    } on Object {
      return null;
    }
    final album = _norm(t.album ?? '');
    final candidates = [
      for (final c in found)
        if (c.isrc == isrc || (service == 'ytm' && looselySameSong(t, c))) c,
    ];
    if (candidates.isEmpty) return null;
    int score(RemoteTrack c) =>
        _rank(_quality(c)) * 2 +
        (album.isNotEmpty && _norm(c.album ?? '') == album ? 1 : 0);
    candidates.sort((a, b) => score(b) - score(a));
    final [track] = await _remember([candidates.first]);
    return _rank(track) >= _rank(t) ? track : null;
  }

  /// How a service's song ranks, before it's remembered as a track.
  static Track _quality(RemoteTrack c) => Track(
    id: 0,
    path: c.path,
    title: c.title,
    artists: c.artists,
    durationSecs: c.durationSecs,
    sampleRate: 0,
    channels: 2,
    codec: c.quality ?? '',
    added: 0,
    plays: 0,
  );

  // ---- playing ----

  @visibleForTesting
  void debugIndexLocal() => _indexLocal();

  void _indexLocal() {
    final index = <String, List<Track>>{};
    final byIsrc = <String, List<Track>>{};
    for (final t in library.tracks) {
      index.putIfAbsent(matchKey(t.title, t.artists), () => []).add(t);
      if (t.isrc case final isrc?) byIsrc.putIfAbsent(isrc, () => []).add(t);
    }
    _local = index;
    _localIsrc = byIsrc;
  }

  /// What plays for `track`: a file of the user's own that's as good as the stream, when
  /// [preferLocal] is on; else the track.
  Track preferred(Track track) {
    if (!preferLocal || !isStream(track.path)) return track;
    Track? best;
    for (final local in _localCandidates(track)) {
      if (_rank(local) < _rank(track)) continue;
      if (best == null || _rank(local) > _rank(best)) best = local;
    }
    return best ?? track;
  }

  /// 3 hi-res, 2 lossless, 1 lossy.
  static int _rank(Track t) {
    if (isStream(t.path)) {
      return switch (t.codec) {
        'Hi-res' => 3,
        'Lossless' => 2,
        _ => 1,
      };
    }
    final lossless = const {
      'flac',
      'alac',
      'wavpack',
      'pcm',
    }.any((c) => t.codec.toLowerCase().startsWith(c));
    if (!lossless) return 1;
    return (t.bits ?? 16) > 16 || t.sampleRate > 48000 ? 3 : 2;
  }

  /// A song was listened to: tell YouTube Music, when sharing history. A local song is
  /// looked for there first (once).
  Future<void> listened(Track track) async {
    if (!shareHistory || !youtube) return;
    try {
      switch (serviceOf(track.path)) {
        case 'ytm':
          await streamingRecordListen(path: track.path);
        case 'local':
          final id = _ytmIds[track.path] ??=
              (await _find(track, 'ytm'))?.path ?? '';
          if (id.isNotEmpty) await streamingRecordListen(path: id);
      }
    } on Object catch (e) {
      debugPrint('sharing a listen: $e');
    }
  }

  @override
  void dispose() {
    library.removeListener(_indexLocal);
    super.dispose();
  }
}

String _reason(Object e) {
  final text = e.toString();
  return text.startsWith('AnyhowException(')
      ? text.substring(16, text.length - 1)
      : text;
}

/// What an error from a service says, for showing.
String streamingError(Object e) => _reason(e);

/// The title without what versions add: "(feat. …)", "[Remastered]", " - 2011 Remaster".
String bareTitle(String title) => title
    .replaceAll(RegExp(r'\s*[(\[][^)\]]*[)\]]'), '')
    .replaceAll(RegExp(r'\s+-\s+.*$'), '')
    .trim();

String _norm(String s) => s
    .toLowerCase()
    .replaceAll('&', 'and')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

/// Two songs that share this are probably the same recording.
String matchKey(String title, List<String> artists) =>
    '${_norm(bareTitle(title))}\u0000${_norm(artists.firstOrNull ?? '')}';

/// Words that make a different recording: two songs must agree on each.
const _versionWords = [
  'live',
  'remix',
  'acoustic',
  'instrumental',
  'karaoke',
  'sped up',
  'slowed',
  'nightcore',
  'demo',
  'unplugged',
  'radio edit',
  'extended',
];

/// Whether YouTube Music's answer to an ISRC search is plausibly [t] (it has no ISRCs to
/// compare): about as long, and sharing the title or the lead artist.
bool looselySameSong(Track t, RemoteTrack c) {
  if (t.durationSecs > 0 &&
      c.durationSecs > 0 &&
      (t.durationSecs - c.durationSecs).abs() > 10) {
    return false;
  }
  final title = _norm(bareTitle(t.title));
  final theirs = _norm(bareTitle(c.title));
  final sameTitle =
      title.isNotEmpty &&
      theirs.isNotEmpty &&
      (theirs.contains(title) || title.contains(theirs));
  final lead = _norm(t.artists.firstOrNull ?? '');
  final sameArtist =
      lead.isNotEmpty && c.artists.any((a) => _norm(a) == lead);
  return sameTitle || sameArtist;
}

/// How sure it is that two songs are the same recording, 0 (they aren't) to about 1.
double sameSong(
  String title,
  List<String> artists,
  double duration,
  String otherTitle,
  List<String> otherArtists,
  double otherDuration,
) {
  if (duration > 0 &&
      otherDuration > 0 &&
      (duration - otherDuration).abs() > 6) {
    return 0;
  }
  bool has(String text, String word) =>
      RegExp('\\b$word\\b').hasMatch(text.toLowerCase());
  for (final w in _versionWords) {
    if (has(title, w) != has(otherTitle, w)) return 0;
  }
  if (_norm(bareTitle(title)) != _norm(bareTitle(otherTitle))) return 0;
  final lead = _norm(artists.firstOrNull ?? '');
  final theirs = {for (final a in otherArtists) _norm(a)};
  if (lead.isNotEmpty && !theirs.any((a) => a == lead || a.contains(lead))) {
    return 0;
  }
  final closeness = duration > 0 && otherDuration > 0
      ? 1 - (duration - otherDuration).abs() / 6
      : 0.5;
  return 0.7 + 0.3 * closeness;
}
