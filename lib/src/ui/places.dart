import 'package:flutter/material.dart';

import '../rust/api/library.dart';
import '../state/library.dart';

/// Everything the sidebar can show.
enum Place {
  /// What the linked streaming services suggest.
  home,
  songs,
  albums,
  artists,
  queue,
  hiRes,
  recent,
  recentlyPlayed,
  mostPlayed,
  forgotten,
  neverPlayed,
  playlist,

  /// The phone layout's list of playlists; the sidebar shows them itself.
  playlists,

  /// Everything matching the sidebar's search.
  search,
  settings,

  /// Installing and managing plugins.
  plugins,

  /// A page a plugin added; the section's id is its [PluginPage.key].
  pluginPage;

  bool get smart => SmartList.all.any((s) => s.place == this);
}

@immutable
class Section {
  const Section(this.place, [this.playlist]);

  final Place place;

  /// The user playlist's id for Place.playlist; the page's key for Place.pluginPage.
  final int? playlist;

  @override
  bool operator ==(Object other) =>
      other is Section && other.place == place && other.playlist == playlist;

  @override
  int get hashCode => Object.hash(place, playlist);
}

/// A smart playlist: its name, icon, one-line rule, and tracks.
class SmartList {
  const SmartList(
    this.place,
    this.name,
    this.icon,
    this.rule,
    this.order,
    this.tracks,
  );

  final Place place;
  final String name;
  final IconData icon;
  final String rule;

  /// Its own order, as the sort menu names it.
  final String order;
  final List<Track> Function(LibraryController library) tracks;

  static final all = [
    SmartList(
      Place.hiRes,
      'Hi-Res picks',
      Icons.graphic_eq_rounded,
      'Over 16-bit or 48 kHz, highest rate first',
      'Highest rate first',
      (l) => l.hiRes,
    ),
    SmartList(
      Place.recent,
      'Recently added',
      Icons.schedule_rounded,
      'The 50 newest files',
      'Newest first',
      (l) => l.recentlyAdded,
    ),
    SmartList(
      Place.recentlyPlayed,
      'Recently played',
      Icons.history_rounded,
      'The last 50 songs you heard',
      'Last played first',
      (l) => l.recentlyPlayed,
    ),
    SmartList(
      Place.mostPlayed,
      'Most played',
      Icons.trending_up_rounded,
      'Counted once you\'ve heard half a song',
      'Most played first',
      (l) => l.mostPlayed,
    ),
    SmartList(
      Place.forgotten,
      'Old favourites',
      Icons.replay_rounded,
      'Played 3+ times, but not in the last month',
      'Most played first',
      (l) => l.forgotten,
    ),
    SmartList(
      Place.neverPlayed,
      'Never played',
      Icons.fiber_new_outlined,
      'Songs you haven\'t heard yet, newest first',
      'Newest first',
      (l) => l.neverPlayed,
    ),
  ];

  static SmartList of(Place place) => all.firstWhere((s) => s.place == place);
}
