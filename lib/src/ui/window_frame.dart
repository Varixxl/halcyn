import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../window.dart';
import 'mini_mode.dart';
import 'widgets.dart';

/// The app's navigator, for closing the top page from the shortcuts above it.
final appNavigator = GlobalKey<NavigatorState>();

/// Above every page: the player's keyboard shortcuts, and the swap between the full app
/// and the mini player. The full app stays alive offstage while the mini player shows,
/// so it comes back exactly as it was left.
class WindowFrame extends StatefulWidget {
  const WindowFrame({super.key, required this.child});

  final Widget child;

  @override
  State<WindowFrame> createState() => _WindowFrameState();
}

class _WindowFrameState extends State<WindowFrame> {
  final _miniFocus = FocusNode(debugLabel: 'mini player');
  final _frameFocus = FocusNode(debugLabel: 'window frame');
  WindowController? _window;
  bool _mini = false;
  // What had focus in the full app, given back when the mini player closes.
  FocusNode? _fullFocus;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_rescueFocus);
  }

  /// Focus sometimes falls back to the root scope (when a focused widget goes away), where
  /// no shortcut hears the keys. Take it back, so Space, Esc and the rest keep working.
  void _rescueFocus() {
    bool lost() {
      final focus = FocusManager.instance.primaryFocus;
      return focus == null || focus == FocusManager.instance.rootScope;
    }

    if (!lost()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && lost()) (_mini ? _miniFocus : _frameFocus).requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final window = AppScope.of(context).window;
    if (window != _window) {
      _window?.removeListener(_sync);
      _window = window..addListener(_sync);
    }
  }

  void _sync() {
    final mini = _window!.mini;
    if (mini == _mini) return;
    if (mini) _fullFocus = FocusManager.instance.primaryFocus;
    setState(() => _mini = mini);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (mini) {
        _miniFocus.requestFocus();
      } else if (_fullFocus case final focus? when focus.context != null) {
        focus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _window?.removeListener(_sync);
    FocusManager.instance.removeListener(_rescueFocus);
    _miniFocus.dispose();
    _frameFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final player = scope.player;
    final window = scope.window;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.space): _Toggle(),
        SingleActivator(LogicalKeyboardKey.arrowRight, control: true): _Next(),
        SingleActivator(LogicalKeyboardKey.arrowLeft, control: true):
            _Previous(),
        SingleActivator(LogicalKeyboardKey.keyM, control: true): _Mini(),
        SingleActivator(LogicalKeyboardKey.escape): _Escape(),
      },
      child: Actions(
        actions: {
          _Toggle: _PlayerKey<_Toggle>(player.toggle),
          _Next: _PlayerKey<_Next>(player.next),
          _Previous: _PlayerKey<_Previous>(player.previous),
          _Mini: _PlayerKey<_Mini>(
            window.toggleMini,
            enabled: () => WindowController.supported,
          ),
          // Esc leaves the mini player, or closes the top page (Now Playing, a
          // dialog); on the main page it falls through.
          _Escape: _PlayerKey<_Escape>(
            () => window.mini
                ? window.setMini(false)
                : appNavigator.currentState?.maybePop(),
            enabled: () =>
                window.mini || (appNavigator.currentState?.canPop() ?? false),
          ),
        },
        child: Focus(
          focusNode: _frameFocus,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const VelvetBackground(),
              Offstage(
                offstage: _mini,
                child: TickerMode(enabled: !_mini, child: widget.child),
              ),
              if (_mini)
                Focus(
                  focusNode: _miniFocus,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: Motion.medium,
                    curve: Motion.curve,
                    builder: (context, t, child) =>
                        Opacity(opacity: t, child: child),
                    // Its own navigator, so tooltips and menus have an overlay. The
                    // full app's navigator owns the hero animations.
                    child: HeroControllerScope.none(
                      child: Navigator(
                        onGenerateRoute: (_) => PageRouteBuilder(
                          pageBuilder: (_, _, _) => const MiniModeView(),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Toggle extends Intent {
  const _Toggle();
}

class _Next extends Intent {
  const _Next();
}

class _Previous extends Intent {
  const _Previous();
}

class _Mini extends Intent {
  const _Mini();
}

class _Escape extends Intent {
  const _Escape();
}

/// A player shortcut that steps aside while a text field has focus, so typing a space
/// (or moving by word with Ctrl+arrows) in the search box still works.
class _PlayerKey<T extends Intent> extends Action<T> {
  _PlayerKey(this.run, {this.enabled});

  final VoidCallback run;
  final bool Function()? enabled;

  @override
  bool isEnabled(T intent) {
    if (enabled?.call() == false) return false;
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused == null ||
        focused.findAncestorWidgetOfExactType<EditableText>() == null;
  }

  @override
  Object? invoke(T intent) {
    run();
    return null;
  }
}
