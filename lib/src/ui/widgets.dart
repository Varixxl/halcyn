import '../cast/receiver.dart';
import '../cast/sender.dart';
import '../state/account.dart';
import '../state/discord.dart';
import '../state/downloads.dart';
import '../state/fetcher.dart';
import '../state/plugins.dart';
import '../state/streaming.dart';
import '../state/updater.dart';

import 'dart:io';

import 'package:flutter/material.dart';

import '../rust/api/library.dart';
import '../rust/api/player.dart';
import '../state/android.dart';
import '../state/library.dart';
import '../state/player.dart';
import '../state/playlists.dart';
import '../state/sort.dart';
import '../state/sound.dart';
import '../state/themes.dart';
import '../theme.dart';
import '../window.dart';

/// Gives every widget below it the app's controllers.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.player,
    required this.library,
    required this.window,
    required this.themes,
    required this.playlists,
    required this.sound,
    required this.sort,
    required this.access,
    required this.artDir,
    required this.cast,
    required this.receiver,
    required this.updater,
    required this.plugins,
    required this.fetcher,
    required this.streaming,
    required this.account,
    required this.downloads,
    required this.discord,
    required super.child,
  });

  final PlayerController player;
  final LibraryController library;
  final WindowController window;
  final ThemeController themes;
  final PlaylistsController playlists;
  final SoundController sound;
  final SortPrefs sort;
  final MusicAccess access;
  final String artDir;
  final CastController cast;
  final CastReceiver receiver;
  final Updater updater;
  final PluginManager plugins;
  final Fetcher fetcher;
  final StreamingController streaming;
  final AccountController account;
  final DownloadsController downloads;
  final DiscordPresence discord;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope old) => false;
}

/// The sizes the art cache keeps of each cover.
enum ArtSize {
  small('128'),
  medium('512'),
  full('full');

  const ArtSize(this.suffix);
  final String suffix;
}

File artFile(String artDir, String art, ArtSize size) =>
    File('$artDir/$art-${size.suffix}.jpg');

/// A cover from the art cache, sized so the decoder never does more work than the
/// pixels on screen need.
class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    required this.art,
    required this.size,
    this.resolution = ArtSize.small,
    this.radius = 6,
  });

  final String? art;
  final double size;
  final ArtSize resolution;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final art = this.art;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final placeholder = ColoredBox(
      color: Palette.surfaceHigh,
      child: Icon(
        Icons.music_note_rounded,
        size: size * 0.4,
        color: Palette.textMuted,
      ),
    );

    final radius = Palette.r(this.radius);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: size < 100 ? const BoxDecoration() : _sheen(radius),
        child: SizedBox.square(
          dimension: size,
          child: art == null
              ? placeholder
              : Image.file(
                  artFile(AppScope.of(context).artDir, art, resolution),
                  fit: BoxFit.cover,
                  cacheWidth: (size * dpr).round(),
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) => placeholder,
                  frameBuilder: (context, child, frame, sync) => sync
                      ? child
                      : AnimatedOpacity(
                          opacity: frame == null ? 0 : 1,
                          duration: Motion.fast,
                          curve: Motion.curve,
                          child: child,
                        ),
                ),
        ),
      ),
    );
  }

  /// Light catching the top-left of the cover, and a faint rim.
  static BoxDecoration _sheen(double radius) {
    final sheen = Palette.theme.sheen;
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: Palette.glassRim),
      gradient: sheen <= 0
          ? null
          : LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFFFFFFFF).withValues(alpha: sheen),
                const Color(0x00FFFFFF),
                const Color(0x00FFFFFF),
              ],
              stops: const [0, 0.38, 1],
            ),
    );
  }
}

/// One row in a song list.
class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.number,
    this.showAlbum = true,
  });

  static const height = 60.0;

  final Track track;
  final VoidCallback onTap;

  /// Shown instead of the cover, e.g. on an album page.
  final int? number;
  final bool showAlbum;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = AppScope.of(context);
    final player = scope.player;
    final plugins = scope.plugins;
    final library = scope.library;
    final wide = MediaQuery.sizeOf(context).width >= 900;

    return ListenableBuilder(
      listenable: Listenable.merge([player, plugins, library]),
      builder: (context, _) {
        final current = player.current?.id == track.id;
        final titleColor = current ? Palette.accent : Palette.text;
        final showPlays = plugins.showTrackPlays;
        return AnimatedContainer(
          duration: Motion.medium,
          curve: Motion.curve,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Palette.r(10)),
            gradient: LinearGradient(
              colors: [
                Palette.accent.withValues(alpha: current ? 0.16 : 0),
                Palette.accent.withValues(alpha: 0),
              ],
            ),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(Palette.r(10)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  if (number case final n?)
                    SizedBox(
                      width: 32,
                      child: current
                          ? Icon(
                              Icons.graphic_eq_rounded,
                              size: 18,
                              color: Palette.accent,
                            )
                          : Text(
                              '$n',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Palette.textMuted,
                              ),
                            ),
                    )
                  else
                    Artwork(art: track.art, size: 40),
                  const SizedBox(width: 14),
                  Expanded(
                    flex: 3,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: titleColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          track.artists.join(', '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Palette.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (wide && showAlbum) ...[
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 2,
                      child: Text(
                        track.album ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Palette.textMuted,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 16),
                  if (wide) ...[
                    QualityLabel(track: track),
                    const SizedBox(width: 16),
                  ],
                  if (showPlays) ...[
                    SizedBox(
                      width: 44,
                      child: Text(
                        formatPlays(library.plays(track)),
                        textAlign: TextAlign.right,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Palette.textMuted,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                  ],
                  SizedBox(
                    width: 44,
                    child: Text(
                      clock(track.durationSecs),
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Palette.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// "24/96" style resolution, highlighted for hi-res files.
class QualityLabel extends StatelessWidget {
  const QualityLabel({super.key, required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final bits = track.bits;
    final khz = track.sampleRate / 1000;
    final rate = khz == khz.roundToDouble() ? '${khz.round()}' : '$khz';
    // A streamed song says the best its service has it in: Hi-res, Lossless or AAC.
    final streamed = track.sampleRate == 0 && track.codec.isNotEmpty;
    final hiRes = streamed
        ? track.codec == 'Hi-res'
        : (bits ?? 0) > 16 || track.sampleRate > 48000;
    return SizedBox(
      width: 64,
      child: Text(
        streamed
            ? track.codec
            : bits == null
            ? rate
            : '$bits/$rate',
        textAlign: TextAlign.right,
        maxLines: 1,
        softWrap: false,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: hiRes
              ? Palette.accent.withValues(alpha: 0.85)
              : Palette.textMuted,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Cycles repeat: off, all, one. Lit while on.
class RepeatButton extends StatelessWidget {
  const RepeatButton({super.key, this.iconSize = 24});

  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final mode = player.repeat;
        return IconButton(
          onPressed: player.cycleRepeat,
          isSelected: mode != Repeat.off,
          icon: const Icon(Icons.repeat_rounded),
          selectedIcon: Icon(
            mode == Repeat.one
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
            color: Palette.accentLight,
          ),
          iconSize: iconSize,
          color: Palette.textMuted,
          tooltip: switch (mode) {
            Repeat.off => 'Repeat',
            Repeat.all => 'Repeating the queue',
            Repeat.one => 'Repeating this song',
          },
        );
      },
    );
  }
}

/// Play/pause that morphs between its two icons.
class PlayPauseButton extends StatefulWidget {
  const PlayPauseButton({super.key, this.size = 48, this.filled = true});

  final double size;
  final bool filled;

  @override
  State<PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<PlayPauseButton>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: Motion.medium,
  );
  PlayerController? _player;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final player = AppScope.of(context).player;
    if (player != _player) {
      _player?.removeListener(_sync);
      _player = player..addListener(_sync);
      _controller.value = player.playing ? 1 : 0;
    }
  }

  void _sync() =>
      _player!.playing ? _controller.forward() : _controller.reverse();

  @override
  void dispose() {
    _player?.removeListener(_sync);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final icon = AnimatedIcon(
          icon: AnimatedIcons.play_pause,
          progress: CurvedAnimation(parent: _controller, curve: Motion.curve),
          size: widget.size * 0.5,
        );
        final onPressed = player.current == null ? null : player.toggle;
        return SizedBox.square(
          dimension: widget.size,
          child: widget.filled
              ? _GlossyOrb(
                  size: widget.size,
                  enabled: onPressed != null,
                  child: IconButton(
                    onPressed: onPressed,
                    icon: icon,
                    color: Palette.onAccent,
                    tooltip: 'Play/Pause (Space)',
                  ),
                )
              : IconButton(onPressed: onPressed, icon: icon),
        );
      },
    );
  }
}

/// A lapis sphere: lit from above, with a gloss cap and a soft glow underneath. Flat on
/// matte themes.
class _GlossyOrb extends StatelessWidget {
  const _GlossyOrb({
    required this.size,
    required this.enabled,
    required this.child,
  });

  final double size;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Matte themes get a flat disc.
    if (Palette.theme.gloss == 0) {
      return AnimatedOpacity(
        opacity: enabled ? 1 : 0.45,
        duration: Motion.fast,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Palette.accent,
          ),
          child: child,
        ),
      );
    }
    return AnimatedOpacity(
      opacity: enabled ? 1 : 0.45,
      duration: Motion.fast,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Palette.accentLight, Palette.accent, Palette.accentDeep],
            stops: const [0, 0.45, 1],
          ),
          border: Border.all(color: const Color(0x40FFFFFF), width: 0.8),
          boxShadow: [
            BoxShadow(
              color: Palette.accent.withValues(alpha: 0.45),
              blurRadius: size * 0.45,
              offset: Offset(0, size * 0.12),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned(
              top: size * 0.05,
              left: size * 0.2,
              right: size * 0.2,
              height: size * 0.4,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(size),
                      bottom: Radius.circular(size * 0.3),
                    ),
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x66FFFFFF), Color(0x00FFFFFF)],
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(child: child),
          ],
        ),
      ),
    );
  }
}

/// The seek bar with elapsed and total time. Rebuilds only on position changes.
class SeekBar extends StatefulWidget {
  const SeekBar({super.key, this.compact = false});

  final bool compact;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Palette.textMuted,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final duration = player.current?.durationSecs ?? 0;
        return RepaintBoundary(
          child: ValueListenableBuilder(
            valueListenable: player.position,
            builder: (context, position, _) {
              final shown = (_dragging ?? position).clamp(
                0.0,
                duration > 0 ? duration : 0.0,
              );
              final slider = SliderTheme(
                data: SliderTheme.of(context)
                    .copyWith(padding: EdgeInsets.zero),
                child: Slider(
                  value: shown,
                  max: duration > 0 ? duration : 1,
                  onChanged: duration > 0
                      ? (v) => setState(() => _dragging = v)
                      : null,
                  onChangeEnd: (v) {
                    player.seek(v);
                    setState(() => _dragging = null);
                  },
                ),
              );
              if (widget.compact) {
                return LayoutBuilder(
                  builder: (context, size) {
                    // A narrow bar keeps the slider and drops the times.
                    if (size.maxWidth < 160) return slider;
                    return Row(
                      children: [
                        SizedBox(
                          width: 40,
                          child: Text(clock(shown), style: style),
                        ),
                        Expanded(child: slider),
                        SizedBox(
                          width: 40,
                          child: Text(
                            clock(duration),
                            style: style,
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ],
                    );
                  },
                );
              }
              return Column(
                children: [
                  slider,
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(clock(shown), style: style),
                      const Spacer(),
                      Text(clock(duration), style: style),
                    ],
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

/// Shows one child at a time and fades in the newly selected one. Every child stays
/// alive, so switching keeps scroll positions and costs nothing to rebuild.
class FadeIndexedStack extends StatefulWidget {
  const FadeIndexedStack({
    super.key,
    required this.index,
    required this.children,
  });

  final int index;
  final List<Widget> children;

  @override
  State<FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<FadeIndexedStack>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: Motion.medium,
    value: 1,
  );

  @override
  void didUpdateWidget(FadeIndexedStack old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _controller, curve: Motion.curve);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.008),
          end: Offset.zero,
        ).animate(curved),
        child: IndexedStack(
          index: widget.index,
          children: [
            for (final (i, child) in widget.children.indexed)
              TickerMode(enabled: i == widget.index, child: child),
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: Palette.textMuted),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: Palette.textMuted),
          ),
        ],
      ),
    );
  }
}

/// Room at the bottom of a scrolling page for the player dock that floats over it.
double dockInset(BuildContext context) => MediaQuery.paddingOf(context).bottom;

String clock(double secs) {
  final s = secs.isFinite ? secs.floor() : 0;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final ss = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// Formats a track's play count: "0", "42", "1.2k", "1.5M".
String formatPlays(int count) {
  if (count >= 1000000) {
    final v = count / 1000000;
    return '${v.toStringAsFixed(v >= 10 ? 0 : 1)}M';
  }
  if (count >= 10000) {
    return '${(count / 1000).toStringAsFixed(0)}k';
  }
  if (count >= 1000) {
    return '${(count / 1000).toStringAsFixed(1)}k';
  }
  return '$count';
}

/// "3 h 12 min" / "42 min" for album and playlist lengths.
String longDuration(double secs) {
  final minutes = (secs / 60).round();
  return minutes >= 60
      ? '${minutes ~/ 60} h ${minutes % 60} min'
      : '$minutes min';
}

/// The device being cast to, while casting: its signal path is what this one shows.
String? castTarget(BuildContext context) {
  final scope = AppScope.of(context);
  return scope.player.casting ? scope.cast.device?.name : null;
}
