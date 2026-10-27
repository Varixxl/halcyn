import 'package:flutter/material.dart';

import '../state/updater.dart';
import '../theme.dart';
import 'widgets.dart';
import 'window_frame.dart';

/// Offers a new version when the daily check finds one, and a restart once it's
/// installed (desktop).
class UpdatePrompt extends StatefulWidget {
  const UpdatePrompt({super.key, required this.child});

  final Widget child;

  @override
  State<UpdatePrompt> createState() => _UpdatePromptState();
}

class _UpdatePromptState extends State<UpdatePrompt> {
  Updater? _updater;
  bool _showing = false;
  UpdateStage? _stage;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final updater = AppScope.of(context).updater;
    if (updater != _updater) {
      _updater?.removeListener(_update);
      _updater = updater..addListener(_update);
    }
  }

  @override
  void dispose() {
    _updater?.removeListener(_update);
    super.dispose();
  }

  void _update() {
    final updater = _updater!;
    final became = updater.stage != _stage ? updater.stage : null;
    _stage = updater.stage;
    final navigator = appNavigator.currentState;
    if (_showing || navigator == null) return;
    final release = updater.available;
    if (updater.offer && release != null && updater.unsupported == null) {
      updater.offer = false;
      _show(
        navigator,
        title: 'Halcyn ${release.version} is available',
        body: _notes(release.notes),
        later: updater.dismiss,
        action: 'Update',
        onAction: updater.install,
      );
    } else if (became == UpdateStage.ready) {
      _show(
        navigator,
        title: 'Halcyn ${release?.version ?? ''} is installed',
        body: 'Restart Halcyn to start using it. Your queue is kept.',
        later: () {},
        action: 'Restart now',
        onAction: () => restartForUpdate(context),
      );
    }
  }

  void _show(
    NavigatorState navigator, {
    required String title,
    required String body,
    required VoidCallback later,
    required String action,
    required VoidCallback onAction,
  }) {
    _showing = true;
    showDialog<bool>(
      context: navigator.context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.system_update_alt_rounded),
        title: Text(title),
        content: body.isEmpty
            ? null
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(child: Text(body)),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    ).then((go) {
      _showing = false;
      go == true ? onAction() : later();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Release notes without GitHub's "Full Changelog" link line.
String _notes(String notes) => notes
    .split('\n')
    .where((line) => !line.startsWith('**Full Changelog**'))
    .join('\n')
    .trim();

/// Saves the queue, then starts the new version.
Future<void> restartForUpdate(BuildContext context) {
  final scope = AppScope.of(context);
  return scope.updater.restart(beforeExit: scope.player.saveNow);
}

/// Settings: the version, checking, and installing updates.
class UpdateSettings extends StatelessWidget {
  const UpdateSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final updater = AppScope.of(context).updater;
    final muted = theme.textTheme.bodySmall?.copyWith(color: Palette.textMuted);
    return ListenableBuilder(
      listenable: updater,
      builder: (context, _) {
        final release = updater.available;
        final unsupported = updater.unsupported;
        final busy =
            updater.stage == UpdateStage.checking ||
            updater.stage == UpdateStage.downloading ||
            updater.stage == UpdateStage.installing;
        final status = switch (updater.stage) {
          UpdateStage.checking => 'Checking…',
          UpdateStage.upToDate => 'Up to date',
          UpdateStage.available when release != null =>
            'Halcyn ${release.version} is available'
                '${unsupported == null ? '' : '. $unsupported.'}',
          UpdateStage.downloading =>
            'Downloading ${release?.version ?? ''}… ${(updater.progress * 100).round()}%',
          UpdateStage.installing => 'Installing…',
          UpdateStage.ready => 'Installed. Restart Halcyn to finish.',
          _ =>
            updater.lastCheck == null
                ? 'Halcyn checks its GitHub releases for new versions'
                : 'Last checked ${_ago(updater.lastCheck!)}',
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
              child: Text('Updates', style: theme.textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Halcyn ${updater.current}',
                style: theme.textTheme.bodyLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
              child: Text(status, style: muted),
            ),
            if (updater.error case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 6, 24, 0),
                child: Text(
                  error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            if (updater.stage == UpdateStage.downloading)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
                child: LinearProgressIndicator(value: updater.progress),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  if (updater.stage == UpdateStage.ready)
                    FilledButton.icon(
                      onPressed: () => restartForUpdate(context),
                      icon: const Icon(Icons.restart_alt_rounded),
                      label: const Text('Restart now'),
                    )
                  else if (release != null && unsupported == null)
                    FilledButton.icon(
                      onPressed: busy ? null : updater.install,
                      icon: const Icon(Icons.system_update_alt_rounded),
                      label: Text('Update to ${release.version}'),
                    ),
                  OutlinedButton.icon(
                    onPressed: busy ? null : updater.check,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Check now'),
                  ),
                ],
              ),
            ),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              value: updater.auto,
              onChanged: updater.setAuto,
              title: const Text('Check for updates automatically'),
              subtitle: Text('Once a day, when Halcyn starts', style: muted),
            ),
          ],
        );
      },
    );
  }
}

String _ago(DateTime when) {
  final d = DateTime.now().difference(when);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} days ago';
}
