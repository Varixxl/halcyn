import 'package:flutter/material.dart';

import '../state/library.dart';
import '../state/sort.dart';
import '../theme.dart';
import 'lookup.dart';
import 'slate.dart';
import 'widgets.dart';

class AlbumsPage extends StatelessWidget {
  const AlbumsPage({super.key, required this.query});

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
        final albums = sort.albums.apply(
          library.albums
              .where(
                (a) =>
                    q.isEmpty ||
                    a.title.toLowerCase().contains(q) ||
                    a.artist.toLowerCase().contains(q),
              )
              .toList(),
          descending: sort.albumsDescending,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerRight,
                child: SortPill(
                  keys: AlbumSortKey.values,
                  label: (k) => k.label,
                  current: sort.albums,
                  descending: sort.albumsDescending,
                  onSelected: sort.sortAlbums,
                ),
              ),
            ),
            Expanded(
              child: albums.isEmpty
                  ? const EmptyState(
                      icon: Icons.album_outlined,
                      message: 'No albums.',
                    )
                  : AlbumGrid(albums: albums),
            ),
          ],
        );
      },
    );
  }
}

class AlbumGrid extends StatelessWidget {
  const AlbumGrid({super.key, required this.albums, this.shrinkWrap = false});

  final List<Album> albums;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: EdgeInsets.fromLTRB(
        24,
        4,
        24,
        shrinkWrap ? 24 : 24 + dockInset(context),
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        mainAxisSpacing: 20,
        crossAxisSpacing: 20,
        childAspectRatio: 0.76,
      ),
      itemCount: albums.length,
      itemBuilder: (context, i) => AlbumTile(album: albums[i]),
    );
  }
}

class AlbumTile extends StatefulWidget {
  const AlbumTile({super.key, required this.album});

  final Album album;

  @override
  State<AlbumTile> createState() => _AlbumTileState();
}

class _AlbumTileState extends State<AlbumTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final album = widget.album;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => AlbumPage(album: album))),
        child: LayoutBuilder(
          builder: (context, box) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedScale(
                scale: _hover ? 1.03 : 1,
                duration: Motion.medium,
                curve: Motion.curve,
                child: AnimatedContainer(
                  duration: Motion.medium,
                  curve: Motion.curve,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Palette.r(10)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: _hover ? 0.45 : 0.25,
                        ),
                        blurRadius: _hover ? 18 : 8,
                        offset: const Offset(0, 6),
                      ),
                      // A lapis glow under the cover on hover.
                      BoxShadow(
                        color: Palette.accent.withValues(
                          alpha: _hover ? 0.28 : 0,
                        ),
                        blurRadius: 28,
                        spreadRadius: -6,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Hero(
                    tag: 'album-${album.artist}-${album.title}',
                    child: Artwork(
                      art: album.art,
                      size: box.maxWidth,
                      resolution: ArtSize.medium,
                      radius: 10,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                album.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                album.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Palette.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AlbumPage extends StatelessWidget {
  const AlbumPage({super.key, required this.album});

  final Album album;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = AppScope.of(context).player;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final artSize = narrow ? 160.0 : 220.0;
    final details = [
      ?album.year?.toString(),
      '${album.tracks.length} ${album.tracks.length == 1 ? 'song' : 'songs'}',
      longDuration(album.durationSecs),
    ].join(' · ');

    final info = Column(
      crossAxisAlignment: narrow
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          album.title,
          textAlign: narrow ? TextAlign.center : TextAlign.start,
          style: theme.textTheme.headlineMedium,
        ),
        const SizedBox(height: 6),
        NameLinks(
          names: [album.artist],
          style: theme.textTheme.titleMedium?.copyWith(color: Palette.accent),
          onOpen: (name) => openArtist(context, name),
        ),
        const SizedBox(height: 4),
        Text(
          details,
          style: theme.textTheme.bodyMedium?.copyWith(color: Palette.textMuted),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: narrow ? WrapAlignment.center : WrapAlignment.start,
          children: [
            FilledButton.icon(
              onPressed: () => player.playTracks(album.tracks, 0),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Play'),
            ),
            FindOnServices(artist: album.artist, album: album.title),
          ],
        ),
      ],
    );

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 24, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back_rounded),
                    tooltip: 'Back',
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Flex(
                  direction: narrow ? Axis.vertical : Axis.horizontal,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Hero(
                      tag: 'album-${album.artist}-${album.title}',
                      child: Artwork(
                        art: album.art,
                        size: artSize,
                        resolution: ArtSize.medium,
                        radius: 12,
                      ),
                    ),
                    SizedBox(width: narrow ? 0 : 28, height: narrow ? 20 : 0),
                    if (narrow) info else Expanded(child: info),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 32 + dockInset(context)),
              sliver: SliverFixedExtentList.builder(
                itemExtent: TrackTile.height,
                itemCount: album.tracks.length,
                itemBuilder: (context, i) => TrackTile(
                  track: album.tracks[i],
                  number: album.tracks[i].trackNo ?? i + 1,
                  showAlbum: false,
                  onTap: () => player.playTracks(album.tracks, i),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
