import 'package:flutter/material.dart';

import '../state/library.dart';
import '../state/sort.dart';
import '../theme.dart';
import 'albums_page.dart';
import 'lookup.dart';
import 'slate.dart';
import 'widgets.dart';

class ArtistsPage extends StatelessWidget {
  const ArtistsPage({super.key, required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final library = scope.library;
    final sort = scope.sort;
    return ListenableBuilder(
      listenable: Listenable.merge([library, sort]),
      builder: (context, _) {
        final q = query.toLowerCase();
        final artists = sort.artists.apply(
          library.artists
              .where((a) => q.isEmpty || a.name.toLowerCase().contains(q))
              .toList(),
          descending: sort.artistsDescending,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerRight,
                child: SortPill(
                  keys: ArtistSortKey.values,
                  label: (k) => k.label,
                  current: sort.artists,
                  descending: sort.artistsDescending,
                  onSelected: sort.sortArtists,
                ),
              ),
            ),
            Expanded(
              child: artists.isEmpty
                  ? const EmptyState(
                      icon: Icons.person_outline_rounded,
                      message: 'No artists.',
                    )
                  : ListView.builder(
                      padding: EdgeInsets.fromLTRB(
                        12,
                        0,
                        12,
                        24 + dockInset(context),
                      ),
                      itemExtent: 64,
                      itemCount: artists.length,
                      itemBuilder: (context, i) =>
                          ArtistTile(artist: artists[i]),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class ArtistTile extends StatelessWidget {
  const ArtistTile({super.key, required this.artist});

  final Artist artist;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = artist.tracks.length;
    return InkWell(
      borderRadius: BorderRadius.circular(Palette.r(8)),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => ArtistPage(artist: artist))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Artwork(art: artist.art, size: 44, radius: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              '$count ${count == 1 ? 'song' : 'songs'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Palette.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ArtistPage extends StatelessWidget {
  const ArtistPage({super.key, required this.artist});

  final Artist artist;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = AppScope.of(context).player;
    final tracks = artist.tracks;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 24, 8),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back_rounded),
                      tooltip: 'Back',
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        artist.name,
                        style: theme.textTheme.displaySmall,
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: () => player.playTracks(tracks, 0),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Play'),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: FindOnServices(artist: artist.name),
              ),
            ),
            if (artist.albums.isNotEmpty) ...[
              _section(context, 'Albums'),
              SliverToBoxAdapter(
                child: AlbumGrid(albums: artist.albums, shrinkWrap: true),
              ),
            ],
            _section(context, 'Songs'),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 32 + dockInset(context)),
              sliver: SliverFixedExtentList.builder(
                itemExtent: TrackTile.height,
                itemCount: tracks.length,
                itemBuilder: (context, i) => TrackTile(
                  track: tracks[i],
                  onTap: () => player.playTracks(tracks, i),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Text(title, style: Theme.of(context).textTheme.titleLarge),
    ),
  );
}
