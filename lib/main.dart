import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'src/rust/api/library.dart';
import 'src/rust/api/streaming.dart';
import 'src/rust/frb_generated.dart';
import 'src/cast/receiver.dart';
import 'src/cast/sender.dart';
import 'src/state/android.dart';
import 'src/state/error_log.dart';
import 'src/state/library.dart';
import 'src/state/player.dart';
import 'src/state/playlists.dart';
import 'src/state/sort.dart';
import 'src/state/sound.dart';
import 'src/state/themes.dart';
import 'src/state/fetcher.dart';
import 'src/state/plugins.dart';
import 'src/state/streaming.dart';
import 'src/state/updater.dart';
import 'src/theme.dart';
import 'src/ui/plugins_page.dart';
import 'src/ui/cast.dart';
import 'src/ui/shell.dart';
import 'src/ui/updates.dart';
import 'src/ui/widgets.dart';
import 'src/ui/window_frame.dart';
import 'src/window.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  final data = await getApplicationSupportDirectory();
  logErrorsTo(File('${data.path}/halcyn.log'));
  final cache = await getApplicationCacheDirectory();
  await libraryOpen(dataDir: data.path, cacheDir: cache.path);
  await streamingInit(dataDir: data.path, cacheDir: cache.path);
  if (Platform.isAndroid) {
    // YouTube's audio addresses come from NewPipe's extractor, in the app.
    const android = MethodChannel('halcyn/android');
    await streamingSetYoutubeResolver(
      resolve: (id) async {
        try {
          return await android.invokeMethod<String>('youtubeAudio', {
                'id': id,
              }) ??
              '';
        } on PlatformException catch (e) {
          return e.message ?? '';
        }
      },
    );
  }

  // Audio sent to a test sink (see integration_test/) isn't listening: it doesn't
  // count towards Most played, replace the session to resume or save settings.
  final listening = !Platform.environment.containsKey('HALCYN_PW_TARGET');
  final themes = ThemeController(
    File('${data.path}/ui.json'),
    persist: listening,
  );
  await themes.load();
  final library = LibraryController();
  final sound = SoundController(
    File('${data.path}/sound.json'),
    persist: listening,
  );
  final sort = SortPrefs(File('${data.path}/sort.json'), persist: listening);
  late final StreamingController streaming;
  final player = PlayerController(
    session: listening ? File('${data.path}/session.json') : null,
    onListened: listening
        ? (track) {
            library.recordPlay(track);
            streaming.listened(track);
          }
        : null,
  );
  final playlists = PlaylistsController();
  streaming = StreamingController(
    library: library,
    player: player,
    playlists: playlists,
    settings: File('${data.path}/streaming.json'),
    persist: listening,
  );
  // Show what's already indexed right away, then pick up changes in the background.
  await Future.wait([
    library.load(),
    playlists.load(),
    sound.load(),
    sort.load(),
  ]);
  // Before the session comes back: it may hold streamed songs.
  await streaming.load();
  if (args.isEmpty) await player.restore(library.byPath);
  final access = MusicAccess(library);
  final artDir = libraryArtDir();
  // A test listens on its own ports (HALCYN_CAST_PORT), never beside the real one.
  final receiver = CastReceiver(
    player: player,
    library: library,
    sound: sound,
    // A test gets no approvals: it never sees the devices the user allowed.
    settings: File(
      listening
          ? '${data.path}/cast-receiver.json'
          : '${cache.path}/cast-receiver-test.json',
    ),
    cacheDir: cache,
    artDir: artDir,
    persist: listening,
  );
  final cast = CastController(
    player: player,
    artDir: artDir,
    settings: File('${data.path}/cast.json'),
    receiverId: () => receiver.id,
    persist: listening,
  );
  final name = await deviceName();
  receiver.name = name;
  await cast.load(deviceName: name);
  if (listening || Platform.environment.containsKey('HALCYN_CAST_PORT')) {
    await receiver.load();
  }
  final version = (await PackageInfo.fromPlatform()).version;
  final updater = Updater(
    settings: File('${data.path}/update.json'),
    cacheDir: cache,
    current: version,
    persist: listening,
  );
  await updater.load();
  if (listening) updater.checkLater();
  // A test gets an empty plugins folder of its own.
  final plugins = PluginManager(
    dir: Directory(
      listening ? '${data.path}/plugins' : '${cache.path}/plugins-test',
    ),
    player: player,
    library: library,
    playlists: playlists,
    sound: sound,
    themes: themes,
    appVersion: version,
  );
  await plugins.load();
  downloadedLyricsDir = Directory('${data.path}/lyrics');
  final fetcher = Fetcher(
    library: library,
    player: player,
    settings: File('${data.path}/fetch.json'),
    userAgent: 'Halcyn/$version ( https://github.com/Varixxl/halcyn )',
    // Tests don't download.
    online: listening,
    persist: listening,
  );
  await fetcher.load();
  fetcher.start();
  await Future.wait([
    access.start(),
    MediaSession.start(player, library, artDir, cast),
  ]);
  if (access.granted) {
    library.rescan().then((_) => _playArgument(args, library, player));
  }

  runApp(
    AppScope(
      player: player,
      library: library,
      window: WindowController(),
      themes: themes,
      playlists: playlists,
      sound: sound,
      sort: sort,
      access: access,
      artDir: artDir,
      cast: cast,
      receiver: receiver,
      updater: updater,
      plugins: plugins,
      fetcher: fetcher,
      streaming: streaming,
      child: const HalcynApp(),
    ),
  );
}

/// `halcyn <file>` plays that file, if it's in the library.
void _playArgument(
  List<String> args,
  LibraryController library,
  PlayerController player,
) {
  if (args.isEmpty) return;
  final track = library.byPath(args.first);
  if (track != null) player.playTracks([track], 0);
}

class HalcynApp extends StatefulWidget {
  const HalcynApp({super.key});

  @override
  State<HalcynApp> createState() => _HalcynAppState();
}

class _HalcynAppState extends State<HalcynApp> {
  ThemeController? _themes;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final themes = AppScope.of(context).themes;
    if (themes != _themes) {
      _themes?.removeListener(_retheme);
      _themes = themes..addListener(_retheme);
    }
  }

  @override
  void dispose() {
    _themes?.removeListener(_retheme);
    super.dispose();
  }

  /// Widgets read Palette while building, and many are const, so a new theme has to
  /// rebuild every element, not just the ones whose configuration changed.
  void _retheme() {
    setState(() {});
    void dirty(Element element) {
      element.markNeedsBuild();
      element.visitChildren(dirty);
    }

    (context as Element).visitChildren(dirty);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Halcyn',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      // Palette switches at once, so ThemeData must too.
      themeAnimationDuration: Duration.zero,
      navigatorKey: appNavigator,
      builder: (context, child) => UpdatePrompt(
        child: PairingPrompts(
          child: PluginHost(
            navigator: appNavigator,
            child: WindowFrame(child: child!),
          ),
        ),
      ),
      home: const Shell(),
    );
  }
}
