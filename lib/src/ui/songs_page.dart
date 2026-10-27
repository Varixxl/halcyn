import 'package:flutter/material.dart';

import '../state/library.dart';
import 'slate.dart';
import 'track_list.dart';
import 'widgets.dart';

class SongsPage extends StatefulWidget {
  const SongsPage({super.key, required this.query});

  final String query;

  @override
  State<SongsPage> createState() => _SongsPageState();
}

class _SongsPageState extends State<SongsPage> {
  bool _lyricsOnly = false;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final library = scope.library;
    return ListenableBuilder(
      listenable: Listenable.merge([library, scope.sort]),
      builder: (context, _) {
        final sort = scope.sort.tracks('songs');
        final tracks = sort.apply([
          for (final t in library.tracks)
            if ((!_lyricsOnly || library.withLyrics.contains(t.path)) &&
                matches(t, widget.query))
              t,
        ], library.plays);
        return LayoutBuilder(
          builder: (context, box) {
            final columns = TrackColumns.of(box.maxWidth);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Pill(
                        label: 'All · ${library.tracks.length}',
                        selected: !_lyricsOnly,
                        onPressed: () => setState(() => _lyricsOnly = false),
                      ),
                      Pill(
                        label: 'Has lyrics · ${library.withLyrics.length}',
                        selected: _lyricsOnly,
                        onPressed: () => setState(() => _lyricsOnly = true),
                      ),
                    ],
                  ),
                ),
                TrackListHeader(
                  columns: columns,
                  sort: sort,
                  onSort: (sort) => scope.sort.setTracks('songs', sort),
                ),
                Expanded(
                  child: tracks.isEmpty
                      ? EmptyState(
                          icon: Icons.library_music_outlined,
                          message: library.tracks.isEmpty
                              ? 'No music yet. Add a folder in Settings.'
                              : 'Nothing matches "${widget.query}".',
                        )
                      : ListView.builder(
                          padding: EdgeInsets.only(
                            top: 4,
                            bottom: 24 + dockInset(context),
                          ),
                          itemExtent: TrackRow.height,
                          itemCount: tracks.length,
                          itemBuilder: (context, i) => TrackRow(
                            track: tracks[i],
                            number: i + 1,
                            columns: columns,
                            onTap: () => scope.player.playTracks(tracks, i),
                          ),
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
