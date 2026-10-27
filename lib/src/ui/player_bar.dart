import 'package:flutter/material.dart';

import '../theme.dart';
import 'cast.dart';
import 'equalizer.dart';
import 'now_playing.dart';
import 'plugin_view.dart';
import 'sidebar.dart';
import 'slate.dart';
import 'widgets.dart';

/// The desktop transport, docked along the bottom: shuffle, previous, play, next, repeat, the
/// seek bar, shortcuts to lyrics, the queue and the equalizer, and volume.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key, this.onQueue});

  static const height = 68.0;

  /// Shows the queue page.
  final VoidCallback? onQueue;

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Palette.surface,
        border: Border(top: BorderSide(color: Palette.outline)),
      ),
      child: ListenableBuilder(
        listenable: player,
        builder: (context, _) {
          final loaded = player.current != null;
          return Row(
            children: [
              IconButton(
                onPressed: player.toggleShuffle,
                isSelected: player.shuffle,
                icon: const Icon(Icons.shuffle_rounded),
                iconSize: 20,
                color: Palette.textMuted,
                selectedIcon: Icon(
                  Icons.shuffle_rounded,
                  color: Palette.accentLight,
                ),
                tooltip: player.shuffle ? 'Shuffle is on' : 'Shuffle',
              ),
              IconButton(
                onPressed: loaded ? player.previous : null,
                icon: const Icon(Icons.skip_previous_rounded),
                tooltip: 'Previous',
              ),
              const SizedBox(width: 4),
              const PlayPauseButton(size: 46),
              const SizedBox(width: 4),
              IconButton(
                onPressed: player.hasNext ? player.next : null,
                icon: const Icon(Icons.skip_next_rounded),
                tooltip: 'Next',
              ),
              const RepeatButton(iconSize: 20),
              const SizedBox(width: 12),
              const Expanded(child: SeekBar(compact: true)),
              const SizedBox(width: 12),
              const PluginPlayerButtons(),
              Pill(
                label: 'Lyrics',
                icon: Icons.lyrics_outlined,
                onPressed: loaded
                    ? () =>
                          openNowPlaying(context, panel: NowPlayingPanel.lyrics)
                    : null,
              ),
              if (onQueue != null)
                IconButton(
                  onPressed: onQueue,
                  icon: const Icon(Icons.queue_music_rounded),
                  iconSize: 20,
                  color: Palette.textMuted,
                  tooltip: 'Queue',
                ),
              const CastButton(),
              if (!player.casting) const EqButton(),
              const NowPlayingCardButton(),
              const VolumeSlider(width: 96),
            ],
          );
        },
      ),
    );
  }
}

/// The phone bar above the navigation: cover, title, play/pause, and a progress line.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final track = player.current;
        return AnimatedSize(
          duration: Motion.medium,
          curve: Motion.curve,
          child: track == null
              ? const SizedBox(width: double.infinity)
              : Material(
                  color: Palette.surfaceHigh.withValues(alpha: 0.6),
                  child: InkWell(
                    onTap: () => openNowPlaying(context),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                          child: Row(
                            children: [
                              Hero(
                                tag: nowPlayingArtTag,
                                child: Artwork(art: track.art, size: 44),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _Titles(
                                  title: track.title,
                                  artists: track.artists,
                                ),
                              ),
                              if (player.casting)
                                const CastButton(compact: true),
                              const PlayPauseButton(size: 44, filled: false),
                            ],
                          ),
                        ),
                        const _ProgressLine(),
                      ],
                    ),
                  ),
                ),
        );
      },
    );
  }
}

/// Shrinks the window into the mini player.
class MiniModeButton extends StatelessWidget {
  const MiniModeButton({super.key});

  @override
  Widget build(BuildContext context) {
    final window = AppScope.of(context).window;
    return IconButton(
      onPressed: () => window.setMini(true),
      icon: const Icon(Icons.picture_in_picture_alt_rounded),
      iconSize: 20,
      color: Palette.textMuted,
      tooltip: 'Mini player (Ctrl+M)',
    );
  }
}

class _Titles extends StatelessWidget {
  const _Titles({required this.title, required this.artists});

  final String title;
  final List<String> artists;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          artists.join(', '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: Palette.textMuted),
        ),
      ],
    );
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine();

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: Listenable.merge([player, player.position]),
        builder: (context, _) {
          final duration = player.current?.durationSecs ?? 0;
          return LinearProgressIndicator(
            value: duration > 0
                ? (player.position.value / duration).clamp(0.0, 1.0)
                : 0,
            minHeight: 2,
            backgroundColor: Colors.transparent,
          );
        },
      ),
    );
  }
}
