import 'package:flutter/material.dart';

import '../theme.dart';
import 'places.dart';
import 'slate.dart';
import 'widgets.dart';

/// The phone layout's Playlists tab: smart playlists, then the user's.
class PlaylistsPage extends StatelessWidget {
  const PlaylistsPage({
    super.key,
    required this.onOpen,
    required this.onCreate,
  });

  final ValueChanged<Section> onOpen;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.library, scope.playlists]),
      builder: (context, _) => ListView(
        padding: EdgeInsets.fromLTRB(8, 0, 8, 24 + dockInset(context)),
        children: [
          const SectionLabel('Smart playlists'),
          for (final smart in SmartList.all)
            _tile(
              smart.icon,
              smart.name,
              '${smart.tracks(scope.library).length} songs · ${smart.rule}',
              () => onOpen(Section(smart.place)),
            ),
          SectionLabel(
            'Your playlists',
            trailing: TextButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('New'),
            ),
          ),
          for (final p in scope.playlists.playlists)
            _tile(
              p.source == null
                  ? Icons.queue_music_rounded
                  : Icons.description_outlined,
              p.name,
              p.source == null
                  ? '${p.paths.length} songs'
                  : '${p.paths.length} songs · from ${p.source!.split(RegExp(r'[/\\]')).last}',
              () => onOpen(Section(Place.playlist, p.id)),
            ),
          if (scope.playlists.playlists.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'None yet. Tap New, or long-press any song.',
                style: TextStyle(color: Palette.textMuted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tile(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) => ListTile(
    leading: Icon(icon, color: Palette.accentLight),
    title: Text(title),
    subtitle: Text(
      subtitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: Palette.textMuted),
    ),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Palette.r(16)),
    ),
    onTap: onTap,
  );
}
