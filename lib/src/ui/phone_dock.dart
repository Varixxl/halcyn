import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'cast.dart';
import 'now_playing.dart';
import 'slate.dart';
import 'widgets.dart';

/// A place the phone dock (or its "Everywhere" sheet) goes to.
typedef DockTab = ({
  IconData icon,
  IconData selected,
  String label,
  VoidCallback open,
  bool Function() shown,
});

/// The phone's bottom: one panel like the desktop's player bar, with the song playing
/// (tap or swipe up for Now Playing) above the theme's own tab buttons. It runs under
/// Android's navigation bar, so the two read as one.
class PhoneDock extends StatelessWidget {
  const PhoneDock({super.key, required this.tabs, required this.everywhere});

  final List<DockTab> tabs;

  /// The last button: a sheet with every page; selected when no tab is.
  final DockTab everywhere;

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.paddingOf(context).bottom;
    final any = tabs.any((t) => t.shown());
    final radius = Radius.circular(Palette.r(22));
    // Typing (the search box): the keyboard covers this anyway.
    final typing = MediaQuery.viewInsetsOf(context).bottom > 0;
    return AnimatedSize(
      duration: Motion.medium,
      curve: Motion.curve,
      alignment: Alignment.topCenter,
      child: typing
          ? const SizedBox(width: double.infinity)
          : Container(
              decoration: BoxDecoration(
                color: Palette.surface,
                borderRadius: BorderRadius.vertical(top: radius),
                border: Border(top: BorderSide(color: Palette.outline)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 18,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              padding: EdgeInsets.only(bottom: inset + 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _DockPlayer(radius: radius),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
                    child: Row(
                      children: [
                        for (final t in tabs)
                          Expanded(
                            child: DockButton(tab: t, selected: t.shown()),
                          ),
                        Expanded(
                          child: DockButton(tab: everywhere, selected: !any),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// A tab: its icon in a pill that fills with the accent when it's the page shown.
class DockButton extends StatelessWidget {
  const DockButton({super.key, required this.tab, required this.selected});

  final DockTab tab;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Palette.text : Palette.textMuted;
    return Tooltip(
      message: tab.label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        selected: selected,
        label: tab.label,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            tab.open();
          },
          borderRadius: BorderRadius.circular(Palette.r(14)),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: SlateMotion.select,
                  curve: Motion.curve,
                  width: selected ? 52 : 40,
                  height: 30,
                  decoration: BoxDecoration(
                    color: selected ? Palette.accentDeep : Colors.transparent,
                    borderRadius: BorderRadius.circular(Palette.r(15)),
                  ),
                  child: Icon(
                    selected ? tab.selected : tab.icon,
                    size: 21,
                    color: selected ? Palette.onAccent : color,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  tab.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The song playing: cover, titles, previous, play and next, and how far in it is along
/// the top edge. Nothing at all while nothing's loaded.
class _DockPlayer extends StatelessWidget {
  const _DockPlayer({required this.radius});

  /// The dock's corner, which the progress line follows.
  final Radius radius;

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
          alignment: Alignment.topCenter,
          child: track == null
              ? const SizedBox(width: double.infinity, height: 4)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.vertical(top: radius),
                      child: const _ProgressLine(),
                    ),
                    GestureDetector(
                      onVerticalDragEnd: (d) {
                        if ((d.primaryVelocity ?? 0) < -200) {
                          openNowPlaying(context);
                        }
                      },
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          onTap: () => openNowPlaying(context),
                          borderRadius: BorderRadius.circular(Palette.r(16)),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 6, 6),
                            child: Row(
                              children: [
                                Hero(
                                  tag: nowPlayingArtTag,
                                  child: Artwork(art: track.art, size: 46),
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
                                IconButton(
                                  onPressed: player.previous,
                                  icon: const Icon(Icons.skip_previous_rounded),
                                  color: Palette.text,
                                  tooltip: 'Previous',
                                ),
                                const PlayPauseButton(size: 44),
                                IconButton(
                                  onPressed: player.hasNext
                                      ? player.next
                                      : null,
                                  icon: const Icon(Icons.skip_next_rounded),
                                  color: Palette.text,
                                  tooltip: 'Next',
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Divider(height: 1, color: Palette.outline),
                    ),
                  ],
                ),
        );
      },
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
            minHeight: 3,
            color: Palette.accent,
            backgroundColor: Palette.outline.withValues(alpha: 0.5),
          );
        },
      ),
    );
  }
}

/// The "Everywhere" sheet: every page, grouped, as the theme's tiles.
Future<void> showEverywhere(
  BuildContext context, {
  required List<(String, List<DockTab>)> groups,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Palette.surface,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Palette.r(24))),
      side: BorderSide(color: Palette.outline),
    ),
    builder: (sheet) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(sheet).height * 0.8,
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          16,
          10,
          16,
          16 + MediaQuery.paddingOf(sheet).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Palette.outline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            for (final (title, tabs) in groups)
              if (tabs.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
                  child: Text(
                    title.toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w600,
                      color: Palette.textMuted,
                    ),
                  ),
                ),
                GridView.count(
                  crossAxisCount: 4,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  childAspectRatio: 1.3,
                  children: [
                    for (final t in tabs)
                      _Tile(
                        tab: t,
                        onTap: () {
                          Navigator.pop(sheet);
                          t.open();
                        },
                      ),
                  ],
                ),
              ],
          ],
        ),
      ),
    ),
  );
}

class _Tile extends StatelessWidget {
  const _Tile({required this.tab, required this.onTap});

  final DockTab tab;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final selected = tab.shown();
    final radius = BorderRadius.circular(Palette.r(16));
    return Material(
      color: selected ? Palette.accentDeep : Palette.surfaceHigh,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: selected ? Palette.accentDeep : Palette.outline,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                selected ? tab.selected : tab.icon,
                size: 22,
                color: selected ? Palette.onAccent : Palette.accentLight,
              ),
              const SizedBox(height: 6),
              Text(
                tab.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: selected ? Palette.onAccent : Palette.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
