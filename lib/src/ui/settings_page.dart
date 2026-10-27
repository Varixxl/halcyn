import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'account.dart';
import 'cast.dart';
import 'plugin_view.dart';
import 'plugins_page.dart';
import 'streaming.dart';
import 'theme_picker.dart';
import 'updates.dart';
import 'widgets.dart';

/// Settings, in two tabs: everything else, and the themes.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Column(
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              dividerColor: Colors.transparent,
              tabs: [
                Tab(text: 'General'),
                Tab(text: 'Themes'),
              ],
            ),
          ),
        ),
        Expanded(
          child: TabBarView(
            children: [
              const _General(),
              ListView(
                padding: EdgeInsets.fromLTRB(
                  24,
                  16,
                  24,
                  24 + dockInset(context),
                ),
                children: const [ThemePicker()],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _General extends StatelessWidget {
  const _General();

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
            const AccountSettings(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
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
            const StreamingSettings(),
            const _SongDownloads(),
            const _DownloadSettings(),
            const _DiscordSettings(),
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

/// Where downloaded songs go, and how the downloading is going.
class _SongDownloads extends StatelessWidget {
  const _SongDownloads();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final downloads = AppScope.of(context).downloads;
    return ListenableBuilder(
      listenable: downloads,
      builder: (context, _) {
        final muted = theme.textTheme.bodySmall?.copyWith(
          color: Palette.textMuted,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
              child: Text('Downloads', style: theme.textTheme.titleMedium),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.download_for_offline_outlined),
              title: Text(downloads.folder),
              subtitle: const Text(
                'Streamed songs you download go here, in Artist and Album '
                'folders, from whichever linked service has them best',
              ),
              trailing: OutlinedButton(
                onPressed: downloads.busy
                    ? null
                    : () async {
                        final dir = await getDirectoryPath();
                        if (dir != null) await downloads.setFolder(dir);
                      },
                child: const Text('Change'),
              ),
            ),
            if (downloads.busy)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(
                      value: downloads.total == 0
                          ? null
                          : (downloads.done + downloads.failed) /
                                downloads.total,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Downloading ${downloads.current?.title ?? ''} '
                            '(${downloads.done + downloads.failed + 1} of '
                            '${downloads.total})',
                            style: muted,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: downloads.cancel,
                          child: const Text('Stop'),
                        ),
                      ],
                    ),
                  ],
                ),
              )
            else if (downloads.done + downloads.failed > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: Text(
                  [
                    'Downloaded ${downloads.done - downloads.skipped}',
                    if (downloads.skipped > 0)
                      '${downloads.skipped} already in your library',
                    if (downloads.failed > 0)
                      '${downloads.failed} failed (${downloads.lastError})',
                  ].join(' · '),
                  style: muted,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// What's playing on the user's Discord profile (see `DiscordPresence`).
class _DiscordSettings extends StatelessWidget {
  const _DiscordSettings();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final discord = AppScope.of(context).discord;
    return ListenableBuilder(
      listenable: discord,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
            child: Text('Discord', style: theme.textTheme.titleMedium),
          ),
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            title: const Text('Show what you\'re playing on Discord'),
            subtitle: Text(
              '${discord.local ? 'Through the Discord app on this computer, ' : ''}'
              'with the cover, a visualizer and a button for friends to get '
              'Halcyn. ${discord.status}',
            ),
            value: discord.on,
            onChanged: discord.setOn,
          ),
        ],
      ),
    );
  }
}

/// Downloading covers and lyrics the library is missing (see `Fetcher`).
class _DownloadSettings extends StatelessWidget {
  const _DownloadSettings();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fetcher = AppScope.of(context).fetcher;
    return ListenableBuilder(
      listenable: fetcher,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
            child: Text(
              'Cover art and lyrics',
              style: theme.textTheme.titleMedium,
            ),
          ),
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            title: const Text('Download missing cover art'),
            subtitle: const Text(
              'For albums without a cover, from MusicBrainz and the Cover Art '
              'Archive',
            ),
            value: fetcher.art,
            onChanged: fetcher.setArt,
          ),
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            title: const Text('Download missing lyrics'),
            subtitle: const Text(
              'For songs without a .lrc file, from LRCLIB, and for streamed songs '
              'as they play. Kept in Halcyn\'s own folder, not beside your music',
            ),
            value: fetcher.lyrics,
            onChanged: fetcher.setLyrics,
          ),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            title: const Text('Clear unused lyrics'),
            subtitle: const Text(
              'Deletes downloaded lyrics of songs not played or shown in the last '
              '7 days. Playing a song gets them again',
            ),
            trailing: OutlinedButton(
              onPressed: () async {
                final cleared = await fetcher.clearUnusedLyrics();
                if (!context.mounted) return;
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(
                    content: Text(
                      cleared == 0
                          ? 'No unused lyrics to clear'
                          : 'Cleared lyrics of $cleared '
                                '${cleared == 1 ? 'song' : 'songs'}',
                    ),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              child: const Text('Clear'),
            ),
          ),
          if (fetcher.status case final status?)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
              child: Text(
                status,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Palette.textMuted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
