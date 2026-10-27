import 'package:flutter/material.dart';

import '../theme.dart';
import 'slate.dart';
import 'track_list.dart';
import 'widgets.dart';

/// What's playing and what comes next. Drag the numbers to reorder; the ⋯ menu removes.
class QueuePage extends StatelessWidget {
  const QueuePage({super.key, this.compact = false});

  /// In Now Playing: no column titles, no page padding.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final current = player.current;
        if (current == null) {
          return const EmptyState(
            icon: Icons.queue_music_rounded,
            message: 'The queue is empty. Play something to start one.',
          );
        }
        final next = player.upNext;
        final start = player.index + 1;
        return LayoutBuilder(
          builder: (context, box) {
            final columns = compact
                ? TrackColumns.of(0)
                : TrackColumns.of(box.maxWidth);
            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: SectionLabel('Now playing')),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: TrackRow.height,
                    child: TrackRow(
                      track: current,
                      number: start,
                      columns: columns,
                      current: true,
                      onTap: player.toggle,
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SectionLabel(
                    'Up next · ${next.length}',
                    trailing: next.isEmpty
                        ? null
                        : TextButton(
                            onPressed: player.clearUpNext,
                            child: const Text('Clear'),
                          ),
                  ),
                ),
                if (next.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'Nothing after this. Use Play next or Add to queue on any song.',
                        style: TextStyle(color: Palette.textMuted),
                      ),
                    ),
                  ),
                SliverReorderableList(
                  itemExtent: TrackRow.height,
                  itemCount: next.length,
                  onReorderItem: (from, to) =>
                      player.move(start + from, start + to),
                  itemBuilder: (context, i) => TrackRow(
                    key: ValueKey((start + i, next[i].path)),
                    track: next[i],
                    number: start + i + 1,
                    columns: columns,
                    current: false,
                    reorderIndex: i,
                    onTap: () => player.jumpTo(start + i),
                    onRemove: () => player.removeAt(start + i),
                    removeLabel: 'Remove from queue',
                  ),
                ),
                const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
              ],
            );
          },
        );
      },
    );
  }
}
