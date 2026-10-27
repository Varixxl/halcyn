import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/plugins.dart';
import '../theme.dart';
import 'plugin_view.dart';
import 'slate.dart';
import 'widgets.dart';

/// Installs, turns on and off, and removes plugins, and holds their buttons.
class PluginsPage extends StatelessWidget {
  const PluginsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plugins = AppScope.of(context).plugins;
    final muted = theme.textTheme.bodySmall?.copyWith(color: Palette.textMuted);
    return ListenableBuilder(
      listenable: plugins,
      builder: (context, _) => ListView(
        padding: EdgeInsets.fromLTRB(24, 4, 24, 24 + dockInset(context)),
        children: [
          Text(
            'Plugins add tabs, buttons, themes and shortcuts, and can change or '
            'replace Halcyn\'s own pages. Each one runs in a sandbox and only gets '
            'the permissions you allow when installing it.',
            style: muted,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => _fromFile(context),
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Install from file'),
              ),
              OutlinedButton.icon(
                onPressed: () => _fromLink(context),
                icon: const Icon(Icons.link_rounded),
                label: const Text('Install from link'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (plugins.plugins.isEmpty)
            Text(
              'No plugins yet. A plugin is one .js file; see docs/plugins.md in '
              'the Halcyn repository to write one.',
              style: muted,
            ),
          for (final plugin in plugins.plugins.values) ...[
            _PluginCard(plugin: plugin),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  Future<void> _fromFile(BuildContext context) async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Halcyn plugin',
          extensions: ['js'],
          mimeTypes: ['text/javascript', 'application/javascript'],
          uniformTypeIdentifiers: ['com.netscape.javascript-source'],
        ),
      ],
    );
    if (file == null || !context.mounted) return;
    try {
      final source = await file.readAsString();
      if (context.mounted) await installPlugin(context, source);
    } on Object catch (e) {
      if (context.mounted) _toast(context, 'Couldn\'t read that file: $e');
    }
  }

  Future<void> _fromLink(BuildContext context) async {
    final link = await askName(context, title: 'Plugin link', action: 'Get');
    final url = Uri.tryParse(link?.trim() ?? '');
    if (url == null || !url.hasScheme || !context.mounted) return;
    try {
      final source = await AppScope.of(context).plugins.download(url);
      if (context.mounted) await installPlugin(context, source);
    } on Object catch (e) {
      if (context.mounted) _toast(context, 'Couldn\'t get the plugin: $e');
    }
  }
}

/// Shows what the plugin is and what it may do, and installs it if the user agrees.
Future<void> installPlugin(BuildContext context, String source) async {
  final plugins = AppScope.of(context).plugins;
  final PluginManifest manifest;
  try {
    manifest = PluginManifest.parse(source);
  } on FormatException catch (e) {
    _toast(context, e.message);
    return;
  }
  if (plugins.incompatibility(manifest) case final reason?) {
    _toast(context, 'Can\'t install it: $reason');
    return;
  }
  final replacing = plugins.plugins[manifest.id]?.manifest;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) =>
        _InstallDialog(manifest: manifest, replacing: replacing),
  );
  if (ok != true || !context.mounted) return;
  try {
    final failure = await plugins.install(source);
    if (!context.mounted) return;
    _toast(
      context,
      failure == null
          ? '${manifest.name} is installed'
          : '${manifest.name} is installed but didn\'t start: $failure',
    );
  } on Object catch (e) {
    if (context.mounted) _toast(context, 'Couldn\'t install it: $e');
  }
}

class _InstallDialog extends StatelessWidget {
  const _InstallDialog({required this.manifest, this.replacing});

  final PluginManifest manifest;
  final PluginManifest? replacing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: Palette.textMuted);
    final by = manifest.author.isEmpty ? '' : ' · by ${manifest.author}';
    return AlertDialog(
      icon: const Icon(Icons.extension_outlined),
      title: Text('Install ${manifest.name}?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Version ${manifest.version}$by', style: muted),
              Text(
                'For ${manifest.platformNames}'
                '${manifest.minHalcyn == null ? '' : ' · Halcyn ${manifest.minHalcyn}+'}',
                style: muted,
              ),
              if (replacing case final old?)
                Text('Replaces version ${old.version}', style: muted),
              if (manifest.description.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(manifest.description),
              ],
              const SizedBox(height: 16),
              if (manifest.permissions.isEmpty)
                Text(
                  'It asks for no permissions: it can only add its own tabs, '
                  'buttons and settings and keep its own saved values.',
                  style: theme.textTheme.bodyMedium,
                )
              else ...[
                Text('It can:', style: theme.textTheme.titleSmall),
                for (final p in manifest.permissions)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(_icon(p), size: 20, color: Palette.accent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(p.label),
                              Text(p.detail, style: muted),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 16),
              Text('Only install plugins from people you trust.', style: muted),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(replacing == null ? 'Install' : 'Update'),
        ),
      ],
    );
  }
}

IconData _icon(PluginPermission p) => switch (p) {
  PluginPermission.library => Icons.library_music_outlined,
  PluginPermission.player => Icons.play_circle_outline_rounded,
  PluginPermission.interface => Icons.dashboard_customize_outlined,
  PluginPermission.files => Icons.folder_outlined,
  PluginPermission.network => Icons.public_rounded,
};

class _PluginCard extends StatelessWidget {
  const _PluginCard({required this.plugin});

  final InstalledPlugin plugin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plugins = AppScope.of(context).plugins;
    final m = plugin.manifest;
    final muted = theme.textTheme.bodySmall?.copyWith(color: Palette.textMuted);
    final errors = plugin.log.where((l) => l.error).length;
    // Material, not a coloured box, so the log's expanding tile shows its ripple.
    return Material(
      color: Palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Palette.r(16)),
        side: BorderSide(color: Palette.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.extension_outlined, color: Palette.textMuted),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.name, style: theme.textTheme.titleSmall),
                      Text(
                        [
                          m.version,
                          if (m.author.isNotEmpty) m.author,
                          m.platformNames,
                        ].join(' · '),
                        style: muted,
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: plugin.enabled,
                  onChanged: (on) => plugins.setEnabled(m.id, on),
                ),
                IconButton(
                  onPressed: () => _remove(context),
                  icon: const Icon(Icons.delete_outline_rounded),
                  tooltip: 'Remove',
                ),
              ],
            ),
            if (m.description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: Text(m.description),
              ),
            if (m.permissions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    for (final p in m.permissions)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_icon(p), size: 14, color: Palette.textMuted),
                          const SizedBox(width: 4),
                          Text(p.label, style: muted),
                        ],
                      ),
                  ],
                ),
              ),
            if (plugin.failure case final failure? when plugin.enabled)
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: Text(
                  failure,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            if (plugin.commands.isNotEmpty || plugin.tabs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final page in plugin.tabs)
                      Pill(
                        label: page.title,
                        icon: pluginIcon(page.icon),
                        onPressed: () => openPluginPage(context, page),
                      ),
                    for (final command in plugin.commands)
                      Pill(
                        label: command.title,
                        icon: command.icon == null
                            ? null
                            : pluginIcon(command.icon),
                        onPressed: () => runPluginAction(context, command),
                      ),
                  ],
                ),
              ),
            if (plugin.log.isNotEmpty)
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    'Log · ${plugin.log.length}'
                    '${errors == 0 ? '' : ' · $errors error${errors == 1 ? '' : 's'}'}',
                    style: muted,
                  ),
                  children: [
                    Container(
                      constraints: const BoxConstraints(maxHeight: 220),
                      alignment: Alignment.topLeft,
                      child: SingleChildScrollView(
                        reverse: true,
                        child: SelectableText(
                          plugin.log
                              .map(
                                (l) =>
                                    '${_time(l.at)} ${l.error ? '!' : ' '} ${l.text}',
                              )
                              .join('\n'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            color: Palette.textMuted,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _remove(BuildContext context) async {
    final plugins = AppScope.of(context).plugins;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${plugin.manifest.name}?'),
        content: const Text('Its tabs, buttons and saved values go too.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await plugins.remove(plugin.manifest.id);
  }
}

String _time(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
    '${t.second.toString().padLeft(2, '0')}';

/// Around the whole app: shows what plugins say with `halcyn.ui.notify`, opens their
/// dialogs, and hears their keyboard shortcuts.
class PluginHost extends StatefulWidget {
  const PluginHost({super.key, required this.navigator, required this.child});

  /// The app's navigator, which dialogs open on.
  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  @override
  State<PluginHost> createState() => _PluginHostState();
}

class _PluginHostState extends State<PluginHost> {
  StreamSubscription<String>? _notices;
  StreamSubscription<PluginPage?>? _dialogs;
  final _open = <PluginPage>[];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final plugins = AppScope.of(context).plugins;
    _notices ??= plugins.notices.stream.listen((message) {
      if (mounted) _toast(context, message);
    });
    _dialogs ??= plugins.dialogs.stream.listen(_dialog);
  }

  @override
  void dispose() {
    _notices?.cancel();
    _dialogs?.cancel();
    super.dispose();
  }

  Future<void> _dialog(PluginPage? page) async {
    final navigator = widget.navigator.currentState;
    if (navigator == null) return;
    if (page == null) {
      if (_open.isNotEmpty) navigator.pop();
      return;
    }
    final plugins = AppScope.of(context).plugins;
    _open.add(page);
    await showDialog<void>(
      context: navigator.context,
      builder: (context) => AlertDialog(
        title: page.title.isEmpty ? null : Text(page.title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
          child: SingleChildScrollView(
            child: PluginPageView(pageKey: page.key, embedded: true),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    _open.remove(page);
    plugins.dialogClosed(page);
  }

  @override
  Widget build(BuildContext context) {
    final plugins = AppScope.of(context).plugins;
    return ListenableBuilder(
      listenable: plugins,
      builder: (context, child) => CallbackShortcuts(
        bindings: {
          for (final s in plugins.shortcuts)
            ?parseShortcut(s.keys ?? ''): () => runPluginAction(context, s),
        },
        child: child!,
      ),
      child: widget.child,
    );
  }
}

/// "ctrl+shift+k", "alt+f5", "space": null if it isn't one.
SingleActivator? parseShortcut(String keys) {
  final parts = keys.toLowerCase().split('+').map((p) => p.trim()).toList();
  if (parts.isEmpty || parts.last.isEmpty) return null;
  var control = false, shift = false, alt = false, meta = false;
  for (final m in parts.sublist(0, parts.length - 1)) {
    switch (m) {
      case 'ctrl' || 'control':
        control = true;
      case 'shift':
        shift = true;
      case 'alt':
        alt = true;
      case 'meta' || 'super' || 'cmd' || 'win':
        meta = true;
      default:
        return null;
    }
  }
  final name = parts.last;
  final key = switch (name) {
    'space' => LogicalKeyboardKey.space,
    'enter' || 'return' => LogicalKeyboardKey.enter,
    'escape' || 'esc' => LogicalKeyboardKey.escape,
    'tab' => LogicalKeyboardKey.tab,
    'backspace' => LogicalKeyboardKey.backspace,
    'delete' => LogicalKeyboardKey.delete,
    'home' => LogicalKeyboardKey.home,
    'end' => LogicalKeyboardKey.end,
    'pageup' => LogicalKeyboardKey.pageUp,
    'pagedown' => LogicalKeyboardKey.pageDown,
    'left' => LogicalKeyboardKey.arrowLeft,
    'right' => LogicalKeyboardKey.arrowRight,
    'up' => LogicalKeyboardKey.arrowUp,
    'down' => LogicalKeyboardKey.arrowDown,
    final f when RegExp(r'^f([1-9]|1[0-2])$').hasMatch(f) => LogicalKeyboardKey(
      LogicalKeyboardKey.f1.keyId + int.parse(f.substring(1)) - 1,
    ),
    // A printable key's id is its character.
    final c when c.length == 1 => LogicalKeyboardKey(c.codeUnitAt(0)),
    _ => null,
  };
  if (key == null) return null;
  return SingleActivator(
    key,
    control: control,
    shift: shift,
    alt: alt,
    meta: meta,
  );
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        width: 360,
        duration: const Duration(seconds: 4),
      ),
    );
}
