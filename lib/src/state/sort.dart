import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../rust/api/library.dart';
import 'library.dart';

/// What a track list can be sorted by. Text sorts start A→Z; the rest start with the
/// biggest (newest, longest, most played, best quality) first.
enum TrackSortKey {
  title('Title'),
  artist('Artist'),
  album('Album'),
  added('Date added', descending: true),
  duration('Length', descending: true),
  plays('Plays', descending: true),
  quality('Quality', descending: true),
  year('Year', descending: true);

  const TrackSortKey(this.label, {this.descending = false});

  final String label;

  /// The direction a first click picks.
  final bool descending;
}

/// A track list's order: `key`, or the list's own (a playlist's, a smart list's rule)
/// when null.
@immutable
class TrackSort {
  const TrackSort([this.key, this.descending = false]);

  final TrackSortKey? key;
  final bool descending;

  /// Sorting by `key`: flips the direction if already sorted by it.
  TrackSort by(TrackSortKey key) => this.key == key
      ? TrackSort(key, !descending)
      : TrackSort(key, key.descending);

  /// `tracks` in this order. `plays` counts include this session's.
  List<Track> apply(List<Track> tracks, int Function(Track) plays) =>
      applyTo(tracks, (t) => t, plays);

  /// `items` in this order, each sorted by its track.
  List<T> applyTo<T>(
    List<T> items,
    Track Function(T) trackOf,
    int Function(Track) plays,
  ) {
    final key = this.key;
    if (key == null) return descending ? items.reversed.toList() : items;
    int compare(Track a, Track b) => switch (key) {
      TrackSortKey.title => _text(a.title, b.title),
      TrackSortKey.artist => _then(
        _text(a.artists.firstOrNull ?? '', b.artists.firstOrNull ?? ''),
        () => _inAlbum(a, b),
      ),
      TrackSortKey.album => _inAlbum(a, b),
      TrackSortKey.added => a.added.compareTo(b.added),
      TrackSortKey.duration => a.durationSecs.compareTo(b.durationSecs),
      TrackSortKey.plays => plays(a).compareTo(plays(b)),
      TrackSortKey.quality => _then(
        (a.bits ?? 16).compareTo(b.bits ?? 16),
        () => a.sampleRate.compareTo(b.sampleRate),
      ),
      TrackSortKey.year => _then(
        (a.year ?? 0).compareTo(b.year ?? 0),
        () => _inAlbum(a, b),
      ),
    };
    // Ties keep the list's own order, so sorting stays stable either way.
    final indexed = [...items.indexed];
    indexed.sort((x, y) {
      final c = compare(trackOf(x.$2), trackOf(y.$2));
      return c != 0 ? (descending ? -c : c) : x.$1.compareTo(y.$1);
    });
    return [for (final (_, t) in indexed) t];
  }

  Map<String, Object?> toJson() => {'key': key?.name, 'desc': descending};

  static TrackSort fromJson(Object? json) => json is Map
      ? TrackSort(
          TrackSortKey.values.asNameMap()[json['key']],
          json['desc'] == true,
        )
      : const TrackSort();

  @override
  bool operator ==(Object other) =>
      other is TrackSort && other.key == key && other.descending == descending;

  @override
  int get hashCode => Object.hash(key, descending);
}

enum AlbumSortKey {
  title('Name'),
  artist('Artist'),
  year('Year', descending: true),
  added('Date added', descending: true);

  const AlbumSortKey(this.label, {this.descending = false});

  final String label;
  final bool descending;

  List<Album> apply(List<Album> albums, {required bool descending}) {
    int newest(Album a) =>
        a.tracks.fold(0, (n, t) => t.added.toInt() > n ? t.added.toInt() : n);
    int compare(Album a, Album b) => switch (this) {
      AlbumSortKey.title => _text(a.title, b.title),
      AlbumSortKey.artist => _then(
        _text(a.artist, b.artist),
        () => (a.year ?? 0).compareTo(b.year ?? 0),
      ),
      AlbumSortKey.year => (a.year ?? 0).compareTo(b.year ?? 0),
      AlbumSortKey.added => newest(a).compareTo(newest(b)),
    };
    final indexed = [...albums.indexed];
    indexed.sort((x, y) {
      final c = compare(x.$2, y.$2);
      return c != 0 ? (descending ? -c : c) : x.$1.compareTo(y.$1);
    });
    return [for (final (_, a) in indexed) a];
  }
}

enum ArtistSortKey {
  name('Name'),
  songs('Songs', descending: true);

  const ArtistSortKey(this.label, {this.descending = false});

  final String label;
  final bool descending;

  List<Artist> apply(List<Artist> artists, {required bool descending}) {
    int compare(Artist a, Artist b) => switch (this) {
      ArtistSortKey.name => _text(a.name, b.name),
      ArtistSortKey.songs => a.tracks.length.compareTo(b.tracks.length),
    };
    final indexed = [...artists.indexed];
    indexed.sort((x, y) {
      final c = compare(x.$2, y.$2);
      return c != 0 ? (descending ? -c : c) : x.$1.compareTo(y.$1);
    });
    return [for (final (_, a) in indexed) a];
  }
}

int _text(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

int _then(int first, int Function() next) => first != 0 ? first : next();

/// Album, then disc and track number.
int _inAlbum(Track a, Track b) => _then(
  _text(a.album ?? '', b.album ?? ''),
  () => ((a.discNo ?? 1) * 1000 + (a.trackNo ?? 0)).compareTo(
    (b.discNo ?? 1) * 1000 + (b.trackNo ?? 0),
  ),
);

/// How each list is sorted, remembered in `<app support>/sort.json`. Lists are named
/// `songs`, a smart list's place, or `playlist:<id>`.
class SortPrefs extends ChangeNotifier {
  SortPrefs(this._file, {this.persist = true});

  final File _file;

  /// False while testing, so the real choices are read but never overwritten.
  final bool persist;
  Timer? _saveTimer;

  final Map<String, TrackSort> _tracks = {};
  AlbumSortKey albums = AlbumSortKey.title;
  bool albumsDescending = false;
  ArtistSortKey artists = ArtistSortKey.name;
  bool artistsDescending = false;

  /// The songs list sorts by title until changed; the others keep their own order.
  TrackSort tracks(String list) =>
      _tracks[list] ??
      (list == 'songs'
          ? const TrackSort(TrackSortKey.title)
          : const TrackSort());

  void setTracks(String list, TrackSort sort) {
    _tracks[list] = sort;
    _changed();
  }

  void sortAlbums(AlbumSortKey key) {
    albumsDescending = albums == key ? !albumsDescending : key.descending;
    albums = key;
    _changed();
  }

  void sortArtists(ArtistSortKey key) {
    artistsDescending = artists == key ? !artistsDescending : key.descending;
    artists = key;
    _changed();
  }

  Future<void> load() async {
    try {
      final saved = jsonDecode(await _file.readAsString()) as Map;
      for (final MapEntry(:key, :value) in (saved['tracks'] as Map).entries) {
        _tracks[key as String] = TrackSort.fromJson(value);
      }
      albums =
          AlbumSortKey.values.asNameMap()[saved['albums']] ??
          AlbumSortKey.title;
      albumsDescending = saved['albumsDesc'] == true;
      artists =
          ArtistSortKey.values.asNameMap()[saved['artists']] ??
          ArtistSortKey.name;
      artistsDescending = saved['artistsDesc'] == true;
    } on Object {
      // Nothing saved yet.
    }
    notifyListeners();
  }

  void _changed() {
    notifyListeners();
    if (!persist) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () async {
      try {
        await _file.writeAsString(
          jsonEncode({
            'tracks': {
              for (final MapEntry(:key, :value) in _tracks.entries)
                key: value.toJson(),
            },
            'albums': albums.name,
            'albumsDesc': albumsDescending,
            'artists': artists.name,
            'artistsDesc': artistsDescending,
          }),
        );
      } on Object catch (e) {
        debugPrint('saving sort order: $e');
      }
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}
