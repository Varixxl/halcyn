import 'package:flutter/material.dart';

import '../rust/api/player.dart';
import '../rust/api/library.dart';
import '../state/plugins.dart';
import '../signal_path_view.dart';
import '../theme.dart';
import '../window.dart';
import 'now_playing.dart';
import 'places.dart';
import 'player_bar.dart';
import 'playlist_import.dart';
import 'plugin_view.dart';
import 'slate.dart';
import 'widgets.dart';

/// The desktop sidebar: library sections, smart playlists, the user's playlists, and
/// the docked Now Playing card.
class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.section,
    required this.onSelect,
    required this.search,
  });

  static const width = 216.0;

  final Section section;
  final ValueChanged<Section> onSelect;

  /// The search across everything, above the library; null when a plugin hides it.
  final Widget? search;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: Palette.surface,
        border: Border(right: BorderSide(color: Palette.outline)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SizedBox(width: 12),
              const Expanded(child: Wordmark()),
              if (WindowController.supported) const MiniModeButton(),
              IconButton(
                onPressed: () => onSelect(const Section(Place.settings)),
                isSelected: section.place == Place.settings,
                icon: const Icon(Icons.settings_outlined),
                selectedIcon: const Icon(Icons.settings_rounded),
                iconSize: 20,
                color: Palette.textMuted,
                tooltip: 'Settings',
              ),
            ],
          ),
          const SizedBox(height: 10),
          ?search,
          Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge([
                scope.library,
                scope.playlists,
                scope.player,
                scope.plugins,
                scope.streaming,
              ]),
              builder: (context, _) {
                final plugins = scope.plugins;
                bool shown(String tab) => !plugins.isHidden(tab);
                String name(String tab, String label) =>
                    plugins.replacement(tab)?.title ?? label;
                final library = [
                  if (shown('songs'))
                    _item(
                      Place.songs,
                      name('songs', 'Songs'),
                      Icons.music_note_outlined,
                    ),
                  if (shown('albums'))
                    _item(
                      Place.albums,
                      name('albums', 'Albums'),
                      Icons.album_outlined,
                    ),
                  if (shown('artists'))
                    _item(
                      Place.artists,
                      name('artists', 'Artists'),
                      Icons.person_outline_rounded,
                    ),
                  if (shown('queue'))
                    _item(
                      Place.queue,
                      name('queue', 'Queue'),
                      Icons.queue_music_rounded,
                      count: scope.player.current == null
                          ? null
                          : scope.player.upNext.length,
                    ),
                  for (final t in plugins.tabs(TabPlace.library)) _tab(t),
                ];
                return ListView(
                  children: [
                    if (scope.streaming.linked)
                      _item(Place.home, 'Home', Icons.home_outlined),
                    for (final t in plugins.tabs(TabPlace.main)) _tab(t),
                    if (library.isNotEmpty) ...[
                      const SectionLabel('Library'),
                      ...library,
                    ],
                    if (shown('smartPlaylists')) ...[
                      const SectionLabel('Smart playlists'),
                      for (final smart in SmartList.all)
                        _item(
                          smart.place,
                          smart.name,
                          smart.icon,
                          count: smart.tracks(scope.library).length,
                        ),
                    ],
                    if (shown('playlists')) ...[
                      SectionLabel(
                        'Playlists',
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              onPressed: () => _import(context),
                              icon: const Icon(Icons.file_open_outlined),
                              iconSize: 18,
                              color: Palette.textMuted,
                              visualDensity: VisualDensity.compact,
                              tooltip: 'Import playlist file',
                            ),
                            IconButton(
                              onPressed: () => _create(context),
                              icon: const Icon(Icons.add_rounded),
                              iconSize: 18,
                              color: Palette.textMuted,
                              visualDensity: VisualDensity.compact,
                              tooltip: 'New playlist',
                            ),
                          ],
                        ),
                      ),
                      for (final p in scope.playlists.playlists)
                        SideItem(
                          label: p.name,
                          // Read from a playlist file in the music folders.
                          icon: p.source == null
                              ? Icons.playlist_play_rounded
                              : Icons.description_outlined,
                          count: p.paths.length,
                          selected: section == Section(Place.playlist, p.id),
                          onTap: () => onSelect(Section(Place.playlist, p.id)),
                        ),
                      if (scope.playlists.playlists.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                          child: Text(
                            'Make one with +, or from any song\'s menu.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Palette.textMuted,
                            ),
                          ),
                        ),
                    ],
                    const SectionLabel('Plugins'),
                    for (final t in plugins.tabs(TabPlace.sidebar)) _tab(t),
                    _item(Place.plugins, 'Manage plugins', Icons.tune_rounded),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _item(Place place, String label, IconData icon, {int? count}) =>
      SideItem(
        label: label,
        icon: icon,
        count: count,
        selected: section.place == place,
        onTap: () => onSelect(Section(place)),
      );

  Widget _tab(PluginPage t) => SideItem(
    label: t.title,
    icon: pluginIcon(t.icon),
    selected: section == Section(Place.pluginPage, t.key),
    onTap: () => onSelect(Section(Place.pluginPage, t.key)),
  );

  Future<void> _create(BuildContext context) async {
    final playlists = AppScope.of(context).playlists;
    final name = await askName(
      context,
      title: 'New playlist',
      action: 'Create',
    );
    if (name == null) return;
    final playlist = await playlists.create(name);
    onSelect(Section(Place.playlist, playlist.id));
  }

  Future<void> _import(BuildContext context) async {
    final playlist = await importPlaylistFile(context);
    if (playlist != null) onSelect(Section(Place.playlist, playlist.id));
  }
}

/// "halcyn" at the top of the sidebar. A rainbow sweeps through it when plugins load.
class Wordmark extends StatefulWidget {
  const Wordmark({super.key});

  @override
  State<Wordmark> createState() => _WordmarkState();
}

class _WordmarkState extends State<Wordmark>
    with SingleTickerProviderStateMixin {
  /// The last load flashed, across rebuilds of the sidebar (resizing to a phone and
  /// back shouldn't flash again).
  static int _shown = 0;

  late final _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  ValueNotifier<int>? _loaded;

  static const _rainbow = [
    Color(0xFFFF5F6D),
    Color(0xFFFFB347),
    Color(0xFFFFF275),
    Color(0xFF7CF29C),
    Color(0xFF5CC8FF),
    Color(0xFF9D7BFF),
    Color(0xFFFF6FD8),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final loaded = AppScope.of(context).plugins.loaded;
    if (loaded != _loaded) {
      _loaded?.removeListener(_check);
      _loaded = loaded..addListener(_check);
      // Plugins loaded before the sidebar was built (at startup).
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    }
  }

  void _check() {
    final loaded = _loaded!.value;
    if (!mounted || loaded <= _shown) return;
    _shown = loaded;
    if (MediaQuery.of(context).disableAnimations) return;
    _flash.forward(from: 0);
  }

  @override
  void dispose() {
    _loaded?.removeListener(_check);
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Text(
      'halcyn',
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: Palette.accentLight,
      ),
    );
    return AnimatedBuilder(
      animation: _flash,
      child: text,
      builder: (context, child) {
        final t = _flash.value;
        if (t == 0 || t == 1) return child!;
        // The rainbow slides across twice, then fades back into the accent.
        final fade = t < 0.75 ? 1.0 : (1 - t) / 0.25;
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) => LinearGradient(
            colors: [
              for (final c in [..._rainbow, ..._rainbow, _rainbow.first])
                Color.lerp(Palette.accentLight, c, fade)!,
            ],
            tileMode: TileMode.repeated,
            transform: _Slide(Curves.easeInOut.transform(t) * 2),
          ).createShader(Rect.fromLTWH(0, 0, bounds.width * 2, bounds.height)),
          child: child,
        );
      },
    );
  }
}

/// Moves a gradient along by `turns` of its width.
class _Slide extends GradientTransform {
  const _Slide(this.turns);
  final double turns;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(-bounds.width * turns, 0, 0);
}

/// The cover, title and signal of what's playing, floating at the bottom right of the
/// desktop window above the volume. Opens Now Playing; hides from its corner button or
/// the player bar's [NowPlayingCardButton].
class NowPlayingCard extends StatelessWidget {
  const NowPlayingCard({super.key});

  static const width = 200.0;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final player = scope.player;
    final shown = scope.themes.nowPlayingCard;
    return ListenableBuilder(
      listenable: Listenable.merge([player, shown]),
      builder: (context, _) {
        final track = player.current;
        return AnimatedSwitcher(
          duration: Motion.medium,
          switchInCurve: Motion.curve,
          switchOutCurve: Motion.curve,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween(begin: 0.9, end: 1.0).animate(animation),
              alignment: Alignment.bottomRight,
              child: child,
            ),
          ),
          child: track == null || !shown.value
              ? const SizedBox.shrink()
              : _card(context, track, player.signalPath, shown),
        );
      },
    );
  }

  Widget _card(
    BuildContext context,
    Track track,
    SignalPath? path,
    ValueNotifier<bool> shown,
  ) {
    final radius = BorderRadius.circular(Palette.r(16));
    return Material(
      color: Palette.surfaceHigh,
      elevation: 12,
      shadowColor: const Color(0xAA000000),
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: Palette.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        child: Stack(
          children: [
            InkWell(
              onTap: () => openNowPlaying(context),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: _contents(context, track, path),
              ),
            ),
            Positioned(
              top: 14,
              right: 14,
              child: Material(
                color: const Color(0x99000000),
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => shown.value = false,
                  child: const Tooltip(
                    message: 'Hide',
                    child: Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _contents(BuildContext context, Track track, SignalPath? path) =>
      LayoutBuilder(
        builder: (context, box) {
          // Short windows get a thumbnail, so the card covers less of the list.
          final big = MediaQuery.sizeOf(context).height >= 640;
          final titles = AnimatedSwitcher(
            duration: Motion.medium,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topLeft,
              children: [...previous, ?current],
            ),
            child: Column(
              key: ValueKey(track.id),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Palette.text,
                  ),
                ),
                Text(
                  track.artists.join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Palette.textMuted),
                ),
              ],
            ),
          );
          final art = Hero(
            tag: nowPlayingArtTag,
            child: Artwork(
              art: track.art,
              size: big ? box.maxWidth : 40,
              resolution: big ? ArtSize.medium : ArtSize.small,
              radius: big ? 12 : 8,
            ),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (big) ...[
                art,
                const SizedBox(height: 8),
                titles,
              ] else
                Row(
                  children: [
                    art,
                    const SizedBox(width: 10),
                    Expanded(child: titles),
                  ],
                ),
              const SizedBox(height: 6),
              RateChip(track: track, path: path),
            ],
          );
        },
      );
}

/// Room under the pages for the [NowPlayingCard] while it shows, through the bottom
/// padding [dockInset] reads, so their last rows can scroll clear of it.
class NowPlayingCardInset extends StatelessWidget {
  const NowPlayingCardInset({super.key, required this.child});

  final Widget child;

  // The card (cover, title, artist, signal) and its 12 px margin.
  static const height = 292.0;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final shown = scope.themes.nowPlayingCard;
    return ListenableBuilder(
      listenable: Listenable.merge([scope.player, shown]),
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final extra = scope.player.current != null && shown.value
            ? height
            : 0.0;
        return MediaQuery(
          data: media.copyWith(
            padding: media.padding.copyWith(
              bottom: media.padding.bottom + extra,
            ),
          ),
          child: child!,
        );
      },
      child: child,
    );
  }
}

/// Shows or hides the [NowPlayingCard].
class NowPlayingCardButton extends StatelessWidget {
  const NowPlayingCardButton({super.key});

  @override
  Widget build(BuildContext context) {
    final shown = AppScope.of(context).themes.nowPlayingCard;
    return ValueListenableBuilder(
      valueListenable: shown,
      builder: (context, on, _) => IconButton(
        onPressed: () => shown.value = !on,
        isSelected: on,
        icon: const Icon(Icons.image_outlined),
        selectedIcon: Icon(Icons.image_rounded, color: Palette.accentLight),
        iconSize: 20,
        color: Palette.textMuted,
        tooltip: on ? 'Hide the cover card' : 'Show the cover card',
      ),
    );
  }
}

/// "Bit-exact" in the accent, or "88.2 → 48" in warm when Halcyn resamples.
class RateChip extends StatelessWidget {
  const RateChip({super.key, required this.track, required this.path});

  final Track track;
  final SignalPath? path;

  @override
  Widget build(BuildContext context) {
    final path = this.path;
    String khz(int rate) {
      final k = rate / 1000;
      return k == k.roundToDouble() ? '${k.round()}' : '$k';
    }

    final (label, color) = switch (path) {
      null => (khz(track.sampleRate), Palette.textMuted),
      SignalPath(bitExact: true) => ('Bit-exact', Palette.accentLight),
      SignalPath(:final processing) when !processing.startsWith('Resampled') =>
        (signalLabel(path), Palette.warm),
      _ => (
        '${khz(track.sampleRate)} → ${RegExp(r'→ ([\d.]+)').firstMatch(path.processing)?[1] ?? '?'}',
        Palette.warm,
      ),
    };
    return AnimatedContainer(
      duration: Motion.medium,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Palette.r(12)),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
