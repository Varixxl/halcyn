import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Switches the desktop window between the full app and the phone-sized mini player.
///
/// On Hyprland the window is floated, sized and pinned through `hyprctl`, because a
/// tiled window ignores the size the app asks for. Elsewhere it asks the runner (see
/// linux/runner/my_application.cc and windows/runner/flutter_window.cpp).
class WindowController extends ChangeNotifier {
  static const miniSize = Size(400, 820);
  static const _channel = MethodChannel('halcyn/window');
  static const _margin = 24.0;

  /// The desktop runners implement the window channel; phones have no window to shrink.
  static bool get supported => Platform.isLinux || Platform.isWindows;

  bool mini = false;

  /// Pinned: stays above other windows (and, on Hyprland, on every workspace).
  bool pinned = true;

  bool _busy = false;
  // Where the window was before the mini player took over, to put it back.
  ({bool floating, List<num> at, List<num> size, int workspace})? _hyprBefore;
  Size? _gtkBefore;
  // Where the user left the mini player, so it comes back there.
  List<num>? _miniAt;

  static final _hyprland = Platform.environment.containsKey(
    'HYPRLAND_INSTANCE_SIGNATURE',
  );

  Future<void> setMini(bool value) async {
    if (!supported || value == mini || _busy) return;
    _busy = true;
    mini = value;
    notifyListeners();
    try {
      if (_hyprland && await _hyprSetMini(value)) return;
      await _gtkSetMini(value);
    } finally {
      _busy = false;
    }
  }

  Future<void> toggleMini() => setMini(!mini);

  Future<void> togglePin() async {
    pinned = !pinned;
    notifyListeners();
    if (!mini) return;
    if (_hyprland && _hyprBefore != null) {
      await _dispatch(
        "hl.dsp.window.pin({ action = '${pinned ? 'set' : 'unset'}', "
        "window = 'pid:$pid' })",
      );
    } else {
      await _channel.invokeMethod('setKeepAbove', pinned);
    }
  }

  // Hyprland ----------------------------------------------------------------------

  Future<bool> _hyprSetMini(bool value) async {
    final client = await _hyprClient();
    if (client == null) return false;
    final window = "window = 'pid:$pid'";

    if (value) {
      _hyprBefore = (
        floating: client['floating'] as bool,
        at: (client['at'] as List).cast<num>(),
        size: (client['size'] as List).cast<num>(),
        workspace: (client['workspace'] as Map)['id'] as int,
      );
      final (at, size) = await _miniPlacement(client);
      // Old (non-Lua) Hyprland configs answer anything but "ok"; fall back to GTK.
      if (!await _dispatch(
        "hl.dsp.window.float({ action = 'set', $window })",
      )) {
        _hyprBefore = null;
        return false;
      }
      await _dispatch(
        'hl.dsp.window.resize({ x = ${size.width.round()}, '
        'y = ${size.height.round()}, $window })',
      );
      await _dispatch(
        'hl.dsp.window.move({ x = ${at.dx.round()}, y = ${at.dy.round()}, $window })',
      );
      if (pinned) {
        await _dispatch("hl.dsp.window.pin({ action = 'set', $window })");
      }
      return true;
    }

    final before = _hyprBefore;
    if (before == null) return false;
    _hyprBefore = null;
    _miniAt = (client['at'] as List).cast<num>();
    if (client['pinned'] == true) {
      await _dispatch("hl.dsp.window.pin({ action = 'unset', $window })");
    }
    // A pinned window follows the user onto a scratchpad (a special workspace), and
    // unpinning leaves it there. Bring it back to a regular workspace and focus it,
    // which also puts the scratchpad away: one left open with nothing on it covers
    // the monitor and takes every click and key meant for the window under it.
    final returnTo = await _hyprRegularWorkspace(before.workspace);
    if (returnTo != null) {
      await _dispatch(
        "hl.dsp.window.move({ workspace = '$returnTo', follow = false, $window })",
      );
    }
    if (before.floating) {
      await _dispatch(
        'hl.dsp.window.resize({ x = ${before.size[0]}, y = ${before.size[1]}, $window })',
      );
      await _dispatch(
        'hl.dsp.window.move({ x = ${before.at[0]}, y = ${before.at[1]}, $window })',
      );
    } else {
      await _dispatch("hl.dsp.window.float({ action = 'unset', $window })");
    }
    if (returnTo != null) await _dispatch('hl.dsp.focus({ $window })');
    return true;
  }

  /// Where to put the window if it's on a special workspace now: the regular one it
  /// came from, else the one showing under the scratchpad on its monitor. Null when
  /// it's already on a regular workspace.
  Future<int?> _hyprRegularWorkspace(int before) async {
    final client = await _hyprClient();
    final now = (client?['workspace'] as Map?)?['id'] as int?;
    if (client == null || now == null || now > 0) return null;
    if (before > 0) return before;
    final monitors = await _hyprJson('monitors') ?? const [];
    final monitor = monitors
        .cast<Map<String, dynamic>>()
        .where((m) => m['id'] == client['monitor'])
        .firstOrNull;
    final active = (monitor?['activeWorkspace'] as Map?)?['id'] as int?;
    return active != null && active > 0 ? active : null;
  }

  /// The last spot the user left the mini player, or the right edge of the window's
  /// monitor, centred vertically. Never taller than the monitor's free height.
  Future<(Offset, Size)> _miniPlacement(Map<String, dynamic> client) async {
    final monitors = await _hyprJson('monitors') ?? const [];
    final monitor = monitors
        .cast<Map<String, dynamic>>()
        .where((m) => m['id'] == client['monitor'])
        .firstOrNull;
    if (monitor == null) {
      final at = _miniAt;
      return (
        at == null ? Offset.zero : Offset(at[0] * 1.0, at[1] * 1.0),
        miniSize,
      );
    }

    final scale = (monitor['scale'] as num).toDouble();
    final rotated = (monitor['transform'] as int) % 2 == 1;
    final w = (rotated ? monitor['height'] : monitor['width']) as int;
    final h = (rotated ? monitor['width'] : monitor['height']) as int;
    final width = w / scale, height = h / scale;
    final x = (monitor['x'] as num).toDouble(),
        y = (monitor['y'] as num).toDouble();
    final reserved = (monitor['reserved'] as List)
        .cast<num>(); // left, top, right, bottom
    final free = height - reserved[1] - reserved[3];
    final size = Size(
      miniSize.width,
      miniSize.height.clamp(320, free - 2 * _margin),
    );

    final saved = _miniAt;
    if (saved != null) return (Offset(saved[0] * 1.0, saved[1] * 1.0), size);
    return (
      Offset(
        x + width - reserved[2] - size.width - _margin,
        y + reserved[1] + (free - size.height) / 2,
      ),
      size,
    );
  }

  Future<Map<String, dynamic>?> _hyprClient() async {
    final clients = await _hyprJson('clients');
    return clients
        ?.cast<Map<String, dynamic>>()
        .where((c) => c['pid'] == pid)
        .firstOrNull;
  }

  Future<List<dynamic>?> _hyprJson(String what) async {
    try {
      final result = await Process.run('hyprctl', [what, '-j']);
      return jsonDecode(result.stdout as String) as List<dynamic>;
    } on Object {
      return null;
    }
  }

  Future<bool> _dispatch(String lua) async {
    try {
      final result = await Process.run('hyprctl', ['dispatch', lua]);
      return (result.stdout as String).trim() == 'ok';
    } on Object {
      return false;
    }
  }

  // The runner (GTK on other desktops, Win32) ---------------------------------------

  Future<void> _gtkSetMini(bool value) async {
    if (value) {
      final size = await _channel.invokeListMethod<int>('getSize');
      if (size != null) _gtkBefore = Size(size[0] * 1.0, size[1] * 1.0);
      await _channel.invokeMethod('resize', [
        miniSize.width.round(),
        miniSize.height.round(),
      ]);
      await _channel.invokeMethod('setKeepAbove', pinned);
    } else {
      await _channel.invokeMethod('setKeepAbove', false);
      final before = _gtkBefore ?? const Size(1280, 720);
      await _channel.invokeMethod('resize', [
        before.width.round(),
        before.height.round(),
      ]);
    }
  }
}
