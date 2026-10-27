import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../rust/api/library.dart';
import '../rust/api/player.dart';
import '../rust/api/plugins.dart';
import '../theme_template.dart';
import 'library.dart';
import 'player.dart';
import 'playlists.dart';
import 'sound.dart';
import 'themes.dart';
import 'updater.dart' show compareVersions;

/// What a plugin may use beyond adding its own tabs, buttons and settings and keeping
/// its own saved values.
enum PluginPermission {
  library(
    'Read and change your library',
    'See every song, its tags and play count, and edit your playlists',
  ),
  player(
    'Control playback',
    'Play, queue, skip and seek, change the volume, know what\'s playing, and '
        'change what plays when you start something',
  ),
  interface(
    'Change how Halcyn looks and works',
    'Hide or replace Halcyn\'s own tabs, add themes and keyboard shortcuts',
  ),
  files(
    'Read and write your files',
    'Open, change, create and delete files anywhere Halcyn can reach',
  ),
  network('Use the internet', 'Send and receive data from any website');

  const PluginPermission(this.label, this.detail);
  final String label;
  final String detail;
}

/// The platforms a plugin can say it runs on.
const pluginPlatforms = {
  'linux': 'Linux',
  'windows': 'Windows',
  'android': 'Android',
};

/// The JSON block at the top of a plugin file:
///
///     /* halcyn-plugin
///     { "id": "dev.example.hello", "name": "Hello", "version": "1.0.0",
///       "platforms": ["linux", "windows", "android"], "halcyn": "0.2.0",
///       "author": "…", "description": "…", "permissions": ["player"] }
///     */
class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.platforms,
    this.minHalcyn,
    this.author = '',
    this.description = '',
    this.permissions = const {},
  });

  final String id;
  final String name;
  final String version;

  /// Where it runs: some of [pluginPlatforms]' keys.
  final Set<String> platforms;

  /// The oldest Halcyn it works with, if it says.
  final String? minHalcyn;
  final String author;
  final String description;
  final Set<PluginPermission> permissions;

  static final _block = RegExp(
    r'^\s*/\*\s*halcyn-plugin\s*(\{.*?\})\s*\*/',
    dotAll: true,
  );
  static final _id = RegExp(r'^[a-z0-9][a-z0-9._-]{1,63}$');
  static final _version = RegExp(r'^\d+(\.\d+){0,2}$');

  /// "Linux, Windows and Android".
  String get platformNames {
    final names = [
      for (final p in pluginPlatforms.keys)
        if (platforms.contains(p)) pluginPlatforms[p]!,
    ];
    return names.length < 2
        ? names.join()
        : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }

  /// Throws a [FormatException] saying what's wrong.
  static PluginManifest parse(String source) {
    final match = _block.firstMatch(source);
    if (match == null) {
      throw const FormatException(
        'This isn\'t a Halcyn plugin: it doesn\'t start with a '
        '/* halcyn-plugin { … } */ block',
      );
    }
    final Object? json;
    try {
      json = jsonDecode(match[1]!);
    } on FormatException catch (e) {
      throw FormatException(
        'The plugin\'s info block isn\'t valid JSON: ${e.message}',
      );
    }
    if (json is! Map<String, Object?>) {
      throw const FormatException('The plugin\'s info block must be an object');
    }
    final info = json;
    String text(String key, {bool required = false}) {
      final value = info[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (required) {
        throw FormatException('The plugin\'s info is missing "$key"');
      }
      return '';
    }

    final id = text('id', required: true);
    if (!_id.hasMatch(id)) {
      throw FormatException(
        '"$id" can\'t be a plugin id: use lowercase letters, digits, dots, dashes',
      );
    }
    final platforms = <String>{};
    for (final p in (info['platforms'] as List?) ?? const []) {
      if (!pluginPlatforms.containsKey(p)) {
        throw FormatException(
          'Unknown platform "$p" (use ${pluginPlatforms.keys.join(', ')})',
        );
      }
      platforms.add(p as String);
    }
    if (platforms.isEmpty) {
      throw const FormatException(
        'The plugin\'s info must list its "platforms": linux, windows, android',
      );
    }
    final minHalcyn = text('halcyn');
    if (minHalcyn.isNotEmpty && !_version.hasMatch(minHalcyn)) {
      throw FormatException(
        '"halcyn" must be the oldest version it works with, like "0.2.0"',
      );
    }
    final permissions = <PluginPermission>{};
    for (final p in (info['permissions'] as List?) ?? const []) {
      final known = PluginPermission.values.where((v) => v.name == p);
      if (known.isEmpty) throw FormatException('Unknown permission "$p"');
      permissions.add(known.single);
    }
    return PluginManifest(
      id: id,
      name: text('name', required: true),
      version: text('version', required: true),
      platforms: platforms,
      minHalcyn: minHalcyn.isEmpty ? null : minHalcyn,
      author: text('author'),
      description: text('description'),
      permissions: permissions,
    );
  }
}

/// Where a plugin's tab shows.
enum TabPlace {
  /// The sidebar's Plugins section; on a phone, the Library tab's row.
  sidebar,

  /// Beside Songs, Albums, Artists and Queue.
  library,

  /// The top of the sidebar; on a phone, the bottom bar.
  main,
}

/// Halcyn's own tabs a plugin can hide or replace.
const builtInTabs = {
  'songs',
  'albums',
  'artists',
  'queue',
  'smartPlaylists',
  'playlists',
  'search',
};

/// A button, menu entry or shortcut a plugin added.
class PluginAction {
  const PluginAction(
    this.plugin,
    this.title,
    this.handler, {
    this.icon,
    this.keys,
  });
  final String plugin;
  final String title;
  final int handler;

  /// A name from the docs' icon list.
  final String? icon;

  /// For a shortcut, e.g. "ctrl+shift+k".
  final String? keys;
}

/// Something a plugin renders: a tab, a replacement for a built-in tab, a Settings
/// section or a dialog. [key] is unique while the app runs.
class PluginPage {
  const PluginPage(
    this.key,
    this.plugin,
    this.title,
    this.handler, {
    this.icon,
    this.place = TabPlace.sidebar,
  });
  final int key;
  final String plugin;
  final String title;
  final int handler;
  final String? icon;
  final TabPlace place;
}

class LogLine {
  const LogLine(this.at, this.error, this.text);
  final DateTime at;
  final bool error;
  final String text;
}

class InstalledPlugin {
  InstalledPlugin(this.manifest, this.file, {this.enabled = true});

  PluginManifest manifest;
  final File file;
  bool enabled;

  /// Why it isn't running, when it should be.
  String? failure;
  bool running = false;
  final log = <LogLine>[];
  final commands = <PluginAction>[];
  final trackActions = <PluginAction>[];
  final playerButtons = <PluginAction>[];
  final shortcuts = <PluginAction>[];
  final tabs = <PluginPage>[];
  final settings = <PluginPage>[];

  /// Built-in tab → its replacement.
  final replaced = <String, PluginPage>{};
  final hidden = <String>{};
  final themes = <HalcynTheme>[];
  final beforePlay = <int>[];
  final events = <String>{};
  bool showTrackPlays = false;

  void clearAdded() {
    commands.clear();
    trackActions.clear();
    playerButtons.clear();
    shortcuts.clear();
    tabs.clear();
    settings.clear();
    replaced.clear();
    hidden.clear();
    themes.clear();
    beforePlay.clear();
    events.clear();
    showTrackPlays = false;
  }
}

/// Installs and runs plugins, and answers what they ask for (see `rust/src/plugins`).
/// A request a plugin lacks the permission for is refused, so its promise rejects.
class PluginManager extends ChangeNotifier {
  PluginManager({
    required this.dir,
    required this.player,
    required this.library,
    required this.playlists,
    required this.sound,
    required this.themes,
    required this.appVersion,
    String? platform,
    this._requests,
  }) : platform = platform ?? Platform.operatingSystem;

  /// Where the plugins (`<id>.js`), their saved values (`<id>.data.json`) and the
  /// on/off list (`plugins.json`) live.
  final Directory dir;
  final PlayerController player;
  final LibraryController library;
  final PlaylistsController playlists;
  final SoundController sound;
  final ThemeController themes;
  final String appVersion;

  /// One of [pluginPlatforms]' keys.
  final String platform;

  /// A test's stand-in for the Rust core's requests.
  final Stream<PluginRequest>? _requests;

  final plugins = <String, InstalledPlugin>{};

  /// Messages plugins show with `halcyn.ui.notify`.
  final notices = StreamController<String>.broadcast();

  /// Where `halcyn.ui.navigate` asks to go: a built-in tab's name or a tab's key.
  final navigation = StreamController<String>.broadcast();

  /// Dialogs to open (`halcyn.ui.dialog`), and ones to close (null).
  final dialogs = StreamController<PluginPage?>.broadcast();

  /// Bumped by `halcyn.ui.refresh`: plugin pages render again.
  final refreshes = ValueNotifier(0);

  /// Bumped when plugins have loaded (at startup, or one installed or turned on) and at
  /// least one is running: the sidebar's wordmark flashes.
  final loaded = ValueNotifier(0);

  static const _maxSource = 1 << 20;
  static const _maxStorage = 1 << 20;
  static const _maxResponse = 5 << 20;
  static const _maxFile = 20 << 20;
  static const _maxLog = 200;

  StreamSubscription<PluginRequest>? _subscription;
  final _returns = <int, Completer<Object?>>{};
  final _dialogsOpen = <int, (PluginPage, Completer<void>)>{};
  int _nextReturn = 1;
  int _nextPage = 1;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 15);

  String? _lastPath;
  bool? _lastPlaying;
  List<String>? _lastQueue;
  int _lastSecond = -1;

  String get userAgent => 'Halcyn/$appVersion';

  File get _settings => File('${dir.path}/plugins.json');
  File _source(String id) => File('${dir.path}/$id.js');
  File _data(String id) => File('${dir.path}/$id.data.json');

  Iterable<InstalledPlugin> get _live => plugins.values.where((p) => p.running);

  /// Why `manifest` can't run here, if it can't.
  String? incompatibility(PluginManifest manifest) {
    if (!manifest.platforms.contains(platform)) {
      return '${manifest.name} works on ${manifest.platformNames}, '
          'not ${pluginPlatforms[platform] ?? platform}';
    }
    if (manifest.minHalcyn case final min?
        when compareVersions(appVersion, min) < 0) {
      return '${manifest.name} needs Halcyn $min or newer (this is $appVersion)';
    }
    return null;
  }

  // What running plugins added ---------------------------------------------------

  List<PluginAction> get trackActions => [
    for (final p in _live) ...p.trackActions,
  ];
  List<PluginAction> get playerButtons => [
    for (final p in _live) ...p.playerButtons,
  ];
  List<PluginAction> get shortcuts => [for (final p in _live) ...p.shortcuts];
  List<PluginPage> tabs(TabPlace place) => [
    for (final p in _live)
      for (final t in p.tabs)
        if (t.place == place) t,
  ];
  List<PluginPage> get settingsSections => [
    for (final p in _live) ...p.settings,
  ];

  /// The page a plugin shows instead of Halcyn's `tab`, if one does (the last
  /// plugin to ask wins).
  PluginPage? replacement(String tab) {
    PluginPage? found;
    for (final p in _live) {
      found = p.replaced[tab] ?? found;
    }
    return found;
  }

  bool isHidden(String tab) => _live.any((p) => p.hidden.contains(tab));
  bool get showTrackPlays => _live.any((p) => p.showTrackPlays);

  /// Any page or tab by key, while its plugin runs.
  PluginPage? page(int key) {
    if (_dialogsOpen[key] case (final dialog, _)
        when plugins[dialog.plugin]?.running ?? false) {
      return dialog;
    }
    for (final p in _live) {
      for (final page in [...p.tabs, ...p.settings, ...p.replaced.values]) {
        if (page.key == key) return page;
      }
    }
    return null;
  }

  // Lifecycle ---------------------------------------------------------------------

  Future<void> load() async {
    _subscription ??= (_requests ?? pluginRequests()).listen(_handle);
    player.addListener(_playerChanged);
    player.position.addListener(_positionChanged);
    library.addListener(_libraryChanged);
    await dir.create(recursive: true);
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      for (final key in manifest.listAssets()) {
        if (key.startsWith('assets/plugins/') && key.endsWith('.js')) {
          final source = await rootBundle.loadString(key);
          final pManifest = PluginManifest.parse(source);
          final file = _source(pManifest.id);
          if (!await file.exists()) {
            await file.writeAsString(source);
          }
        }
      }
    } on Object catch (e) {
      debugPrint('Bundling assets/plugins: $e');
    }
    Map<String, Object?> enabled = const {};
    try {
      enabled =
          jsonDecode(await _settings.readAsString()) as Map<String, Object?>;
    } on Object {
      // None saved yet.
    }
    final files = await dir
        .list()
        .where((f) => f is File && f.path.endsWith('.js'))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      try {
        final manifest = PluginManifest.parse(await file.readAsString());
        plugins[manifest.id] = InstalledPlugin(
          manifest,
          file,
          enabled: enabled[manifest.id] != false,
        );
      } on Object catch (e) {
        debugPrint('Skipping plugin ${file.path}: $e');
      }
    }
    for (final p in plugins.values.toList()) {
      if (p.enabled) await _start(p);
    }
    if (_live.isNotEmpty) loaded.value++;
    notifyListeners();
  }

  /// Fetches a plugin's source from a link, for [PluginManifest.parse] and [install].
  Future<String> download(Uri url) async {
    if (url.scheme != 'https' && url.scheme != 'http') {
      throw const FormatException('Use an http or https link');
    }
    final request = await _http.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw HttpException('The link answered ${response.statusCode}', uri: url);
    }
    final bytes = await _readLimited(response, _maxSource);
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Saves and starts a plugin the user has looked over (see [PluginManifest.parse]),
  /// replacing an installed one with the same id. Refuses one that doesn't run on this
  /// platform or this version. Returns why it didn't start, if it didn't.
  Future<String?> install(String source) async {
    if (source.length > _maxSource) {
      throw const FormatException('That plugin is over 1 MB');
    }
    final manifest = PluginManifest.parse(source);
    if (incompatibility(manifest) case final reason?) {
      throw FormatException(reason);
    }
    await dir.create(recursive: true);
    final file = _source(manifest.id);
    await file.writeAsString(source);
    final existing = plugins[manifest.id];
    if (existing != null) {
      _stop(existing);
      existing.manifest = manifest;
      existing.enabled = true;
    } else {
      plugins[manifest.id] = InstalledPlugin(manifest, file);
    }
    await _saveEnabled();
    final plugin = plugins[manifest.id]!;
    await _start(plugin);
    if (plugin.running) loaded.value++;
    notifyListeners();
    return plugin.failure;
  }

  Future<void> setEnabled(String id, bool on) async {
    final plugin = plugins[id];
    if (plugin == null) return;
    plugin.enabled = on;
    if (on) {
      await _start(plugin);
      if (plugin.running) loaded.value++;
    } else {
      _stop(plugin);
    }
    await _saveEnabled();
    notifyListeners();
  }

  /// Uninstalls it, saved values included.
  Future<void> remove(String id) async {
    final plugin = plugins.remove(id);
    if (plugin == null) return;
    _stop(plugin);
    for (final f in [plugin.file, _data(id)]) {
      try {
        await f.delete();
      } on FileSystemException {
        // Already gone.
      }
    }
    await _saveEnabled();
    notifyListeners();
  }

  /// Runs one of a plugin's handlers and gives back what it returned.
  Future<Object?> invoke(
    String id,
    int handler, [
    Object? argument,
    Duration timeout = const Duration(seconds: 20),
  ]) {
    final reply = _nextReturn++;
    final done = Completer<Object?>();
    _returns[reply] = done;
    try {
      pluginInvoke(
        id: id,
        callback: handler,
        json: jsonEncode(argument),
        reply: reply,
      );
    } on Object catch (e) {
      _returns.remove(reply);
      return Future.error(
        StateError('${plugins[id]?.manifest.name ?? id} isn\'t running ($e)'),
      );
    }
    return done.future.timeout(
      timeout,
      onTimeout: () {
        _returns.remove(reply);
        throw TimeoutException('The plugin took too long to answer');
      },
    );
  }

  /// A dialog ([dialogs]) was closed by the user.
  void dialogClosed(PluginPage dialog) =>
      _dialogsOpen.remove(dialog.key)?.$2.complete();

  Future<void> _start(InstalledPlugin plugin) async {
    _stop(plugin);
    plugin.failure = incompatibility(plugin.manifest);
    if (plugin.failure != null) return;
    // Running from the start: its top level asks for things (tabs, buttons) before
    // pluginStart returns.
    plugin.running = true;
    try {
      await pluginStart(
        id: plugin.manifest.id,
        source: await plugin.file.readAsString(),
      );
    } on Object catch (e) {
      plugin.running = false;
      plugin.clearAdded();
      plugin.failure = '$e';
      _log(plugin, true, 'Didn\'t start: $e');
    }
    _changedHooks();
  }

  void _stop(InstalledPlugin plugin) {
    if (plugin.running) pluginStop(id: plugin.manifest.id);
    plugin.running = false;
    final hadThemes = plugin.themes.isNotEmpty;
    plugin.clearAdded();
    if (hadThemes) _syncThemes();
    _changedHooks();
  }

  Future<void> _saveEnabled() => _settings.writeAsString(
    jsonEncode({for (final p in plugins.values) p.manifest.id: p.enabled}),
  );

  void _log(InstalledPlugin plugin, bool error, String text) {
    plugin.log.add(LogLine(DateTime.now(), error, text));
    if (plugin.log.length > _maxLog) plugin.log.removeAt(0);
    notifyListeners();
  }

  void _syncThemes() => themes.setExtra([for (final p in _live) ...p.themes]);

  // Hooks -------------------------------------------------------------------------

  void _changedHooks() {
    player.beforePlay = _live.any((p) => p.beforePlay.isNotEmpty)
        ? _beforePlay
        : null;
  }

  /// Passes what's about to play through every plugin's beforePlay hook, in turn.
  /// Null: play nothing.
  Future<({List<Track> tracks, int start})?> _beforePlay(
    List<Track> tracks,
    int start,
  ) async {
    for (final p in _live.toList()) {
      for (final handler in p.beforePlay.toList()) {
        final Object? result;
        try {
          result = await invoke(p.manifest.id, handler, {
            'tracks': [for (final t in tracks) trackJson(t)],
            'start': start,
          }, const Duration(seconds: 3));
        } on Object catch (e) {
          _log(p, true, 'beforePlay: $e');
          continue;
        }
        if (result == false) return null;
        if (result case {'tracks': final List<Object?> list}) {
          final next = [
            for (final item in list)
              ?switch (item) {
                {'path': final String path} => library.byPath(path),
                final String path => library.byPath(path),
                _ => null,
              },
          ];
          if (next.isEmpty) return null;
          tracks = next;
          start = ((result['start'] as num?)?.toInt() ?? 0).clamp(
            0,
            next.length - 1,
          );
        }
      }
    }
    return (tracks: tracks, start: start);
  }

  // Requests ----------------------------------------------------------------------

  Future<void> _handle(PluginRequest r) async {
    final plugin = plugins[r.plugin];
    if (plugin == null || !plugin.running) return;
    Object? args;
    try {
      args = jsonDecode(r.args);
    } on FormatException {
      args = null;
    }
    final map = args is Map<String, Object?> ? args : const <String, Object?>{};

    switch (r.method) {
      case 'log' || 'error':
        _log(plugin, r.method == 'error', args is String ? args : r.args);
        return;
      case '__return':
        final done = _returns.remove(map['reply']);
        if (done == null) return;
        if (map['ok'] == true) {
          done.complete(map['value']);
        } else {
          done.completeError(StateError('${map['value']}'));
        }
        return;
      case 'on':
        final event = map['event'];
        if (event is String) plugin.events.add(event);
        final needs = event == 'libraryChanged'
            ? PluginPermission.library
            : PluginPermission.player;
        if (!plugin.manifest.permissions.contains(needs)) {
          _log(
            plugin,
            true,
            '"$event" needs the "${needs.name}" permission; it won\'t arrive',
          );
        }
        return;
    }

    try {
      final result = await _answer(plugin, r.method, map);
      _reply(plugin, r.call, true, result);
    } on Object catch (e) {
      _reply(plugin, r.call, false, e is _Refused ? e.message : '$e');
    }
  }

  void _reply(InstalledPlugin plugin, int call, bool ok, Object? value) {
    if (call == 0 || !plugin.running) return;
    try {
      pluginReply(
        id: plugin.manifest.id,
        call: call,
        ok: ok,
        json: jsonEncode(value),
      );
    } on Object {
      // It stopped meanwhile.
    }
  }

  void _need(InstalledPlugin plugin, PluginPermission permission) {
    if (!plugin.manifest.permissions.contains(permission)) {
      throw _Refused(
        '${plugin.manifest.name} doesn\'t have the "${permission.name}" permission',
      );
    }
  }

  static const _needs = {
    'library.': PluginPermission.library,
    'playlists.': PluginPermission.library,
    'player.': PluginPermission.player,
    'hooks.': PluginPermission.player,
    'files.': PluginPermission.files,
    'http.': PluginPermission.network,
    'ui.replace': PluginPermission.interface,
    'ui.hide': PluginPermission.interface,
    'ui.show': PluginPermission.interface,
    'ui.addTheme': PluginPermission.interface,
    'ui.addShortcut': PluginPermission.interface,
    'ui.showTrackPlays': PluginPermission.interface,
  };

  Future<Object?> _answer(
    InstalledPlugin plugin,
    String method,
    Map<String, Object?> args,
  ) async {
    String text(String key) => switch (args[key]) {
      final String s => s,
      _ => throw _Refused('"$key" must be text'),
    };
    String? optional(String key) =>
        args[key] is String ? args[key]! as String : null;
    int number(String key) => switch (args[key]) {
      final num n => n.toInt(),
      _ => throw _Refused('"$key" must be a number'),
    };

    for (final MapEntry(key: prefix, value: permission) in _needs.entries) {
      if (method.startsWith(prefix)) _need(plugin, permission);
    }
    final id = plugin.manifest.id;
    PluginAction action() =>
        PluginAction(id, text('title'), _handler(args), icon: optional('icon'));
    PluginPage page(TabPlace place, {String? title}) => PluginPage(
      _nextPage++,
      id,
      title ?? optional('title') ?? plugin.manifest.name,
      _handler(args),
      icon: optional('icon'),
      place: place,
    );
    Object? added(void Function() add, [Object? result]) {
      add();
      notifyListeners();
      return result;
    }

    switch (method) {
      case 'app.info':
        return {'version': appVersion, 'platform': platform};

      case 'library.tracks':
        return [for (final t in library.tracks) trackJson(t)];
      case 'library.search':
        final query = text('query');
        return [
          for (final t
              in library.tracks.where((t) => matches(t, query)).take(500))
            trackJson(t),
        ];
      case 'library.albums':
        return [
          for (final a in library.albums)
            {
              'title': a.title,
              'artist': a.artist,
              'year': a.year,
              'art': a.art,
              'paths': [for (final t in a.tracks) t.path],
            },
        ];
      case 'library.artists':
        return [
          for (final a in library.artists)
            {
              'name': a.name,
              'art': a.art,
              'albums': [for (final al in a.albums) al.title],
              'paths': [for (final t in a.tracks) t.path],
            },
        ];
      case 'library.rescan':
        await library.rescan();
        return null;

      case 'playlists.list':
        return [
          for (final p in playlists.playlists)
            {'id': p.id, 'name': p.name, 'paths': p.paths, 'file': p.source},
        ];
      case 'playlists.create':
        final created = await playlists.create(
          text('name'),
          _paths(args['paths'], allowEmpty: true),
        );
        return created.id;
      case 'playlists.add':
        playlists.add(_playlist(number('id')), _paths(args['paths']));
        return null;
      case 'playlists.removeAt':
        playlists.removeAt(_playlist(number('id')), number('index'));
        return null;
      case 'playlists.rename':
        playlists.rename(_playlist(number('id')), text('name'));
        return null;
      case 'playlists.delete':
        playlists.delete(_playlist(number('id')));
        return null;

      case 'player.current':
        final t = player.current;
        return t == null ? null : trackJson(t);
      case 'player.play':
        final tracks = _tracks(args['paths']);
        final start = (args['start'] as num?)?.toInt() ?? 0;
        // A plugin's own play skips the beforePlay hooks.
        player.playTracks(
          tracks,
          start.clamp(0, tracks.length - 1),
          hooks: false,
        );
        return null;
      case 'player.playNext':
        player.playNext(_tracks(args['paths']));
        return null;
      case 'player.enqueue':
        player.addToQueue(_tracks(args['paths']));
        return null;
      case 'player.pause':
        player.pause();
        return null;
      case 'player.resume':
        player.play();
        return null;
      case 'player.next':
        player.next();
        return null;
      case 'player.previous':
        player.previous();
        return null;
      case 'player.queue':
        return _queueJson();
      case 'player.jumpTo':
        player.jumpTo(_queueIndex(number('index')));
        return null;
      case 'player.removeAt':
        player.removeAt(_queueIndex(number('index')));
        return null;
      case 'player.move':
        player.move(_queueIndex(number('from')), _queueIndex(number('to')));
        return null;
      case 'player.seek':
        player.seek(((args['seconds'] as num?) ?? 0).toDouble());
        return null;
      case 'player.position':
        return player.position.value;
      case 'player.setShuffle':
        if (player.shuffle != (args['on'] == true)) player.toggleShuffle();
        return null;
      case 'player.setRepeat':
        final mode = Repeat.values.where((m) => m.name == text('mode'));
        if (mode.isEmpty) throw _Refused('repeat is "off", "all" or "one"');
        player.setRepeat(mode.single);
        return null;
      case 'player.volume':
        return sound.volume;
      case 'player.setVolume':
        sound.setVolume(((args['value'] as num?) ?? 1).toDouble().clamp(0, 1));
        return null;

      case 'hooks.beforePlay':
        plugin.beforePlay.add(_handler(args));
        _changedHooks();
        return null;

      case 'ui.addTab':
        final place =
            TabPlace.values.where((p) => p.name == args['where']).firstOrNull ??
            TabPlace.sidebar;
        final tab = page(place);
        return added(() => plugin.tabs.add(tab), '${tab.key}');
      case 'ui.replace':
        final target = text('target');
        if (!builtInTabs.contains(target)) {
          throw _Refused(
            '"$target" isn\'t a built-in tab (${builtInTabs.join(', ')})',
          );
        }
        final replacement = page(TabPlace.sidebar, title: optional('title'));
        return added(() => plugin.replaced[target] = replacement);
      case 'ui.hide' || 'ui.show':
        final targets = [
          for (final t in (args['targets'] as List?) ?? const [])
            if (builtInTabs.contains(t)) t as String,
        ];
        return added(
          () => method == 'ui.hide'
              ? plugin.hidden.addAll(targets)
              : plugin.hidden.removeAll(targets),
        );
      case 'ui.addPlayerButton':
        return added(() => plugin.playerButtons.add(action()));
      case 'ui.addCommand':
        return added(() => plugin.commands.add(action()));
      case 'ui.addTrackAction':
        return added(() => plugin.trackActions.add(action()));
      case 'ui.addSettings':
        return added(() => plugin.settings.add(page(TabPlace.sidebar)));
      case 'ui.addTheme':
        final json = args['theme'];
        if (json is! Map<String, Object?>) {
          throw _Refused('give a theme object');
        }
        final HalcynTheme theme;
        try {
          theme = HalcynTheme.fromJson({
            ...json,
            // Its own id space, so a plugin can't stand in for a built-in theme.
            'id': 'plugin:$id:${json['id'] ?? json['name']}',
          });
        } on Object catch (e) {
          throw _Refused('that theme isn\'t valid: $e');
        }
        plugin.themes
          ..removeWhere((t) => t.id == theme.id)
          ..add(theme);
        _syncThemes();
        return theme.id;
      case 'ui.addShortcut':
        return added(
          () => plugin.shortcuts.add(
            PluginAction(id, text('keys'), _handler(args), keys: text('keys')),
          ),
        );
      case 'ui.showTrackPlays':
        final show = args['show'] != false;
        return added(() => plugin.showTrackPlays = show);
      case 'ui.navigate':
        navigation.add(text('target'));
        return null;
      case 'ui.dialog':
        final dialog = page(TabPlace.sidebar, title: optional('title') ?? '');
        final closed = Completer<void>();
        _dialogsOpen[dialog.key] = (dialog, closed);
        dialogs.add(dialog);
        await closed.future;
        return null;
      case 'ui.closeDialog':
        if (_dialogsOpen.values.any((d) => d.$1.plugin == id)) {
          dialogs.add(null);
        }
        return null;
      case 'ui.refresh':
        refreshes.value++;
        return null;
      case 'ui.notify':
        notices.add('${plugin.manifest.name}: ${text('text')}');
        return null;

      case 'storage.get':
        return (await _storage(id))[text('key')];
      case 'storage.set':
        final values = await _storage(id);
        values[text('key')] = args['value'];
        final json = jsonEncode(values);
        if (json.length > _maxStorage) {
          throw _Refused('A plugin can keep up to 1 MB of saved values');
        }
        await _data(id).writeAsString(json);
        return null;

      case 'files.read':
        final file = File(text('path'));
        if (await file.length() > _maxFile) {
          throw _Refused('files.read reads up to 20 MB');
        }
        return utf8.decode(await file.readAsBytes(), allowMalformed: true);
      case 'files.write':
        final file = File(text('path'));
        await file.parent.create(recursive: true);
        await file.writeAsString(text('text'));
        return null;
      case 'files.list':
        return [
          await for (final e in Directory(text('path')).list())
            {
              'name': e.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
              'path': e.path,
              'directory': e is Directory,
              'size': e is File ? await e.length() : null,
            },
        ];
      case 'files.exists':
        return FileSystemEntity.typeSync(text('path')) !=
            FileSystemEntityType.notFound;
      case 'files.delete':
        final path = text('path');
        await switch (FileSystemEntity.typeSync(path)) {
          FileSystemEntityType.directory => Directory(
            path,
          ).delete(recursive: true),
          FileSystemEntityType.notFound => Future.value(),
          _ => File(path).delete(),
        };
        return null;

      case 'http.get' || 'http.post':
        return _fetch(
          plugin,
          method == 'http.get' ? 'GET' : 'POST',
          Uri.tryParse(text('url')),
          args['headers'],
          method == 'http.post' ? text('body') : null,
        );
    }
    throw _Refused('"$method" isn\'t something Halcyn knows');
  }

  int _handler(Map<String, Object?> args) => switch (args['handler']) {
    final num n => n.toInt(),
    _ => throw _Refused('missing handler'),
  };

  List<String> _paths(Object? paths, {bool allowEmpty = false}) {
    final list = [
      if (paths is List)
        for (final p in paths)
          if (p is String && library.byPath(p) != null) p,
    ];
    if (list.isEmpty && !allowEmpty) {
      throw _Refused('none of those tracks are in the library');
    }
    return list;
  }

  List<Track> _tracks(Object? paths) {
    return [for (final p in _paths(paths)) library.byPath(p)!];
  }

  int _queueIndex(int i) {
    if (i < 0 || i >= player.queue.length) {
      throw _Refused('the queue has no entry $i');
    }
    return i;
  }

  Playlist _playlist(int id) =>
      playlists.byId(id) ?? (throw _Refused('there\'s no playlist $id'));

  Map<String, Object?> _queueJson() => {
    'tracks': [for (final t in player.queue) trackJson(t)],
    'index': player.index,
    'shuffle': player.shuffle,
    'repeat': player.repeat.name,
    'playing': player.playing,
  };

  Future<Map<String, Object?>> _storage(String id) async {
    try {
      return (jsonDecode(await _data(id).readAsString()) as Map)
          .cast<String, Object?>();
    } on Object {
      return {};
    }
  }

  Future<Object?> _fetch(
    InstalledPlugin plugin,
    String method,
    Uri? url,
    Object? headers,
    String? body,
  ) async {
    if (url == null || (url.scheme != 'https' && url.scheme != 'http')) {
      throw _Refused('give an http or https address');
    }
    final request = await _http.openUrl(method, url);
    request.headers.set(
      HttpHeaders.userAgentHeader,
      '$userAgent (plugin ${plugin.manifest.id})',
    );
    if (headers is Map) {
      headers.forEach((k, v) => request.headers.set('$k', '$v'));
    }
    if (body != null) request.write(body);
    final response = await request.close().timeout(const Duration(seconds: 30));
    final bytes = await _readLimited(response, _maxResponse);
    return {
      'status': response.statusCode,
      'body': utf8.decode(bytes, allowMalformed: true),
      'contentType': response.headers.contentType?.mimeType,
    };
  }

  static Future<List<int>> _readLimited(
    Stream<List<int>> stream,
    int max,
  ) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      bytes.add(chunk);
      if (bytes.length > max) {
        throw _Refused('the answer is over ${max >> 20} MB');
      }
    }
    return bytes.takeBytes();
  }

  // Events ------------------------------------------------------------------------

  void _playerChanged() {
    final current = player.current;
    if (current?.path != _lastPath) {
      _lastPath = current?.path;
      _emit('trackChanged', current == null ? null : trackJson(current));
    }
    if (player.playing != _lastPlaying) {
      _lastPlaying = player.playing;
      _emit('playState', {'playing': player.playing});
    }
    final queue = [for (final t in player.queue) t.path];
    if (!listEquals(queue, _lastQueue)) {
      _lastQueue = queue;
      if (_wanted('queueChanged')) _emit('queueChanged', _queueJson());
    }
  }

  void _positionChanged() {
    final second = player.position.value.floor();
    if (second == _lastSecond) return;
    _lastSecond = second;
    _emit('position', {'seconds': player.position.value});
  }

  void _libraryChanged() => _emit('libraryChanged', null);

  bool _wanted(String event) => _live.any((p) => p.events.contains(event));

  void _emit(String event, Object? value) {
    final needs = event == 'libraryChanged'
        ? PluginPermission.library
        : PluginPermission.player;
    String? json;
    for (final p in _live) {
      if (!p.events.contains(event)) continue;
      if (!p.manifest.permissions.contains(needs)) continue;
      try {
        pluginEmit(
          id: p.manifest.id,
          event: event,
          json: json ??= jsonEncode(value),
        );
      } on Object {
        // Stopped meanwhile.
      }
    }
  }

  @override
  void dispose() {
    player.removeListener(_playerChanged);
    player.position.removeListener(_positionChanged);
    library.removeListener(_libraryChanged);
    _subscription?.cancel();
    for (final p in plugins.values) {
      _stop(p);
    }
    _http.close(force: true);
    notices.close();
    navigation.close();
    dialogs.close();
    super.dispose();
  }
}

class _Refused implements Exception {
  const _Refused(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A track as plugins see it.
Map<String, Object?> trackJson(Track t) => {
  'path': t.path,
  'title': t.title,
  'artists': t.artists,
  'artist': t.artists.join(', '),
  'album': t.album,
  'albumArtist': t.albumArtist,
  'year': t.year,
  'trackNo': t.trackNo,
  'discNo': t.discNo,
  'duration': t.durationSecs,
  'sampleRate': t.sampleRate,
  'bits': t.bits,
  'codec': t.codec,
  'plays': t.plays,
  'art': t.art,
};
