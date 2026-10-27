import 'dart:io';

import 'package:flutter/foundation.dart';

import '../rust/api/library.dart';

class Album {
  Album(this.title, this.artist);

  final String title;
  final String artist;
  final List<Track> tracks = [];

  int? get year => tracks.map((t) => t.year).nonNulls.firstOrNull;
  String? get art => tracks.map((t) => t.art).nonNulls.firstOrNull;
  double get durationSecs => tracks.fold(0, (sum, t) => sum + t.durationSecs);
}

class Artist {
  Artist(this.name);

  final String name;
  final List<Track> tracks = [];
  final List<Album> albums = [];

  String? get art => albums.map((a) => a.art).nonNulls.firstOrNull;
}

/// The indexed music, grouped for browsing.
class LibraryController extends ChangeNotifier {
  List<Track> tracks = const [];
  List<Album> albums = const [];
  List<Artist> artists = const [];
  List<String> folders = const [];

  /// Paths of the tracks with a `.lrc` file beside them.
  Set<String> withLyrics = const {};

  /// Set while a scan runs.
  ScanProgress? scanning;
  String? error;

  /// Listens counted since the tracks were loaded; Track.plays holds the rest.
  final Map<String, int> _newPlays = {};
  final Map<String, int> _lastPlayed = {};

  Future<void> load() async {
    tracks = await libraryTracks();
    folders = await libraryFolders();
    _newPlays.clear();
    _lastPlayed.clear();
    _group();
    notifyListeners();
    _findLyrics();
  }

  Future<void> _findLyrics() async {
    final found = await Future.wait([
      for (final t in tracks)
        File(lyricsPath(t.path)).exists().then((has) => has ? t.path : null),
    ]);
    withLyrics = found.nonNulls.toSet();
    notifyListeners();
  }

  int plays(Track track) => track.plays + (_newPlays[track.path] ?? 0);

  /// When `track` was last listened to, in Unix seconds, counting this session.
  int? lastPlayed(Track track) =>
      _lastPlayed[track.path] ?? track.lastPlayed?.toInt();

  void recordPlay(Track track) {
    _newPlays.update(track.path, (n) => n + 1, ifAbsent: () => 1);
    _lastPlayed[track.path] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    libraryRecordPlay(path: track.path);
    notifyListeners();
  }

  /// Smart playlists: computed from the library, never edited by hand.
  List<Track> get hiRes => [
    for (final t in tracks)
      if ((t.bits ?? 0) > 16 || t.sampleRate > 48000) t,
  ]..sort((a, b) => b.sampleRate.compareTo(a.sampleRate));

  List<Track> get recentlyAdded => ([
    ...tracks,
  ]..sort((a, b) => b.added.compareTo(a.added))).take(50).toList();

  List<Track> get recentlyPlayed =>
      ([
            for (final t in tracks)
              if (lastPlayed(t) != null) t,
          ]..sort((a, b) => lastPlayed(b)!.compareTo(lastPlayed(a)!)))
          .take(50)
          .toList();

  List<Track> get neverPlayed => [
    for (final t in tracks)
      if (plays(t) == 0) t,
  ]..sort((a, b) => b.added.compareTo(a.added));

  /// Played at least 3 times, but not in the last 30 days.
  List<Track> get forgotten {
    final monthAgo =
        DateTime.now().millisecondsSinceEpoch ~/ 1000 - 30 * 24 * 3600;
    return [
      for (final t in tracks)
        if (plays(t) >= 3 && (lastPlayed(t) ?? 0) < monthAgo) t,
    ]..sort((a, b) => plays(b).compareTo(plays(a)));
  }

  List<Track> get mostPlayed => ([
    for (final t in tracks)
      if (plays(t) > 0) t,
  ]..sort((a, b) => plays(b).compareTo(plays(a)))).take(50).toList();

  Future<void> rescan() async {
    if (scanning != null) return;
    scanning = const ScanProgress(done: 0, total: 0);
    error = null;
    notifyListeners();
    try {
      await for (final progress in libraryScan()) {
        scanning = progress;
        notifyListeners();
      }
      await load();
    } catch (e) {
      error = '$e';
    } finally {
      scanning = null;
      notifyListeners();
    }
  }

  Future<void> setFolders(List<String> folders) async {
    await librarySetFolders(folders: folders);
    this.folders = folders;
    notifyListeners();
    await rescan();
  }

  Track? byPath(String path) => tracks.where((t) => t.path == path).firstOrNull;

  void _group() {
    final albums = <String, Album>{};
    final artists = <String, Artist>{};
    for (final track in tracks) {
      final albumArtist =
          track.albumArtist ?? track.artists.firstOrNull ?? 'Unknown artist';
      final title = track.album ?? track.title;
      final album = albums.putIfAbsent(
        '${albumArtist.toLowerCase()}\u0000${title.toLowerCase()}',
        () => Album(title, albumArtist),
      );
      album.tracks.add(track);
      for (final name
          in track.artists.isEmpty ? [albumArtist] : track.artists) {
        artists
            .putIfAbsent(name.toLowerCase(), () => Artist(name))
            .tracks
            .add(track);
      }
    }

    for (final album in albums.values) {
      album.tracks.sort(
        (a, b) => ((a.discNo ?? 1) * 1000 + (a.trackNo ?? 0)).compareTo(
          (b.discNo ?? 1) * 1000 + (b.trackNo ?? 0),
        ),
      );
      artists[album.artist.toLowerCase()]?.albums.add(album);
    }

    int byName(String a, String b) =>
        a.toLowerCase().compareTo(b.toLowerCase());
    this.albums = albums.values.toList()
      ..sort((a, b) => byName(a.title, b.title));
    this.artists = artists.values.toList()
      ..sort((a, b) => byName(a.name, b.name));
    for (final artist in this.artists) {
      artist.albums.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
    }
  }
}

/// Where a track's synced lyrics live: beside it, as `.lrc`.
String lyricsPath(String trackPath) {
  final dot = trackPath.lastIndexOf('.');
  final slash = trackPath.lastIndexOf('/');
  return '${dot > slash ? trackPath.substring(0, dot) : trackPath}.lrc';
}

/// Case-insensitive match on title, artists and album.
bool matches(Track track, String query) {
  if (query.isEmpty) return true;
  final q = query.toLowerCase();
  return track.title.toLowerCase().contains(q) ||
      track.artists.any((a) => a.toLowerCase().contains(q)) ||
      (track.album?.toLowerCase().contains(q) ?? false);
}
