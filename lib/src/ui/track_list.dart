import 'dart:math';

import 'package:flutter/material.dart';

import '../rust/api/library.dart';
import '../state/library.dart';
import '../state/sort.dart';
import '../theme.dart';
import 'places.dart';
import 'plugin_view.dart';
import 'slate.dart';
import 'widgets.dart';

/// Which columns a track list has room for.
class TrackColumns {
  const TrackColumns._(this.wide, this.album);

  factory TrackColumns.of(double width) =>
      TrackColumns._(width >= 640, width >= 1000);

  /// Number, artist and format columns; otherwise artist sits under the title.
  final bool wide;
  final bool album;
}

/// The column titles above a track list. With `sort`, the titles sort the list (again
/// to reverse) and a button at the end offers every order.
class TrackListHeader extends StatelessWidget {
  const TrackListHeader({
    super.key,
    required this.columns,
    this.sort,
    this.onSort,
    this.natural,
  });

  final TrackColumns columns;
  final TrackSort? sort;
  final ValueChanged<TrackSort>? onSort;

  /// The list's own order, e.g. "Playlist order"; null when it has none.
  final String? natural;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.55,
      color: Palette.textMuted,
    );
    Widget title(String text, TrackSortKey key, {bool right = false}) {
      final sort = this.sort;
      final onSort = this.onSort;
      if (sort == null || onSort == null) {
        return Text(
          text,
          style: style,
          textAlign: right ? TextAlign.right : null,
        );
      }
      final active = sort.key == key;
      final arrow = AnimatedOpacity(
        opacity: active ? 1 : 0,
        duration: Motion.fast,
        child: Icon(
          sort.descending && active
              ? Icons.arrow_downward_rounded
              : Icons.arrow_upward_rounded,
          size: 13,
          color: Palette.accentLight,
        ),
      );
      return Align(
        alignment: right ? Alignment.centerRight : Alignment.centerLeft,
        child: InkWell(
          onTap: () => onSort(sort.by(key)),
          borderRadius: BorderRadius.circular(Palette.r(6)),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (right) ...[arrow, const SizedBox(width: 2)],
                Flexible(
                  child: Text(
                    text,
                    overflow: TextOverflow.ellipsis,
                    style: active
                        ? style.copyWith(color: Palette.accentLight)
                        : style,
                  ),
                ),
                if (!right) ...[const SizedBox(width: 2), arrow],
              ],
            ),
          ),
        ),
      );
    }

    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: scope.plugins,
      builder: (context, _) {
        final showPlays = scope.plugins.showTrackPlays;
        return Container(
          height: 32,
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: Palette.outline)),
          ),
          child: Row(
            children: [
              if (columns.wide)
                SizedBox(width: 40, child: Text('#', style: style)),
              Expanded(flex: 18, child: title('TITLE', TrackSortKey.title)),
              if (columns.wide) ...[
                const SizedBox(width: 14),
                Expanded(flex: 15, child: title('ARTIST', TrackSortKey.artist)),
              ],
              if (columns.album) ...[
                const SizedBox(width: 14),
                Expanded(flex: 13, child: title('ALBUM', TrackSortKey.album)),
              ],
              if (columns.wide)
                SizedBox(
                  width: 78,
                  child: title('FORMAT', TrackSortKey.quality, right: true),
                ),
              if (showPlays)
                SizedBox(
                  width: 52,
                  child: title('PLAYS', TrackSortKey.plays, right: true),
                ),
              SizedBox(
                width: 54,
                child: title('TIME', TrackSortKey.duration, right: true),
              ),
              SizedBox(
                width: 48,
                child: sort != null && onSort != null
                    ? SortMenu(sort: sort!, onSort: onSort!, natural: natural)
                    : null,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Every order a track list can take, ticked, plus the direction.
class SortMenu extends StatelessWidget {
  const SortMenu({
    super.key,
    required this.sort,
    required this.onSort,
    this.natural,
  });

  final TrackSort sort;
  final ValueChanged<TrackSort> onSort;
  final String? natural;

  @override
  Widget build(BuildContext context) {
    PopupMenuItem<TrackSort> item(String label, TrackSort value, bool on) =>
        PopupMenuItem(
          value: value,
          height: 40,
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: on
                    ? Icon(
                        Icons.check_rounded,
                        size: 18,
                        color: Palette.accentLight,
                      )
                    : null,
              ),
              Text(label),
            ],
          ),
        );
    final key = sort.key;
    return PopupMenuButton<TrackSort>(
      tooltip: 'Sort',
      icon: Icon(
        Icons.sort_rounded,
        size: 18,
        color: key == null ? Palette.textMuted : Palette.accentLight,
      ),
      padding: EdgeInsets.zero,
      color: Palette.surfaceHigh,
      onSelected: onSort,
      itemBuilder: (_) => [
        if (natural case final natural?)
          item(natural, TrackSort(null, sort.descending), key == null),
        for (final k in TrackSortKey.values)
          item(k.label, key == k ? sort : TrackSort(k, k.descending), key == k),
        const PopupMenuDivider(),
        item(
          key == null ? 'In order' : _ascending(key),
          TrackSort(key, false),
          !sort.descending,
        ),
        item(
          key == null ? 'Reversed' : _descending(key),
          TrackSort(key, true),
          sort.descending,
        ),
      ],
    );
  }

  static String _ascending(TrackSortKey key) => switch (key) {
    TrackSortKey.title || TrackSortKey.artist || TrackSortKey.album => 'A to Z',
    TrackSortKey.added || TrackSortKey.year => 'Oldest first',
    TrackSortKey.duration => 'Shortest first',
    TrackSortKey.plays => 'Fewest plays first',
    TrackSortKey.quality => 'Lowest first',
  };

  static String _descending(TrackSortKey key) => switch (key) {
    TrackSortKey.title || TrackSortKey.artist || TrackSortKey.album => 'Z to A',
    TrackSortKey.added || TrackSortKey.year => 'Newest first',
    TrackSortKey.duration => 'Longest first',
    TrackSortKey.plays => 'Most played first',
    TrackSortKey.quality => 'Highest first',
  };
}

/// One 50 px row in a track list. Right-click (or the ⋯ button) opens its menu.
class TrackRow extends StatefulWidget {
  const TrackRow({
    super.key,
    required this.track,
    required this.number,
    required this.columns,
    required this.onTap,
    this.current,
    this.onRemove,
    this.removeLabel = 'Remove from playlist',
    this.reorderIndex,
  });

  static const height = 50.0;

  final Track track;
  final int number;
  final TrackColumns columns;
  final VoidCallback onTap;

  /// Whether this is the playing row; by default, any row of the playing track is.
  final bool? current;
  final VoidCallback? onRemove;
  final String removeLabel;

  /// Set in reorderable lists: dragging the number cell moves the row.
  final int? reorderIndex;

  @override
  State<TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends State<TrackRow> {
  bool _hover = false;

  void _menu(Offset at) => showTrackMenu(
    context,
    at,
    widget.track,
    onRemove: widget.onRemove,
    removeLabel: widget.removeLabel,
  );

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final player = scope.player;
    final plugins = scope.plugins;
    final library = scope.library;
    return ListenableBuilder(
      listenable: Listenable.merge([player, plugins, library]),
      builder: (context, _) {
        final current =
            widget.current ?? player.current?.path == widget.track.path;
        final showPlays = plugins.showTrackPlays;
        return MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onSecondaryTapUp: (d) => _menu(d.globalPosition),
            onLongPressStart: (d) => _menu(d.globalPosition),
            child: AnimatedContainer(
              duration: SlateMotion.select,
              curve: Motion.curve,
              decoration: BoxDecoration(
                color: current
                    ? Palette.accent.withValues(alpha: 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(Palette.r(16)),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: widget.onTap,
                  borderRadius: BorderRadius.circular(Palette.r(16)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: _row(
                      context,
                      current,
                      player.playing,
                      showPlays,
                      library,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _row(
    BuildContext context,
    bool current,
    bool playing,
    bool showPlays,
    LibraryController library,
  ) {
    final track = widget.track;
    final columns = widget.columns;
    final muted = TextStyle(fontSize: 13, color: Palette.textMuted);
    final title = Text(
      track.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 14,
        color: current ? Palette.accentLight : Palette.text,
        fontWeight: current ? FontWeight.w600 : FontWeight.w400,
      ),
    );
    final artists = Text(
      track.artists.join(', '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: muted,
    );

    Widget number = current
        ? Icon(
            playing ? Icons.graphic_eq_rounded : Icons.play_arrow_rounded,
            size: 18,
            color: Palette.accentLight,
          )
        : Text(
            '${widget.number}',
            style: muted.copyWith(
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          );
    if (widget.reorderIndex case final index?) {
      number = ReorderableDragStartListener(
        index: index,
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: _hover
              ? Icon(
                  Icons.drag_indicator_rounded,
                  size: 18,
                  color: Palette.textMuted,
                )
              : number,
        ),
      );
    }

    return Row(
      children: [
        if (columns.wide)
          SizedBox(
            width: 40,
            child: Align(alignment: Alignment.centerLeft, child: number),
          ),
        Expanded(
          flex: 18,
          child: columns.wide
              ? title
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [title, artists],
                ),
        ),
        if (columns.wide) ...[
          const SizedBox(width: 14),
          Expanded(flex: 15, child: artists),
        ],
        if (columns.album) ...[
          const SizedBox(width: 14),
          Expanded(
            flex: 13,
            child: Text(
              track.album ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
          ),
        ],
        if (columns.wide)
          SizedBox(
            width: 78,
            child: Align(
              alignment: Alignment.centerRight,
              child: QualityLabel(track: track),
            ),
          ),
        if (showPlays)
          SizedBox(
            width: 52,
            child: Text(
              formatPlays(library.plays(track)),
              textAlign: TextAlign.right,
              style: muted.copyWith(
                fontSize: 12,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        SizedBox(
          width: 54,
          child: Text(
            clock(track.durationSecs),
            textAlign: TextAlign.right,
            style: muted.copyWith(
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        SizedBox(
          width: 36,
          child: AnimatedOpacity(
            opacity: _hover ? 1 : 0,
            duration: SlateMotion.select,
            child: Builder(
              builder: (context) => IconButton(
                onPressed: () {
                  final box = context.findRenderObject()! as RenderBox;
                  _menu(box.localToGlobal(box.size.bottomLeft(Offset.zero)));
                },
                icon: const Icon(Icons.more_horiz_rounded),
                iconSize: 18,
                color: Palette.textMuted,
                tooltip: 'More',
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Play next, add to the queue or a playlist, and (when given) remove.
Future<void> showTrackMenu(
  BuildContext context,
  Offset at,
  Track track, {
  VoidCallback? onRemove,
  String removeLabel = 'Remove from playlist',
}) async {
  final scope = AppScope.of(context);
  final actions = scope.plugins.trackActions;
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  PopupMenuItem<String> item(String value, IconData icon, String label) =>
      PopupMenuItem(
        value: value,
        height: 40,
        child: Row(
          children: [
            Icon(icon, size: 18, color: Palette.textMuted),
            const SizedBox(width: 12),
            Text(label),
          ],
        ),
      );
  final choice = await showMenu<String>(
    context: context,
    color: Palette.surfaceHigh,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Palette.r(16)),
      side: BorderSide(color: Palette.outline),
    ),
    position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
    items: [
      item('next', Icons.playlist_play_rounded, 'Play next'),
      item('queue', Icons.queue_music_rounded, 'Add to queue'),
      item('playlist', Icons.playlist_add_rounded, 'Add to playlist…'),
      if (onRemove != null)
        item('remove', Icons.remove_circle_outline_rounded, removeLabel),
      for (final (i, action) in actions.indexed)
        item('plugin $i', Icons.extension_outlined, action.title),
    ],
  );
  if (!context.mounted) return;
  switch (choice) {
    case 'next':
      scope.player.playNext([track]);
      _toast(context, 'Playing next');
    case 'queue':
      scope.player.addToQueue([track]);
      _toast(context, 'Added to the queue');
    case 'playlist':
      await addToPlaylist(context, [track]);
    case 'remove':
      onRemove!();
    case final String c when c.startsWith('plugin '):
      await runPluginAction(context, actions[int.parse(c.substring(7))], track);
  }
}

/// Lets the user pick a playlist (or make one) and adds `tracks` to it.
Future<void> addToPlaylist(BuildContext context, List<Track> tracks) async {
  final playlists = AppScope.of(context).playlists;
  final paths = [for (final t in tracks) t.path];
  final picked = await showDialog<Object>(
    context: context,
    builder: (context) => SimpleDialog(
      backgroundColor: Palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Palette.r(24)),
        side: BorderSide(color: Palette.outline),
      ),
      title: const Text('Add to playlist'),
      children: [
        for (final p in playlists.playlists)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(p),
            child: Row(
              children: [
                Icon(
                  Icons.queue_music_rounded,
                  size: 18,
                  color: Palette.textMuted,
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(p.name)),
                Text(
                  '${p.paths.length}',
                  style: TextStyle(color: Palette.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(#create),
          child: Row(
            children: [
              Icon(Icons.add_rounded, size: 18, color: Palette.accent),
              const SizedBox(width: 12),
              Text('New playlist…', style: TextStyle(color: Palette.accent)),
            ],
          ),
        ),
      ],
    ),
  );
  if (!context.mounted || picked == null) return;
  if (picked == #create) {
    final name = await askName(
      context,
      title: 'New playlist',
      action: 'Create',
    );
    if (name == null) return;
    await playlists.create(name, paths);
    if (context.mounted) _toast(context, 'Added to $name');
  } else if (picked is Playlist) {
    playlists.add(picked, paths);
    _toast(context, 'Added to ${picked.name}');
  }
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        width: 280,
        duration: const Duration(seconds: 2),
      ),
    );
}

/// Title, a line of facts, and Play / Shuffle, above a track list.
class CollectionHeader extends StatelessWidget {
  const CollectionHeader({
    super.key,
    required this.title,
    required this.tracks,
    this.icon,
    this.subtitle,
    this.menu,
  });

  final String title;
  final List<Track> tracks;
  final IconData? icon;
  final String? subtitle;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    final theme = Theme.of(context);
    final length = tracks.fold<double>(0, (sum, t) => sum + t.durationSecs);
    final facts = [
      '${tracks.length} ${tracks.length == 1 ? 'song' : 'songs'}',
      if (tracks.isNotEmpty) longDuration(length),
      ?subtitle,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
      child: Row(
        children: [
          if (icon != null) ...[
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Palette.surfaceHigh,
                borderRadius: BorderRadius.circular(Palette.r(16)),
                border: Border.all(color: Palette.outline),
              ),
              child: Icon(icon, color: Palette.accentLight),
            ),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  facts,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: Palette.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: tracks.isEmpty
                ? null
                : () => player.playTracks(
                    tracks,
                    player.shuffle ? Random().nextInt(tracks.length) : 0,
                  ),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Play'),
            style: FilledButton.styleFrom(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Palette.r(16)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Pill(
            label: 'Shuffle',
            icon: Icons.shuffle_rounded,
            onPressed: tracks.isEmpty
                ? null
                : () {
                    if (!player.shuffle) player.toggleShuffle();
                    player.playTracks(tracks, Random().nextInt(tracks.length));
                  },
          ),
          ?menu,
        ],
      ),
    );
  }
}

/// A smart playlist or one of the user's: header, column titles and the songs. The
/// user's can be reordered by dragging the number, and songs removed from the menu.
class CollectionPage extends StatelessWidget {
  const CollectionPage({
    super.key,
    required this.section,
    required this.query,
    required this.onDeleted,
  });

  final Section section;
  final String query;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        scope.library,
        scope.playlists,
        scope.sort,
      ]),
      builder: (context, _) {
        if (section.place == Place.playlist) {
          final playlist = scope.playlists.byId(section.playlist!);
          if (playlist == null) return const SizedBox.shrink();
          return _playlist(context, playlist);
        }
        final smart = SmartList.of(section.place);
        final tracks = smart.tracks(scope.library);
        return _page(
          context,
          entries: [...tracks.indexed],
          header: CollectionHeader(
            title: smart.name,
            icon: smart.icon,
            subtitle: smart.rule,
            tracks: tracks,
          ),
          tracks: tracks,
          list: section.place.name,
          natural: smart.order,
          empty: switch (section.place) {
            Place.mostPlayed || Place.recentlyPlayed => 'Nothing yet. Songs show up here once you\'ve heard half of them.',
            Place.forgotten => 'Nothing yet. Songs you loved but haven\'t played in a month land here.',
            Place.neverPlayed => 'You\'ve heard everything. Nice.',
            _ => 'Nothing here.',
          },
        );
      },
    );
  }

  Widget _playlist(BuildContext context, Playlist playlist) {
    final scope = AppScope.of(context);
    // (position in the playlist, track) for the songs still in the library.
    final entries = [
      for (final (i, path) in playlist.paths.indexed)
        if (scope.library.byPath(path) case final track?) (i, track),
    ];
    final tracks = [for (final (_, t) in entries) t];
    return _page(
      context,
      entries: entries,
      header: CollectionHeader(
        title: playlist.name,
        icon: Icons.queue_music_rounded,
        tracks: tracks,
        subtitle: entries.length < playlist.paths.length
            ? '${playlist.paths.length - entries.length} missing'
            : null,
        menu: PopupMenuButton<String>(
          tooltip: 'Playlist options',
          icon: Icon(Icons.more_vert_rounded, color: Palette.textMuted),
          color: Palette.surfaceHigh,
          onSelected: (choice) async {
            if (choice == 'rename') {
              final name = await askName(
                context,
                title: 'Rename playlist',
                action: 'Rename',
                initial: playlist.name,
              );
              if (name != null) scope.playlists.rename(playlist, name);
            } else if (choice == 'delete') {
              final ok = await confirm(
                context,
                title: 'Delete "${playlist.name}"?',
                message: 'The songs stay in your library.',
                action: 'Delete',
              );
              if (ok) {
                onDeleted();
                scope.playlists.delete(playlist);
              }
            } else if (choice == 'download') {
              scope.downloads.add(tracks);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'rename', child: Text('Rename…')),
            if (tracks.any((t) => isStream(t.path)))
              const PopupMenuItem(
                value: 'download',
                child: Text('Download streamed songs'),
              ),
            const PopupMenuItem(value: 'delete', child: Text('Delete…')),
          ],
        ),
      ),
      tracks: tracks,
      list: 'playlist:${playlist.id}',
      natural: 'Playlist order',
      playlist: playlist,
      reorderable: entries.length == playlist.paths.length,
      empty: 'Empty for now. Right-click any song and choose Add to playlist.',
    );
  }

  /// `entries` pairs each track with its position in the playlist, so removing works on
  /// a sorted or filtered view too. `list` names it for its saved sort order.
  Widget _page(
    BuildContext context, {
    required Widget header,
    required List<(int, Track)> entries,
    required List<Track> tracks,
    required String empty,
    required String list,
    required String natural,
    Playlist? playlist,
    bool reorderable = false,
  }) {
    final scope = AppScope.of(context);
    final sort = scope.sort.tracks(list);
    final sorted = sort.applyTo(entries, (e) => e.$2, scope.library.plays);
    final queue = [for (final (_, t) in sorted) t];
    final rows = [
      for (final (n, (i, t)) in sorted.indexed)
        if (matches(t, query)) (n, i, t),
    ];
    // Dragging only makes sense in the playlist's own order.
    reorderable = reorderable && query.isEmpty && sort == const TrackSort();
    return LayoutBuilder(
      builder: (context, box) {
        final columns = TrackColumns.of(box.maxWidth);
        Widget row(int n) {
          final (at, i, track) = rows[n];
          return TrackRow(
            key: ValueKey((i, track.path)),
            track: track,
            number: n + 1,
            columns: columns,
            onTap: () => scope.player.playTracks(queue, at),
            onRemove: playlist == null
                ? null
                : () => scope.playlists.removeAt(playlist, i),
            reorderIndex: reorderable ? n : null,
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            TrackListHeader(
              columns: columns,
              sort: sort,
              onSort: (sort) => scope.sort.setTracks(list, sort),
              natural: natural,
            ),
            Expanded(
              child: rows.isEmpty
                  ? EmptyState(
                      icon: Icons.queue_music_rounded,
                      message: query.isEmpty
                          ? empty
                          : 'Nothing matches "$query".',
                    )
                  : reorderable
                  ? ReorderableListView.builder(
                      padding: EdgeInsets.only(
                        top: 4,
                        bottom: 24 + dockInset(context),
                      ),
                      buildDefaultDragHandles: false,
                      itemExtent: TrackRow.height,
                      itemCount: rows.length,
                      onReorderItem: (from, to) =>
                          scope.playlists.move(playlist!, from, to),
                      itemBuilder: (context, n) => row(n),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.only(
                        top: 4,
                        bottom: 24 + dockInset(context),
                      ),
                      itemExtent: TrackRow.height,
                      itemCount: rows.length,
                      itemBuilder: (context, n) => row(n),
                    ),
            ),
          ],
        );
      },
    );
  }
}
