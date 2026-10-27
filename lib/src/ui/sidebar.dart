import 'package:flutter/material.dart';

import '../rust/api/player.dart';
import '../rust/api/library.dart';
import '../signal_path_view.dart';
import '../theme.dart';
import '../window.dart';
import 'now_playing.dart';
import 'places.dart';
import 'player_bar.dart';
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

  /// The search across everything, above the library.
  final Widget search;

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
              Expanded(
                child: Text(
                  'halcyn',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    color: Palette.accentLight,
                  ),
                ),
              ),
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
          search,
          Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge([
                scope.library,
                scope.playlists,
                scope.player,
              ]),
              builder: (context, _) => ListView(
                children: [
                  const SectionLabel('Library'),
                  _item(Place.songs, 'Songs', Icons.music_note_outlined),
                  _item(Place.albums, 'Albums', Icons.album_outlined),
                  _item(Place.artists, 'Artists', Icons.person_outline_rounded),
                  _item(
                    Place.queue,
                    'Queue',
                    Icons.queue_music_rounded,
                    count: scope.player.current == null
                        ? null
                        : scope.player.upNext.length,
                  ),
                  const SectionLabel('Smart playlists'),
                  for (final smart in SmartList.all)
                    _item(
                      smart.place,
                      smart.name,
                      smart.icon,
                      count: smart.tracks(scope.library).length,
                    ),
                  SectionLabel(
                    'Playlists',
                    trailing: IconButton(
                      onPressed: () => _create(context),
                      icon: const Icon(Icons.add_rounded),
                      iconSize: 18,
                      color: Palette.textMuted,
                      visualDensity: VisualDensity.compact,
                      tooltip: 'New playlist',
                    ),
                  ),
                  for (final p in scope.playlists.playlists)
                    SideItem(
                      label: p.name,
                      icon: Icons.playlist_play_rounded,
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
              ),
            ),
          ),
          const SizedBox(height: 8),
          const NowPlayingCard(),
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
}

/// The cover, title and signal of what's playing, docked at the bottom of the sidebar.
/// Opens Now Playing.
class NowPlayingCard extends StatelessWidget {
  const NowPlayingCard({super.key});

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
          alignment: Alignment.bottomCenter,
          child: track == null
              ? const SizedBox(width: double.infinity)
              : _card(context, track, player.signalPath),
        );
      },
    );
  }

  Widget _card(BuildContext context, Track track, SignalPath? path) {
    final radius = BorderRadius.circular(Palette.r(16));
    return Material(
      color: Palette.surfaceHigh,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: Palette.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openNowPlaying(context),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: LayoutBuilder(
            builder: (context, box) {
              // Short windows trade the big cover for a thumbnail, keeping the
              // playlists in view.
              final big = MediaQuery.sizeOf(context).height >= 820;
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
          ),
        ),
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
