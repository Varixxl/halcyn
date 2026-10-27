import 'package:flutter/material.dart';

import '../cast/receiver.dart';
import '../cast/sender.dart';
import '../theme.dart';
import 'slate.dart';
import 'widgets.dart';
import 'window_frame.dart';

/// Opens the device picker; while casting, shows where to.
class CastButton extends StatelessWidget {
  const CastButton({super.key, this.compact = false});

  /// Just the icon, even while casting.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cast = AppScope.of(context).cast;
    return ListenableBuilder(
      listenable: cast,
      builder: (context, _) {
        final device = cast.device;
        if (cast.connected && device != null && !compact) {
          return Pill(
            label: device.name,
            icon: Icons.cast_connected_rounded,
            selected: true,
            onPressed: () => openCast(context),
          );
        }
        return IconButton(
          onPressed: () => openCast(context),
          isSelected: cast.connected,
          icon: const Icon(Icons.cast_rounded),
          selectedIcon: Icon(
            Icons.cast_connected_rounded,
            color: Palette.accentLight,
          ),
          iconSize: 20,
          color: Palette.textMuted,
          tooltip: cast.connected && device != null
              ? 'Playing on ${device.name}'
              : 'Play on another device',
        );
      },
    );
  }
}

Future<void> openCast(BuildContext context) {
  final cast = AppScope.of(context).cast;
  if (!cast.connected) cast.search();
  return showDialog(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: Palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Palette.r(24)),
        side: BorderSide(color: Palette.outline),
      ),
      child: const SizedBox(width: 420, child: _CastPanel()),
    ),
  );
}

class _CastPanel extends StatefulWidget {
  const _CastPanel();

  @override
  State<_CastPanel> createState() => _CastPanelState();
}

class _CastPanelState extends State<_CastPanel> {
  final _address = TextEditingController();
  bool _typing = false;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cast = AppScope.of(context).cast;
    final muted = theme.textTheme.bodySmall?.copyWith(color: Palette.textMuted);
    return ListenableBuilder(
      listenable: cast,
      builder: (context, _) {
        final device = cast.device;
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 20, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  cast.connected && device != null
                      ? 'Playing on ${device.name}'
                      : 'Play on another device',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 8),
              if (cast.connected) ...[
                if (cast.waiting || cast.sending != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          cast.sending == null
                              ? 'Getting ready…'
                              : 'Sending “${cast.sending}”',
                          style: muted,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        LinearProgressIndicator(
                          value: cast.sending == null
                              ? null
                              : cast.sendProgress,
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: cast.toggleMute,
                        icon: Icon(
                          cast.volume == 0
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                        ),
                        color: Palette.textMuted,
                        tooltip: cast.volume == 0 ? 'Unmute' : 'Mute',
                      ),
                      Expanded(
                        child: Slider(
                          value: cast.volume,
                          onChanged: cast.setVolume,
                          semanticFormatterCallback: (v) =>
                              '${device?.name} volume ${(v * 100).round()}%',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                ListTile(
                  leading: const Icon(Icons.phone_android_rounded),
                  title: const Text('Play on this device'),
                  subtitle: Text(
                    'Stops casting; your queue here comes back',
                    style: muted,
                  ),
                  onTap: () {
                    cast.disconnect();
                    Navigator.of(context).pop();
                  },
                ),
              ] else ...[
                for (final d in cast.devices)
                  ListTile(
                    leading: const Icon(Icons.computer_rounded),
                    title: Text(d.name),
                    subtitle: Text(switch ((device == d, cast.status)) {
                      (true, CastStatus.connecting) => 'Connecting…',
                      (true, CastStatus.approving) =>
                        'Allow this device on ${d.name}',
                      _ when cast.found.contains(d) => d.host,
                      _ => 'Not found just now · ${d.host}',
                    }, style: muted),
                    trailing: device == d && cast.status != CastStatus.idle
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    onTap: () => cast.connect(d),
                  ),
                if (cast.searching)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: LinearProgressIndicator(),
                  )
                else if (cast.devices.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Text(
                      'No other Halcyn found. It needs to be open, with “Let other '
                      'devices play here” on in its Settings, on the same network.',
                      style: muted,
                    ),
                  ),
                if (cast.error case final error?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Text(
                      error,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                if (_typing)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: TextField(
                      controller: _address,
                      autofocus: true,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'Address',
                        hintText: '192.168.1.20',
                      ),
                      onSubmitted: cast.connectTo,
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: cast.searching ? null : cast.search,
                        child: const Text('Search again'),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _typing
                            ? () => cast.connectTo(_address.text)
                            : () => setState(() => _typing = true),
                        child: Text(_typing ? 'Connect' : 'Enter address'),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Asks whether a device may cast here, one at a time, as they ask.
class PairingPrompts extends StatefulWidget {
  const PairingPrompts({super.key, required this.child});

  final Widget child;

  @override
  State<PairingPrompts> createState() => _PairingPromptsState();
}

class _PairingPromptsState extends State<PairingPrompts> {
  CastReceiver? _receiver;
  (PairingRequest, DialogRoute<bool>)? _shown;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final receiver = AppScope.of(context).receiver;
    if (receiver != _receiver) {
      _receiver?.removeListener(_update);
      _receiver = receiver..addListener(_update);
    }
  }

  @override
  void dispose() {
    _receiver?.removeListener(_update);
    super.dispose();
  }

  void _update() {
    final requests = _receiver!.requests;
    if (_shown case (final request, final route)) {
      // The device gave up asking: take its prompt down.
      if (!requests.contains(request) && route.isActive) {
        route.navigator?.removeRoute(route);
        _shown = null;
        _update();
      }
      return;
    }
    final next = requests.firstOrNull;
    final navigator = appNavigator.currentState;
    if (next == null || navigator == null) return;
    final route = DialogRoute<bool>(
      context: navigator.context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.cast_rounded),
        title: Text('Let ${next.name} play here?'),
        content: const Text(
          'It will be able to play music on this computer and control what\'s '
          'playing. You can take this back in Settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Don\'t allow'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    _shown = (next, route);
    navigator.push(route).then((allow) {
      next.answer(allow ?? false);
      if (_shown?.$1 != next) return;
      _shown = null;
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _update());
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Settings: letting other devices play here, and which ones may.
class CastSettings extends StatelessWidget {
  const CastSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final receiver = AppScope.of(context).receiver;
    final muted = theme.textTheme.bodySmall?.copyWith(color: Palette.textMuted);
    return ListenableBuilder(
      listenable: receiver,
      builder: (context, _) {
        final connected = receiver.connected;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 4),
              child: Text('Casting', style: theme.textTheme.titleMedium),
            ),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              value: receiver.enabled,
              onChanged: receiver.setEnabled,
              title: const Text('Let other devices play here'),
              subtitle: Text(
                receiver.error ??
                    (!receiver.enabled
                        ? 'Your phone can play through this device and control it'
                        : connected.isNotEmpty
                        ? 'Playing from ${connected.join(', ')}'
                        : 'Shows up as “${receiver.name}”. If your phone can\'t find '
                              'it, allow UDP 47230 and TCP ${receiver.port ?? 47231} '
                              'in this device\'s firewall.'),
                style: muted,
              ),
            ),
            for (final d in receiver.devices)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: Icon(
                  connected.contains(d.name)
                      ? Icons.cast_connected_rounded
                      : Icons.phone_android_rounded,
                ),
                title: Text(d.name),
                subtitle: Text('Allowed', style: muted),
                trailing: IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Don\'t allow any more',
                  onPressed: () => receiver.forget(d.id),
                ),
              ),
          ],
        );
      },
    );
  }
}
