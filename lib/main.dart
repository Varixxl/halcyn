import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/rust/api/library.dart';
import 'src/rust/frb_generated.dart';
import 'src/cast/receiver.dart';
import 'src/cast/sender.dart';
import 'src/state/android.dart';
import 'src/state/library.dart';
import 'src/state/player.dart';
import 'src/state/playlists.dart';
import 'src/state/sort.dart';
import 'src/state/sound.dart';
import 'src/state/themes.dart';
import 'src/theme.dart';
import 'src/ui/cast.dart';
import 'src/ui/shell.dart';
import 'src/ui/widgets.dart';
import 'src/ui/window_frame.dart';
import 'src/window.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  final data = await getApplicationSupportDirectory();
  final cache = await getApplicationCacheDirectory();
  await libraryOpen(dataDir: data.path, cacheDir: cache.path);

  // Audio sent to a test sink (see integration_test/) isn't listening: it doesn't
  // count towards Most played, replace the session to resume or save settings.
  final listening = !Platform.environment.containsKey('HALCYN_PW_TARGET');
  final themes = ThemeController(
    File('${data.path}/ui.json'),
    persist: listening,
  );
  await themes.load();
  final library = LibraryController();
  final playlists = PlaylistsController();
  final sound = SoundController(
    File('${data.path}/sound.json'),
    persist: listening,
  );
  final sort = SortPrefs(File('${data.path}/sort.json'), persist: listening);
  final player = PlayerController(
    session: listening ? File('${data.path}/session.json') : null,
    onListened: listening ? library.recordPlay : null,
  );
  // Show what's already indexed right away, then pick up changes in the background.
  await Future.wait([
    library.load(),
    playlists.load(),
    sound.load(),
    sort.load(),
  ]);
  if (args.isEmpty) await player.restore(library.byPath);
  final access = MusicAccess(library);
  final artDir = libraryArtDir();
  // A test listens on its own ports (HALCYN_CAST_PORT), never beside the real one.
  final receiver = CastReceiver(
    player: player,
    library: library,
    sound: sound,
    settings: File('${data.path}/cast-receiver.json'),
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
  await Future.wait([
    access.start(),
    MediaSession.start(player, library, artDir),
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
      builder: (context, child) =>
          PairingPrompts(child: WindowFrame(child: child!)),
      home: const Shell(),
    );
  }
}
