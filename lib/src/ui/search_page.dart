import 'package:flutter/material.dart';

import '../state/library.dart';
import 'albums_page.dart';
import 'artists_page.dart';
import 'places.dart';
import 'slate.dart';
import 'track_list.dart';
import 'widgets.dart';

/// Everything that matches the sidebar's search: songs, albums, artists and playlists.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.query, required this.onOpen});

  final String query;

  /// Opens a playlist.
  final ValueChanged<Section> onOpen;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  /// Songs shown before "Show all".
  static const _few = 8;
  bool _allSongs = false;

  @override
  void didUpdateWidget(SearchPage old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _allSongs = false;
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.library, scope.playlists]),
      builder: (context, _) {
        final q = widget.query.toLowerCase();
        if (q.isEmpty) {
          return const EmptyState(
            icon: Icons.search_rounded,
            message: 'Search your songs, albums, artists and playlists.',
          );
        }
        final library = scope.library;
        final songs = [
          for (final t in library.tracks)
            if (matches(t, q)) t,
        ];
        final albums = [
          for (final a in library.albums)
            if (a.title.toLowerCase().contains(q) ||
                a.artist.toLowerCase().contains(q))
              a,
        ];
        final artists = [
          for (final a in library.artists)
            if (a.name.toLowerCase().contains(q)) a,
        ];
        final playlists = [
          for (final p in scope.playlists.playlists)
            if (p.name.toLowerCase().contains(q)) p,
        ];
        if (songs.isEmpty &&
            albums.isEmpty &&
            artists.isEmpty &&
            playlists.isEmpty) {
          return EmptyState(
            icon: Icons.search_off_rounded,
            message: 'Nothing matches "${widget.query}".',
          );
        }
        final shown = _allSongs ? songs : songs.take(_few).toList();
        return LayoutBuilder(
          builder: (context, box) {
            final columns = TrackColumns.of(box.maxWidth);
            return CustomScrollView(
              slivers: [
                if (songs.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: SectionLabel(
                      'Songs · ${songs.length}',
                      trailing: songs.length > _few
                          ? TextButton(
                              onPressed: () =>
                                  setState(() => _allSongs = !_allSongs),
                              child: Text(_allSongs ? 'Fewer' : 'Show all'),
                            )
                          : null,
                    ),
                  ),
                  SliverFixedExtentList.builder(
                    itemExtent: TrackRow.height,
                    itemCount: shown.length,
                    itemBuilder: (context, i) => TrackRow(
                      track: shown[i],
                      number: i + 1,
                      columns: columns,
                      onTap: () => scope.player.playTracks(songs, i),
                    ),
                  ),
                ],
                if (albums.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: SectionLabel('Albums · ${albums.length}'),
                  ),
                  SliverToBoxAdapter(
                    child: AlbumGrid(albums: albums, shrinkWrap: true),
                  ),
                ],
                if (artists.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: SectionLabel('Artists · ${artists.length}'),
                  ),
                  SliverFixedExtentList.builder(
                    itemExtent: 64,
                    itemCount: artists.length,
                    itemBuilder: (context, i) => ArtistTile(artist: artists[i]),
                  ),
                ],
                if (playlists.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: SectionLabel('Playlists · ${playlists.length}'),
                  ),
                  SliverList.builder(
                    itemCount: playlists.length,
                    itemBuilder: (context, i) => SideItem(
                      label: playlists[i].name,
                      icon: Icons.playlist_play_rounded,
                      count: playlists[i].paths.length,
                      selected: false,
                      onTap: () => widget.onOpen(
                        Section(Place.playlist, playlists[i].id),
                      ),
                    ),
                  ),
                ],
                SliverPadding(
                  padding: EdgeInsets.only(bottom: 24 + dockInset(context)),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
