import 'dart:io';

import 'package:flutter/material.dart';

import '../rust/api/library.dart';
import '../state/plugins.dart';
import '../theme.dart';
import 'slate.dart';
import 'widgets.dart';

/// The icons a plugin can name (see docs/plugins.md); anything else is a puzzle piece.
const pluginIcons = <String, IconData>{
  'extension': Icons.extension_outlined,
  'music': Icons.music_note_outlined,
  'album': Icons.album_outlined,
  'artist': Icons.person_outline_rounded,
  'playlist': Icons.queue_music_rounded,
  'library': Icons.library_music_outlined,
  'play': Icons.play_arrow_rounded,
  'pause': Icons.pause_rounded,
  'next': Icons.skip_next_rounded,
  'previous': Icons.skip_previous_rounded,
  'shuffle': Icons.shuffle_rounded,
  'repeat': Icons.repeat_rounded,
  'volume': Icons.volume_up_rounded,
  'lyrics': Icons.lyrics_outlined,
  'radio': Icons.radio_outlined,
  'mic': Icons.mic_none_rounded,
  'headphones': Icons.headphones_outlined,
  'speaker': Icons.speaker_outlined,
  'equalizer': Icons.equalizer_rounded,
  'waves': Icons.graphic_eq_rounded,
  'heart': Icons.favorite_border_rounded,
  'heartFilled': Icons.favorite_rounded,
  'star': Icons.star_border_rounded,
  'starFilled': Icons.star_rounded,
  'thumbUp': Icons.thumb_up_outlined,
  'thumbDown': Icons.thumb_down_outlined,
  'history': Icons.history_rounded,
  'clock': Icons.schedule_rounded,
  'timer': Icons.timer_outlined,
  'alarm': Icons.alarm_rounded,
  'calendar': Icons.calendar_today_outlined,
  'chart': Icons.bar_chart_rounded,
  'trending': Icons.trending_up_rounded,
  'explore': Icons.explore_outlined,
  'search': Icons.search_rounded,
  'filter': Icons.filter_list_rounded,
  'sort': Icons.sort_rounded,
  'tag': Icons.sell_outlined,
  'edit': Icons.edit_outlined,
  'add': Icons.add_rounded,
  'remove': Icons.remove_rounded,
  'delete': Icons.delete_outline_rounded,
  'close': Icons.close_rounded,
  'check': Icons.check_rounded,
  'refresh': Icons.refresh_rounded,
  'download': Icons.download_rounded,
  'upload': Icons.upload_rounded,
  'share': Icons.share_outlined,
  'link': Icons.link_rounded,
  'cloud': Icons.cloud_outlined,
  'folder': Icons.folder_outlined,
  'file': Icons.description_outlined,
  'image': Icons.image_outlined,
  'settings': Icons.settings_outlined,
  'tune': Icons.tune_rounded,
  'info': Icons.info_outline_rounded,
  'warning': Icons.warning_amber_rounded,
  'error': Icons.error_outline_rounded,
  'help': Icons.help_outline_rounded,
  'home': Icons.home_outlined,
  'sparkle': Icons.auto_awesome_outlined,
  'bolt': Icons.bolt_rounded,
  'moon': Icons.dark_mode_outlined,
  'sun': Icons.light_mode_outlined,
  'palette': Icons.palette_outlined,
  'keyboard': Icons.keyboard_outlined,
  'bell': Icons.notifications_none_rounded,
  'chat': Icons.chat_bubble_outline_rounded,
  'person': Icons.person_outline_rounded,
  'people': Icons.people_outline_rounded,
  'globe': Icons.public_rounded,
  'lock': Icons.lock_outline_rounded,
  'eye': Icons.visibility_outlined,
  'more': Icons.more_horiz_rounded,
  'menu': Icons.menu_rounded,
  'arrowBack': Icons.arrow_back_rounded,
  'arrowForward': Icons.arrow_forward_rounded,
  'open': Icons.open_in_new_rounded,
};

IconData pluginIcon(String? name) =>
    pluginIcons[name] ?? Icons.extension_outlined;

int? _handler(Object? value) => switch (value) {
  {'handler': final num n} => n.toInt(),
  _ => null,
};

/// Renders a plugin's page: the blocks its `render` returns, again whenever it calls
/// `halcyn.ui.refresh()` and after the user presses or changes something on it. What
/// was shown stays while it renders again, so text being typed isn't lost.
class PluginPageView extends StatefulWidget {
  const PluginPageView({
    super.key,
    required this.pageKey,
    this.embedded = false,
  });

  final int pageKey;

  /// Inside another list (Settings, a dialog): no scrolling or padding of its own.
  final bool embedded;

  @override
  State<PluginPageView> createState() => _PluginPageViewState();
}

class _PluginPageViewState extends State<PluginPageView> {
  PluginManager? _plugins;
  List<Object?>? _blocks;
  Object? _error;
  PluginPage? _page;
  int _rendering = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final plugins = AppScope.of(context).plugins;
    if (plugins != _plugins) {
      _plugins?.removeListener(_changed);
      _plugins?.refreshes.removeListener(_render);
      _plugins = plugins
        ..addListener(_changed)
        ..refreshes.addListener(_render);
      _changed();
    }
  }

  @override
  void didUpdateWidget(PluginPageView old) {
    super.didUpdateWidget(old);
    if (old.pageKey != widget.pageKey) {
      _page = null;
      _blocks = null;
      _changed();
    }
  }

  @override
  void dispose() {
    _plugins?.removeListener(_changed);
    _plugins?.refreshes.removeListener(_render);
    super.dispose();
  }

  /// The page came or went (its plugin started or stopped).
  void _changed() {
    final page = _plugins!.page(widget.pageKey);
    if (page == _page) return;
    setState(() => _page = page);
    if (page != null) _render();
  }

  Future<void> _render() async {
    final page = _page;
    if (page == null || !mounted) return;
    final turn = ++_rendering;
    try {
      final value = await _plugins!.invoke(page.plugin, page.handler);
      if (!mounted || turn != _rendering) return;
      setState(() {
        _error = null;
        _blocks = switch (value) {
          final List<Object?> list => list,
          {'blocks': final List<Object?> list} => list,
          _ => const [],
        };
      });
    } on Object catch (e) {
      if (mounted && turn == _rendering) setState(() => _error = e);
    }
  }

  /// Runs one of the page's callbacks, then renders the page again.
  Future<void> _run(
    int handler, [
    Object? argument,
    bool rerender = true,
  ]) async {
    final page = _page;
    if (page == null) return;
    try {
      await _plugins!.invoke(page.plugin, handler, argument);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text('${page.title}: $e'),
            behavior: SnackBarBehavior.floating,
            width: 360,
          ),
        );
      }
    }
    if (rerender) await _render();
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    final Widget body;
    if (page == null) {
      body = const EmptyState(
        icon: Icons.extension_off_outlined,
        message: 'This plugin isn\'t running.',
      );
    } else if (_error case final error? when _blocks == null) {
      body = EmptyState(icon: Icons.error_outline_rounded, message: '$error');
    } else if (_blocks case final blocks?) {
      final children = [
        for (final (i, b) in blocks.indexed)
          if (b is Map<String, Object?>)
            _Block(key: ValueKey(b['id'] ?? i), block: b, run: _run),
      ];
      body = widget.embedded
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: children,
            )
          : ListView(
              padding: EdgeInsets.fromLTRB(24, 8, 24, 24 + dockInset(context)),
              children: children,
            );
    } else {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      );
    }
    return body;
  }
}

typedef _Run = Future<void> Function(
  int handler, [
  Object? argument,
  bool rerender,
]);

/// One block of a plugin page. See docs/plugins.md for what each takes.
class _Block extends StatelessWidget {
  const _Block({super.key, required this.block, required this.run});

  final Map<String, Object?> block;
  final _Run run;

  String _text(String key) => '${block[key] ?? ''}';
  double? _number(String key) => (block[key] as num?)?.toDouble();

  List<Widget> _children() => [
    for (final (i, b) in ((block['children'] as List?) ?? const []).indexed)
      if (b is Map<String, Object?>)
        _flex(b, _Block(key: ValueKey(b['id'] ?? i), block: b, run: run)),
  ];

  /// In a row, a child with `flex` takes that share of the room left.
  Widget _flex(Map<String, Object?> b, Widget child) =>
      block['type'] == 'row' && b['flex'] is num
      ? Expanded(flex: (b['flex'] as num).toInt().clamp(1, 100), child: child)
      : child;

  VoidCallback? _press(String key) {
    final h = _handler(block[key]);
    return h == null ? null : () => run(h);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = AppScope.of(context);
    final muted = TextStyle(color: Palette.textMuted);
    final gap = _number('gap') ?? 8;

    switch (block['type']) {
      case 'heading':
        return Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 6),
          child: Text(
            _text('text'),
            style: block['size'] == 'large'
                ? theme.textTheme.headlineSmall
                : theme.textTheme.titleMedium,
          ),
        );
      case 'text':
        final style = switch (block['style']) {
          'muted' => theme.textTheme.bodyMedium?.merge(muted),
          'small' => theme.textTheme.bodySmall?.merge(muted),
          'bold' => theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          'mono' => theme.textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
          ),
          _ => theme.textTheme.bodyMedium,
        };
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: SelectableText(_text('text'), style: style),
        );
      case 'button':
        final icon = block['icon'] as String?;
        final onPressed = _press('onPress');
        final label = Text(_text('title'));
        final button = switch (block['style']) {
          'filled' =>
            icon == null
                ? FilledButton(onPressed: onPressed, child: label)
                : FilledButton.icon(
                    onPressed: onPressed,
                    icon: Icon(pluginIcon(icon)),
                    label: label,
                  ),
          'outlined' =>
            icon == null
                ? OutlinedButton(onPressed: onPressed, child: label)
                : OutlinedButton.icon(
                    onPressed: onPressed,
                    icon: Icon(pluginIcon(icon)),
                    label: label,
                  ),
          'text' =>
            icon == null
                ? TextButton(onPressed: onPressed, child: label)
                : TextButton.icon(
                    onPressed: onPressed,
                    icon: Icon(pluginIcon(icon)),
                    label: label,
                  ),
          _ =>
            icon == null
                ? FilledButton.tonal(onPressed: onPressed, child: label)
                : FilledButton.tonalIcon(
                    onPressed: onPressed,
                    icon: Icon(pluginIcon(icon)),
                    label: label,
                  ),
        };
        return Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: button,
          ),
        );
      case 'iconButton':
        return IconButton(
          onPressed: _press('onPress'),
          icon: Icon(pluginIcon(block['icon'] as String?)),
          isSelected: block['selected'] == true,
          selectedIcon: Icon(
            pluginIcon(block['icon'] as String?),
            color: Palette.accentLight,
          ),
          tooltip: block['title'] as String?,
        );
      case 'row':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: _spaced(_children(), SizedBox(width: gap)),
          ),
        );
      case 'column':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: _spaced(_children(), SizedBox(height: gap)),
        );
      case 'wrap':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Wrap(spacing: gap, runSpacing: gap, children: _children()),
        );
      case 'card':
        final onTap = _press('onPress');
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Material(
            color: Palette.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Palette.r(16)),
              side: BorderSide(color: Palette.outline),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: _spaced(_children(), SizedBox(height: gap)),
                ),
              ),
            ),
          ),
        );
      case 'image':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _image(
            block,
            width: _number('width'),
            height: _number('height'),
          ),
        );
      case 'divider':
        return const Divider(height: 24);
      case 'spacer':
        return SizedBox(
          height: _number('size') ?? 16,
          width: _number('size') ?? 16,
        );
      case 'progress':
        final value = _number('value');
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: LinearProgressIndicator(value: value?.clamp(0, 1)),
        );
      case 'input':
        return _Input(block: block, run: run);
      case 'switch':
        return _Switch(block: block, run: run);
      case 'slider':
        return _Slider(block: block, run: run);
      case 'select':
        return _Select(block: block, run: run);
      case 'list':
        final items = [
          for (final item in (block['items'] as List?) ?? const [])
            if (item is Map<String, Object?>) item,
        ];
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in items)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: item['image'] != null || item['art'] != null
                    ? _image(item, width: 40, height: 40)
                    : item['icon'] is String
                    ? Icon(pluginIcon(item['icon'] as String))
                    : null,
                title: Text(
                  '${item['title'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: item['subtitle'] == null
                    ? null
                    : Text(
                        '${item['subtitle']}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                trailing: item['trailing'] == null
                    ? null
                    : Text('${item['trailing']}', style: muted),
                onTap: switch (_handler(item['onPress'])) {
                  final h? => () => run(h),
                  null => null,
                },
              ),
          ],
        );
      case 'tracks':
        final wanted = [
          for (final item in (block['paths'] ?? block['tracks']) as List? ?? [])
            switch (item) {
              final String path => path,
              {'path': final String path} => path,
              _ => null,
            },
        ];
        final tracks = <Track>[
          for (final p in wanted)
            if (p != null) ?scope.library.byPath(p),
        ];
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, t) in tracks.indexed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Artwork(art: t.art, size: 40, radius: 6),
                title: Text(
                  t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  t.artists.join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => scope.player.playTracks(tracks, i),
              ),
          ],
        );
    }
    return const SizedBox.shrink();
  }

  static List<Widget> _spaced(List<Widget> children, Widget gap) => [
    for (final (i, c) in children.indexed) ...[if (i > 0) gap, c],
  ];

  /// `art` (a track's cover key), `src` (a web address or a file's path).
  static Widget _image(
    Map<String, Object?> b, {
    double? width,
    double? height,
  }) {
    final radius = BorderRadius.circular(
      Palette.r(((b['radius'] as num?) ?? 8).toDouble()),
    );
    if (b['art'] case final String art) {
      return Artwork(art: art, size: width ?? height ?? 120, radius: 8);
    }
    final src = '${b['src'] ?? b['image'] ?? ''}';
    final fit = b['fit'] == 'contain' ? BoxFit.contain : BoxFit.cover;
    Widget broken(BuildContext _, Object _, StackTrace? _) => SizedBox(
      width: width,
      height: height,
      child: Icon(Icons.broken_image_outlined, color: Palette.textMuted),
    );
    final image = src.startsWith('http://') || src.startsWith('https://')
        ? Image.network(
            src,
            width: width,
            height: height,
            fit: fit,
            errorBuilder: broken,
          )
        : Image.file(
            File(src),
            width: width,
            height: height,
            fit: fit,
            errorBuilder: broken,
          );
    return ClipRRect(borderRadius: radius, child: image);
  }
}

class _Input extends StatefulWidget {
  const _Input({required this.block, required this.run});

  final Map<String, Object?> block;
  final _Run run;

  @override
  State<_Input> createState() => _InputState();
}

class _InputState extends State<_Input> {
  late final _controller = TextEditingController(
    text: '${widget.block['value'] ?? ''}',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.block;
    final onChange = _handler(b['onChange']);
    final onSubmit = _handler(b['onSubmit']);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: _controller,
        obscureText: b['secret'] == true,
        maxLines: b['multiline'] == true ? 5 : 1,
        minLines: 1,
        decoration: InputDecoration(
          labelText: b['label'] as String?,
          hintText: b['placeholder'] as String?,
        ),
        // Typing doesn't render the page again; submitting does.
        onChanged: onChange == null
            ? null
            : (v) => widget.run(onChange, v, false),
        onSubmitted: onSubmit == null ? null : (v) => widget.run(onSubmit, v),
      ),
    );
  }
}

class _Switch extends StatefulWidget {
  const _Switch({required this.block, required this.run});

  final Map<String, Object?> block;
  final _Run run;

  @override
  State<_Switch> createState() => _SwitchState();
}

class _SwitchState extends State<_Switch> {
  /// Shown at once, until the page renders again with the plugin's value.
  bool? _value;

  @override
  void didUpdateWidget(_Switch old) {
    super.didUpdateWidget(old);
    _value = null;
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.block;
    final onChange = _handler(b['onChange']);
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('${b['label'] ?? ''}'),
      subtitle: b['detail'] == null ? null : Text('${b['detail']}'),
      value: _value ?? b['value'] == true,
      onChanged: onChange == null
          ? null
          : (on) {
              setState(() => _value = on);
              widget.run(onChange, on);
            },
    );
  }
}

class _Slider extends StatefulWidget {
  const _Slider({required this.block, required this.run});

  final Map<String, Object?> block;
  final _Run run;

  @override
  State<_Slider> createState() => _SliderState();
}

class _SliderState extends State<_Slider> {
  double? _value;

  @override
  void didUpdateWidget(_Slider old) {
    super.didUpdateWidget(old);
    _value = null;
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.block;
    final min = ((b['min'] as num?) ?? 0).toDouble();
    final max = ((b['max'] as num?) ?? 1).toDouble();
    final step = (b['step'] as num?)?.toDouble();
    final value = (_value ?? ((b['value'] as num?) ?? min).toDouble()).clamp(
      min,
      max > min ? max : min + 1,
    );
    final onChange = _handler(b['onChange']);
    return Row(
      children: [
        if (b['label'] case final String label)
          SizedBox(width: 120, child: Text(label)),
        Expanded(
          child: Slider(
            min: min,
            max: max > min ? max : min + 1,
            divisions: step != null && step > 0
                ? ((max - min) / step).round().clamp(1, 1000)
                : null,
            value: value,
            label: step == null ? null : '$value',
            onChanged: onChange == null
                ? null
                : (v) => setState(() => _value = v),
            onChangeEnd: onChange == null
                ? null
                : (v) => widget.run(onChange, v),
          ),
        ),
      ],
    );
  }
}

class _Select extends StatelessWidget {
  const _Select({required this.block, required this.run});

  final Map<String, Object?> block;
  final _Run run;

  @override
  Widget build(BuildContext context) {
    final options = [
      for (final o in (block['options'] as List?) ?? const [])
        switch (o) {
          {'value': final v, 'label': final l} => (value: '$v', label: '$l'),
          {'value': final v} => (value: '$v', label: '$v'),
          _ => (value: '$o', label: '$o'),
        },
    ];
    final value = '${block['value'] ?? ''}';
    final onChange = _handler(block['onChange']);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: DropdownMenu<String>(
        key: ValueKey(value),
        label: block['label'] == null ? null : Text('${block['label']}'),
        initialSelection: options.any((o) => o.value == value) ? value : null,
        enabled: onChange != null,
        dropdownMenuEntries: [
          for (final o in options)
            DropdownMenuEntry(value: o.value, label: o.label),
        ],
        onSelected: (v) {
          if (v != null && onChange != null) run(onChange, v);
        },
      ),
    );
  }
}

/// The buttons plugins added to the player bar and Now Playing.
class PluginPlayerButtons extends StatelessWidget {
  const PluginPlayerButtons({super.key, this.iconSize = 20, this.color});

  final double iconSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final plugins = AppScope.of(context).plugins;
    return ListenableBuilder(
      listenable: plugins,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final action in plugins.playerButtons)
            IconButton(
              onPressed: () => runPluginAction(context, action),
              icon: Icon(pluginIcon(action.icon)),
              iconSize: iconSize,
              color: color ?? Palette.textMuted,
              tooltip: action.title,
            ),
        ],
      ),
    );
  }
}

/// Runs a plugin's command, button or song-menu entry, saying so if it fails.
Future<void> runPluginAction(
  BuildContext context,
  PluginAction action, [
  Track? track,
]) async {
  final plugins = AppScope.of(context).plugins;
  try {
    await plugins.invoke(
      action.plugin,
      action.handler,
      track == null ? null : trackJson(track),
    );
  } on Object catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('${action.title}: $e'),
          behavior: SnackBarBehavior.floating,
          width: 360,
        ),
      );
    }
  }
}

/// A plugin's page on a route of its own (the phone, or from its card).
void openPluginPage(BuildContext context, PluginPage page) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        appBar: AppBar(title: Text(page.title)),
        body: PluginPageView(pageKey: page.key),
      ),
    ),
  );
}

/// Pill used by plugin tabs in the phone's Library row.
Widget pluginTabPill(
  PluginPage tab, {
  required bool selected,
  required VoidCallback onPressed,
}) => Pill(
  label: tab.title,
  icon: tab.icon == null ? null : pluginIcon(tab.icon),
  selected: selected,
  onPressed: onPressed,
);
