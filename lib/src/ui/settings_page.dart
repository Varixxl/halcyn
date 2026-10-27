import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'cast.dart';
import 'plugin_view.dart';
import 'plugins_page.dart';
import 'theme_picker.dart';
import 'updates.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final library = AppScope.of(context).library;
    final plugins = AppScope.of(context).plugins;

    return ListenableBuilder(
      listenable: Listenable.merge([library, plugins]),
      builder: (context, _) {
        final scanning = library.scanning;
        return ListView(
          padding: EdgeInsets.only(bottom: 24 + dockInset(context)),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
              child: Text('Theme', style: theme.textTheme.titleMedium),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: ThemePicker(),
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: Text('Music folders', style: theme.textTheme.titleMedium),
            ),
            for (final folder in library.folders)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: const Icon(Icons.folder_outlined),
                title: Text(folder),
                trailing: IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Remove',
                  onPressed: () =>
                      library.setFolders([...library.folders]..remove(folder)),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      final dir = await getDirectoryPath();
                      if (dir != null && !library.folders.contains(dir)) {
                        await library.setFolders([...library.folders, dir]);
                      }
                    },
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add folder'),
                  ),
                  OutlinedButton.icon(
                    onPressed: scanning == null ? library.rescan : null,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Rescan'),
                  ),
                ],
              ),
            ),
            AnimatedSize(
              duration: Motion.medium,
              curve: Motion.curve,
              child: scanning == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LinearProgressIndicator(
                            value: scanning.total == 0
                                ? null
                                : scanning.done / scanning.total,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            scanning.total == 0
                                ? 'Looking for music…'
                                : 'Reading ${scanning.done} of ${scanning.total} files',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Palette.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            if (library.error case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: Text(
                  error,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
              child: Text('Library', style: theme.textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                '${library.tracks.length} songs · ${library.albums.length} albums · '
                '${library.artists.length} artists',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Palette.textMuted,
                ),
              ),
            ),
            const CastSettings(),
            // Plugins' own settings.
            for (final section in plugins.settingsSections) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
                child: Text(section.title, style: theme.textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: PluginPageView(
                  key: ValueKey(section.key),
                  pageKey: section.key,
                  embedded: true,
                ),
              ),
            ],
            // The sidebar has Plugins on a wide window; a phone reaches it here.
            if (MediaQuery.sizeOf(context).width < 720) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
                child: Text('Plugins', style: theme.textTheme.titleMedium),
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: const Icon(Icons.extension_outlined),
                title: const Text('Manage plugins'),
                trailing: const Icon(Icons.chevron_right_rounded),
                // Over the whole app, not under the Settings header.
                onTap: () => Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(
                    builder: (context) => Scaffold(
                      appBar: AppBar(title: const Text('Plugins')),
                      body: const PluginsPage(),
                    ),
                  ),
                ),
              ),
            ],
            const UpdateSettings(),
          ],
        );
      },
    );
  }
}
