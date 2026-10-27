import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../rust/api/library.dart';
import '../signal_path_view.dart';
import '../state/streaming.dart';
import '../state/lyrics.dart';
import '../state/player.dart';
import '../theme.dart';
import '../window.dart';
import 'cast.dart';
import 'equalizer.dart';
import 'player_bar.dart';
import 'plugin_view.dart';
import 'queue_page.dart';
import 'slate.dart';
import 'visualizer.dart';
import 'widgets.dart';

const nowPlayingArtTag = 'now-playing-art';

/// What shares the page with the cover and controls.
enum NowPlayingPanel { none, lyrics, queue }

void openNowPlaying(
  BuildContext context, {
  NowPlayingPanel panel = NowPlayingPanel.none,
}) {
  Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder(
      transitionDuration: Motion.slow,
      reverseTransitionDuration: Motion.medium,
      pageBuilder: (_, _, _) => NowPlayingPage(panel: panel),
      transitionsBuilder: (_, animation, _, child) {
        final curved = CurvedAnimation(parent: animation, curve: Motion.curve);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.03),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    ),
  );
}

/// The player, full window, over a visualizer in the cover's colours. Lyrics or the
/// queue can open beside the cover.
class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({super.key, this.panel = NowPlayingPanel.none});

  final NowPlayingPanel panel;

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  /// What the user picked; null until they do, which shows Up Next when there's room.
  late NowPlayingPanel? _chosen = widget.panel == NowPlayingPanel.none
      ? null
      : widget.panel;

  /// Wide enough for the queue beside the player without squeezing the cover.
  static const _roomForUpNext = 1180.0;

  NowPlayingPanel _panel(BuildContext context) =>
      _chosen ??
      (MediaQuery.sizeOf(context).width >= _roomForUpNext
          ? NowPlayingPanel.queue
          : NowPlayingPanel.none);

  void _toggle(NowPlayingPanel panel) => setState(
    () => _chosen = _panel(context) == panel ? NowPlayingPanel.none : panel,
  );

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    final panel = _panel(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: ListenableBuilder(
            listenable: player,
            builder: (context, _) {
              final track = player.current;
              final narrowBar = MediaQuery.sizeOf(context).width < 520;
              return VisualizerBackdrop(
                art: track?.art,
                child: SafeArea(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                              ),
                              iconSize: 30,
                              tooltip: 'Close (Esc)',
                            ),
                            const Spacer(),
                            const PluginPlayerButtons(),
                            // Phones have their own volume keys, but those don't
                            // reach the device cast to.
                            if (MediaQuery.sizeOf(context).width >= 600 ||
                                player.casting) ...[
                              VolumeSlider(
                                width: MediaQuery.sizeOf(context).width < 600
                                    ? 72
                                    : 120,
                              ),
                              const SizedBox(width: 8),
                            ],
                            const CastButton(compact: true),
                            if (!player.casting) const EqButton(),
                            const SizedBox(width: 8),
                            // A phone is too narrow for the volume, cast, Lyrics
                            // and Queue side by side, so the pills keep just their
                            // icons (and the queue's count).
                            Pill(
                              label: narrowBar ? '' : 'Lyrics',
                              tooltip: narrowBar ? 'Lyrics' : null,
                              icon: Icons.lyrics_outlined,
                              selected: panel == NowPlayingPanel.lyrics,
                              onPressed: () => _toggle(NowPlayingPanel.lyrics),
                            ),
                            const SizedBox(width: 8),
                            Pill(
                              label: narrowBar
                                  ? '${player.upNext.length}'
                                  : 'Queue · ${player.upNext.length}',
                              tooltip: narrowBar ? 'Queue' : null,
                              icon: Icons.queue_music_rounded,
                              selected: panel == NowPlayingPanel.queue,
                              onPressed: () => _toggle(NowPlayingPanel.queue),
                            ),
                            if (WindowController.supported) ...[
                              const SizedBox(width: 4),
                              const MiniModeButton(),
                            ],
                          ],
                        ),
                      ),
                      Expanded(
                        child: track == null
                            ? const EmptyState(
                                icon: Icons.music_note_rounded,
                                message: 'Nothing playing.',
                              )
                            : LayoutBuilder(
                                // Short screens (a phone on its side) use the narrow
                                // layout's landscape arrangement at any width.
                                builder: (context, box) =>
                                    box.maxWidth >= 860 && box.maxHeight >= 520
                                    ? _WideLayout(box: box, panel: panel)
                                    : _NarrowLayout(box: box, panel: panel),
                              ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Wide: the player (cover with its controls underneath) and, sliding in on the right,
/// lyrics or the queue.
class _WideLayout extends StatelessWidget {
  const _WideLayout({required this.box, required this.panel});

  final BoxConstraints box;
  final NowPlayingPanel panel;

  @override
  Widget build(BuildContext context) {
    final panelWidth = (box.maxWidth * 0.42).clamp(340.0, 560.0);
    final open = panel != NowPlayingPanel.none;
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 0, 40, 28),
      child: Row(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => Center(child: _Player(box: box)),
            ),
          ),
          AnimatedContainer(
            duration: Motion.slow,
            curve: Motion.curve,
            width: open ? panelWidth + 40 : 0,
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: panelWidth + 40,
                maxWidth: panelWidth + 40,
                child: Padding(
                  padding: const EdgeInsets.only(left: 40, top: 8),
                  child: AnimatedOpacity(
                    opacity: open ? 1 : 0,
                    duration: Motion.medium,
                    child: _PanelView(panel: panel),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Narrow: the player in a scrolling column, or, with a panel open, a small header over
/// the panel and the controls.
class _NarrowLayout extends StatelessWidget {
  const _NarrowLayout({required this.box, required this.panel});

  final BoxConstraints box;
  final NowPlayingPanel panel;

  @override
  Widget build(BuildContext context) {
    final open = panel != NowPlayingPanel.none;
    final landscape = box.maxWidth > box.maxHeight && box.maxHeight < 520;
    return AnimatedSwitcher(
      duration: Motion.slow,
      switchInCurve: Motion.curve,
      switchOutCurve: Motion.curve,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: open && landscape
          // A phone on its side: the controls beside the panel, which keeps the height.
          ? Padding(
              key: const ValueKey('panel'),
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: min(360, box.maxWidth * 0.45),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _Header(),
                        SizedBox(height: 16),
                        SeekBar(),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: _Transport(compact: true),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(child: _PanelView(panel: panel)),
                ],
              ),
            )
          : open
          ? Padding(
              key: const ValueKey('panel'),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _Header(),
                  const SizedBox(height: 12),
                  Expanded(child: _PanelView(panel: panel)),
                  const SizedBox(height: 12),
                  const SeekBar(),
                  const SizedBox(height: 4),
                  const _Transport(compact: true),
                ],
              ),
            )
          // A phone on its side: the player fits the screen rather than scrolling.
          : box.maxWidth > box.maxHeight && box.maxHeight < 520
          ? Padding(
              key: const ValueKey('player'),
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: LayoutBuilder(
                builder: (context, box) => Center(child: _Player(box: box)),
              ),
            )
          : ListView(
              key: const ValueKey('player'),
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              children: [
                Center(
                  child: _Player(
                    box: BoxConstraints(
                      maxWidth: box.maxWidth - 48,
                      maxHeight: double.infinity,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// Lyrics or the queue. While closing it keeps showing the last one, so it can slide out.
class _PanelView extends StatefulWidget {
  const _PanelView({required this.panel});

  final NowPlayingPanel panel;

  @override
  State<_PanelView> createState() => _PanelViewState();
}

class _PanelViewState extends State<_PanelView> {
  late NowPlayingPanel _shown = widget.panel;

  @override
  void didUpdateWidget(_PanelView old) {
    super.didUpdateWidget(old);
    if (widget.panel != NowPlayingPanel.none) _shown = widget.panel;
  }

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final track = player.current;
        return AnimatedSwitcher(
          duration: Motion.medium,
          switchInCurve: Motion.curve,
          switchOutCurve: Motion.curve,
          child: switch (_shown) {
            NowPlayingPanel.lyrics when track != null => LyricsView(
              key: ValueKey(track.path),
              path: track.path,
            ),
            NowPlayingPanel.queue => const QueuePage(compact: true),
            _ => const SizedBox.shrink(),
          },
        );
      },
    );
  }
}

/// The cover with the titles, seek bar and transport underneath, sized to fit `box`.
/// The signal path card goes below when there's height to spare. Too short to stack (a
/// phone on its side), the controls go beside the cover instead.
class _Player extends StatelessWidget {
  const _Player({required this.box});

  final BoxConstraints box;

  /// Titles, seek bar and transport, below the cover.
  static const _controls = 236.0;
  static const _card = 190.0;

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final width = box.maxWidth;
        final error = player.error;
        final errorText = error == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              );
        if (box.maxHeight.isFinite && box.maxHeight - _controls < 200) {
          final art = min(box.maxHeight, width * 0.42).clamp(96.0, 520.0);
          return SizedBox(
            width: min(width, art + 28 + 480),
            child: Row(
              children: [
                _Cover(size: art),
                const SizedBox(width: 28),
                Expanded(
                  // Scrolls if even the controls alone don't fit.
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _Titles(),
                        const SizedBox(height: 10),
                        const SeekBar(),
                        const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: _Transport(compact: true),
                        ),
                        ?errorText,
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        final fit = [width, box.maxHeight - _controls, 520.0].reduce(min);
        final withCard = [
          width,
          box.maxHeight - _controls - _card,
          520.0,
        ].reduce(min);
        final card = player.signalPath != null && withCard >= 280;
        final art = (card ? withCard : fit).clamp(160.0, 520.0);
        return SizedBox(
          width: max(art, min(width, 340.0)),
          // The card's lines can wrap past the room allowed for it: then this scrolls.
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(child: _Cover(size: art)),
                const SizedBox(height: 24),
                const _Titles(),
                const SizedBox(height: 14),
                const SeekBar(),
                const SizedBox(height: 4),
                const _Transport(),
                ?errorText,
                AnimatedSize(
                  duration: Motion.medium,
                  curve: Motion.curve,
                  child: card
                      ? Padding(
                          padding: const EdgeInsets.only(top: 20),
                          child: SignalPathView(
                            path: player.signalPath!,
                            castTo: castTarget(context),
                            origin:
                                serviceNames[serviceOf(
                                  player.current?.path ?? '',
                                )],
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final track = AppScope.of(context).player.current;
    return Hero(
      tag: nowPlayingArtTag,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Palette.r(16)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 40,
              offset: Offset(0, 16),
            ),
          ],
        ),
        child: AnimatedSwitcher(
          duration: Motion.slow,
          switchInCurve: Motion.curve,
          switchOutCurve: Motion.curve,
          child: Artwork(
            key: ValueKey(track?.art),
            art: track?.art,
            size: size,
            resolution: ArtSize.full,
            radius: 16,
          ),
        ),
      ),
    );
  }
}

/// Title, artists, and the album with the signal badge.
class _Titles extends StatelessWidget {
  const _Titles();

  // It's const, so it listens itself: its parent doesn't rebuild it on a new track.
  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) => player.current == null
          ? const SizedBox.shrink()
          : _titles(context, player),
    );
  }

  Widget _titles(BuildContext context, PlayerController player) {
    final theme = Theme.of(context);
    final track = player.current!;
    final album = [?track.album, ?track.year?.toString()].join(' · ');
    return AnimatedSwitcher(
      duration: Motion.medium,
      switchInCurve: Motion.curve,
      switchOutCurve: Motion.curve,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topLeft,
        children: [...previous, ?current],
      ),
      child: Column(
        key: ValueKey(track.path),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            track.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            track.artists.join(', '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              color: Palette.accentLight,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (album.isNotEmpty)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Text(
                      album,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Palette.textMuted,
                      ),
                    ),
                  ),
                ),
              SignalBadge(path: player.signalPath, castTo: castTarget(context)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Narrow, with a panel open: a small cover beside the titles.
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) => player.current == null
          ? const SizedBox.shrink()
          : _header(context, player.current!),
    );
  }

  Widget _header(BuildContext context, Track track) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Artwork(art: track.art, size: 56, radius: 10),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                track.artists.join(', '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Palette.accentLight),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Shuffle, previous, play/pause, next, repeat.
class _Transport extends StatelessWidget {
  const _Transport({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) => Row(
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
          const SizedBox(width: 12),
          IconButton(
            onPressed: player.previous,
            icon: const Icon(Icons.skip_previous_rounded),
            iconSize: 36,
            tooltip: 'Previous',
          ),
          const SizedBox(width: 16),
          PlayPauseButton(size: compact ? 60 : 68),
          const SizedBox(width: 16),
          IconButton(
            onPressed: player.hasNext ? player.next : null,
            icon: const Icon(Icons.skip_next_rounded),
            iconSize: 36,
            tooltip: 'Next',
          ),
          const SizedBox(width: 12),
          const RepeatButton(),
        ],
      ),
    );
  }
}

/// The song's synced lyrics, following along. Tap a line to jump there. Scrolling by
/// hand pauses the following for a few seconds.
class LyricsView extends StatefulWidget {
  const LyricsView({super.key, required this.path});

  final String path;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  // While casting, the .lrc is on the other device.
  late final Future<Lyrics?> _lyrics = loadLyrics(
    widget.path,
    fetch: AppScope.of(context).cast.connected
        ? AppScope.of(context).cast.lyrics
        : null,
  );
  final _scroll = ScrollController();
  List<GlobalKey> _keys = const [];
  Lyrics? _loaded;
  int _line = -1;
  DateTime _heldUntil = DateTime(0);
  ValueNotifier<double>? _position;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = AppScope.of(context).player.position;
    if (position != _position) {
      _position?.removeListener(_follow);
      _position = position..addListener(_follow);
    }
  }

  @override
  void dispose() {
    _position?.removeListener(_follow);
    _scroll.dispose();
    super.dispose();
  }

  void _follow() {
    final lyrics = _loaded;
    if (lyrics == null) return;
    // The position arrives five times a second; lead it slightly so lines don't lag.
    final line = lyrics.lineAt(_position!.value + 0.15);
    if (line == _line) return;
    setState(() => _line = line);
    if (line < 0 || DateTime.now().isBefore(_heldUntil)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _keys[line].currentContext;
      if (target == null || !mounted) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.35,
        duration: Motion.slow,
        curve: Motion.curve,
      );
    });
  }

  void _hold() => _heldUntil = DateTime.now().add(const Duration(seconds: 4));

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _lyrics,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox.shrink();
        }
        final lyrics = snapshot.data;
        if (lyrics == null) {
          return const EmptyState(
            icon: Icons.lyrics_outlined,
            message: 'No lyrics for this song.\nHalcyn reads a .lrc file next to it.',
          );
        }
        if (!identical(lyrics, _loaded)) {
          _loaded = lyrics;
          _keys = [for (final _ in lyrics.lines) GlobalKey()];
          _line = lyrics.lineAt(_position!.value);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final target = _line < 0 ? null : _keys[_line].currentContext;
            if (target != null) {
              Scrollable.ensureVisible(target, alignment: 0.35);
            }
          });
        }
        return _lines(context, lyrics);
      },
    );
  }

  Widget _lines(BuildContext context, Lyrics lyrics) {
    final player = AppScope.of(context).player;
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) _hold();
      },
      child: NotificationListener<ScrollStartNotification>(
        onNotification: (n) {
          if (n.dragDetails != null) _hold();
          return false;
        },
        child: ShaderMask(
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0x00FFFFFF),
              Color(0xFFFFFFFF),
              Color(0xFFFFFFFF),
              Color(0x00FFFFFF),
            ],
            stops: [0, 0.08, 0.88, 1],
          ).createShader(rect),
          blendMode: BlendMode.dstIn,
          child: SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, line) in lyrics.lines.indexed)
                  _Line(
                    key: _keys[i],
                    text: line.text,
                    state: !lyrics.synced
                        ? _LineState.plain
                        : i == _line
                        ? _LineState.current
                        : i < _line
                        ? _LineState.past
                        : _LineState.ahead,
                    onTap: line.secs == null
                        ? null
                        : () {
                            _heldUntil = DateTime(0);
                            player.seek(line.secs!);
                          },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _LineState { plain, past, current, ahead }

class _Line extends StatelessWidget {
  const _Line({
    super.key,
    required this.text,
    required this.state,
    required this.onTap,
  });

  final String text;
  final _LineState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (color, size) = switch (state) {
      _LineState.plain => (Palette.text, 20.0),
      _LineState.current => (Palette.text, 26.0),
      _LineState.past => (Palette.textMuted.withValues(alpha: 0.5), 22.0),
      _LineState.ahead => (Palette.textMuted.withValues(alpha: 0.8), 22.0),
    };
    return MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: AnimatedDefaultTextStyle(
            duration: Motion.medium,
            curve: Motion.curve,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: size,
              height: 1.3,
              fontWeight: state == _LineState.plain
                  ? FontWeight.w500
                  : FontWeight.w700,
              letterSpacing: -0.3,
              color: color,
            ),
            child: Text(text.isEmpty ? '♪' : text),
          ),
        ),
      ),
    );
  }
}
