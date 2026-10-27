import 'package:flutter/material.dart';

import '../rust/api/library.dart';
import '../signal_path_view.dart';
import '../theme.dart';
import 'visualizer.dart';
import 'widgets.dart';

/// The phone-sized mini player: cover, titles, seek, transport, and a row of actions
/// along the bottom with room for more.
class MiniModeView extends StatelessWidget {
  const MiniModeView({super.key});

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    return Scaffold(
      body: ListenableBuilder(
        listenable: player,
        builder: (context, _) {
          final track = player.current;
          return VisualizerBackdrop(
            art: track?.art,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
              child: track == null
                  ? const Column(
                      children: [
                        Expanded(
                          child: EmptyState(
                            icon: Icons.music_note_rounded,
                            message: 'Nothing playing.',
                          ),
                        ),
                        Glass(child: _Actions()),
                      ],
                    )
                  : _Player(track: track),
            ),
          );
        },
      ),
    );
  }
}

class _Player extends StatelessWidget {
  const _Player({required this.track});

  /// Passed in rather than read, so a new track rebuilds this.
  final Track track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = AppScope.of(context).player;
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final size = box.maxWidth < box.maxHeight
                  ? box.maxWidth
                  : box.maxHeight;
              return Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Palette.r(16)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 32,
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  child: AnimatedSwitcher(
                    duration: Motion.slow,
                    switchInCurve: Motion.curve,
                    switchOutCurve: Motion.curve,
                    child: Artwork(
                      key: ValueKey(track.art),
                      art: track.art,
                      size: size,
                      resolution: ArtSize.medium,
                      radius: 16,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 18),
        Glass(
          tint: Palette.background.withValues(alpha: 0.25),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
            child: Column(
              children: [
                AnimatedSwitcher(
                  duration: Motion.medium,
                  switchInCurve: Motion.curve,
                  switchOutCurve: Motion.curve,
                  layoutBuilder: (current, previous) =>
                      Stack(children: [...previous, ?current]),
                  child: SizedBox(
                    key: ValueKey(track.id),
                    width: double.infinity,
                    child: Column(
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          track.artists.join(', '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Palette.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const SeekBar(),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: player.toggleShuffle,
                      isSelected: player.shuffle,
                      icon: const Icon(Icons.shuffle_rounded),
                      selectedIcon: Icon(
                        Icons.shuffle_rounded,
                        color: Palette.accentLight,
                      ),
                      color: Palette.textMuted,
                      tooltip: player.shuffle ? 'Shuffle is on' : 'Shuffle',
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      onPressed: player.previous,
                      icon: const Icon(Icons.skip_previous_rounded),
                      iconSize: 34,
                      tooltip: 'Previous',
                    ),
                    const SizedBox(width: 12),
                    const PlayPauseButton(size: 64),
                    const SizedBox(width: 12),
                    IconButton(
                      onPressed: player.hasNext ? player.next : null,
                      icon: const Icon(Icons.skip_next_rounded),
                      iconSize: 34,
                      tooltip: 'Next',
                    ),
                    const SizedBox(width: 4),
                    const RepeatButton(),
                  ],
                ),
                const SizedBox(height: 4),
                const _Actions(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Pin on the left, back to the full app on the right, the signal path between.
/// New buttons go into this row.
class _Actions extends StatelessWidget {
  const _Actions();

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final window = scope.window;
    return ListenableBuilder(
      listenable: Listenable.merge([window, scope.player]),
      builder: (context, _) => Row(
        children: [
          IconButton(
            onPressed: window.togglePin,
            isSelected: window.pinned,
            icon: const Icon(Icons.push_pin_outlined),
            selectedIcon: const Icon(Icons.push_pin_rounded),
            tooltip: window.pinned ? 'Unpin' : 'Pin on top',
          ),
          Expanded(
            child: Center(
              child: SignalBadge(
                path: scope.player.signalPath,
                castTo: castTarget(context),
              ),
            ),
          ),
          IconButton(
            onPressed: () => window.setMini(false),
            icon: const Icon(Icons.open_in_full_rounded),
            tooltip: 'Full player (Esc)',
          ),
        ],
      ),
    );
  }
}
