// Plugins in the real app: installing (the example plugins), platform and version
// checks, a permission refusal, a broken plugin, a plugin's sidebar page, command and
// song-menu entry, events and saved values; a plugin that reshapes the app (hides and
// replaces built-in tabs, adds a main tab, player button, Settings section, theme,
// shortcut and a beforePlay hook); then turning one off and removing it.
//
//   HALCYN_PW_TARGET=<null sink> flutter test integration_test/plugins_test.dart -d linux

import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/main.dart' as app;
import 'package:halcyn/src/state/plugins.dart';
import 'package:halcyn/src/ui/sidebar.dart';
import 'package:halcyn/src/ui/track_list.dart';
import 'package:halcyn/src/ui/widgets.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('install, run, refuse, turn off and remove plugins', (
    tester,
  ) async {
    expect(Platform.environment['HALCYN_PW_TARGET'], isNotNull);
    // A clean plugins folder (the test's own; see main.dart).
    final cache = await getApplicationCacheDirectory();
    final folder = Directory('${cache.path}/plugins-test');
    if (folder.existsSync()) folder.deleteSync(recursive: true);
    // Gone afterwards too, even if a step fails: other tests would run its plugins.
    addTearDown(() {
      if (folder.existsSync()) folder.deleteSync(recursive: true);
    });

    await app.main(const []);
    // The desktop layout, sidebar and all, whatever size the test window opened at.
    tester.view.physicalSize =
        const Size(1280, 800) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await _wait(tester, 2500);
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    final plugins = scope.plugins;
    final player = scope.player;
    // Only the plugins that come with the app.
    expect(plugins.plugins.keys, ['io.github.varixxl.play-counts']);

    // Installing: the info block is checked; a broken one is refused up front.
    expect(
      () => PluginManifest.parse('halcyn.ui.notify("hi")'),
      throwsFormatException,
    );
    final discover = File('plugins/examples/discover.js').readAsStringSync();
    expect(await tester.runAsync(() => plugins.install(discover)), isNull);
    // The wordmark flashes a rainbow, then settles.
    expect(plugins.loaded.value, greaterThan(0));
    await _wait(tester, 500);
    expect(
      find.descendant(
        of: find.byType(Wordmark),
        matching: find.byType(ShaderMask),
      ),
      findsOneWidget,
    );
    await _shot(tester, 'plugins-0-rainbow');
    await _wait(tester, 1600);
    expect(
      find.descendant(
        of: find.byType(Wordmark),
        matching: find.byType(ShaderMask),
      ),
      findsNothing,
    );

    // Its page is in the sidebar and renders the blocks render() returns.
    await _until(tester, () => plugins.tabs(TabPlace.sidebar).isNotEmpty);
    await _sidebar(tester, 'Discover');
    await tester.tap(find.text('Discover'));
    await _wait(tester, 1200);
    expect(find.text('Not played yet'), findsOneWidget);
    expect(find.text('Shuffle these'), findsOneWidget);
    await _shot(tester, 'plugins-1-page');

    // Its command, from its card in Manage plugins: plays an album and says so.
    await _sidebar(tester, 'Manage plugins');
    await tester.tap(find.text('Manage plugins'));
    await _wait(tester, 800);
    // Discover's card and play-counts'.
    expect(find.text('Read and change your library'), findsNWidgets(2));
    expect(find.text('Control playback'), findsOneWidget);
    await tester.tap(find.text('Play a random album'));
    await _until(tester, () => player.current != null && player.playing);
    await _wait(tester, 400);
    expect(find.textContaining('Discover: Playing'), findsOneWidget);
    await _shot(tester, 'plugins-2-manage');

    // Its song-menu entry: Play this artist plays only that artist.
    await _sidebar(tester, 'Songs');
    await tester.tap(find.text('Songs').first);
    await _wait(tester, 600);
    final row = tester.widget<TrackRow>(find.byType(TrackRow).at(3));
    await tester.tap(find.byType(TrackRow).at(3), buttons: kSecondaryButton);
    await _wait(tester, 500);
    await tester.tap(find.text('Play this artist'));
    await _until(
      tester,
      () => player.current?.artists.contains(row.track.artists.first) ?? false,
    );
    expect(
      player.queue.every((t) => t.artists.contains(row.track.artists.first)),
      isTrue,
    );

    // A plugin without "library" is refused, and the refusal lands in its log.
    const nosy = '''/* halcyn-plugin
{"id": "test.nosy", "name": "Nosy", "version": "0.1.0", "platforms": ["linux"]}
*/
halcyn.library.tracks().then(() => console.log('got in'), e => console.error(e.message));
''';
    await tester.runAsync(() => plugins.install(nosy));
    await _until(tester, () => plugins.plugins['test.nosy']!.log.isNotEmpty);
    final line = plugins.plugins['test.nosy']!.log.single;
    expect(line.error, isTrue);
    expect(line.text, contains('doesn\'t have the "library" permission'));

    // A plugin that throws at the top level is installed but not running.
    const broken = '''/* halcyn-plugin
{"id": "test.broken", "name": "Broken", "version": "0.1.0", "platforms": ["linux"]}
*/
throw new Error('broken on purpose');
''';
    final failure = await tester.runAsync(() => plugins.install(broken));
    expect(failure, contains('broken on purpose'));
    expect(plugins.plugins['test.broken']!.running, isFalse);

    // Platforms and versions: one for Android only, or for a later Halcyn, is refused.
    String only(String extra) =>
        '/* halcyn-plugin\n{"id": "test.other", "name": "Other", "version": "1", '
        '$extra}\n*/';
    expect(PluginManifest.parse(only('"platforms": ["linux"]')).platforms, {
      'linux',
    });
    expect(() => PluginManifest.parse(only('"x": 1')), throwsFormatException);
    await expectLater(
      plugins.install(only('"platforms": ["android"]')),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('works on Android, not Linux'),
        ),
      ),
    );
    await expectLater(
      plugins.install(only('"platforms": ["linux"], "halcyn": "99.0"')),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('needs Halcyn 99.0 or newer'),
        ),
      ),
    );
    expect(plugins.plugins.containsKey('test.other'), isFalse);

    // Reshaping the app needs "interface"; without it, hiding is refused.
    const shy = '''/* halcyn-plugin
{"id": "test.shy", "name": "Shy", "version": "1", "platforms": ["linux"]}
*/
halcyn.ui.hide('albums').catch(e => console.error(e.message));
''';
    await tester.runAsync(() => plugins.install(shy));
    await _until(tester, () => plugins.plugins['test.shy']!.log.isNotEmpty);
    expect(
      plugins.plugins['test.shy']!.log.single.text,
      contains('"interface" permission'),
    );
    expect(plugins.isHidden('albums'), isFalse);

    final theme = File('assets/themes/adaptive-slate.json').readAsStringSync();
    final reshape =
        '''/* halcyn-plugin
{"id": "test.reshape", "name": "Reshape", "version": "1",
 "platforms": ["linux", "windows"], "permissions": ["interface", "player", "library"]}
*/
let pressed = 0;
let beforePlays = 0;
halcyn.ui.hide(['smartPlaylists']);
halcyn.ui.replace('albums', { title: 'Records', render: () => [
  { type: 'heading', text: 'My own albums page' },
  { type: 'row', children: [
    { type: 'text', text: 'pressed ' + pressed, flex: 1 },
    { type: 'iconButton', icon: 'add', title: 'Press', onPress: () => { pressed++; } },
  ] },
  { type: 'switch', label: 'A switch', value: pressed > 0, onChange: () => {} },
] });
halcyn.ui.addTab({ title: 'Welcome', icon: 'home', where: 'main',
  render: () => [{ type: 'text', text: 'Welcome home' }] });
halcyn.ui.addTab({ title: 'Extras', where: 'library',
  render: () => [{ type: 'text', text: 'Library extras' }] });
halcyn.ui.addPlayerButton({ title: 'Plugin button', icon: 'star',
  run: () => halcyn.ui.notify('button pressed') });
halcyn.ui.addSettings({ title: 'Reshape settings',
  render: () => [{ type: 'text', text: 'Set me' }] });
halcyn.ui.addShortcut({ keys: 'ctrl+shift+k', run: () => halcyn.ui.notify('shortcut') });
halcyn.ui.addTheme(Object.assign($theme, { id: 'mine', name: 'Plugin theme' }));
halcyn.hooks.beforePlay(({ tracks, start }) => {
  beforePlays++;
  return { tracks: [tracks[start]], start: 0 };
});
''';
    await tester.runAsync(() => plugins.install(reshape));
    await _until(tester, () => plugins.tabs(TabPlace.main).isNotEmpty);
    await _wait(tester, 400);
    expect(plugins.isHidden('smartPlaylists'), isTrue);
    expect(find.text('Hi-Res picks'), findsNothing);
    expect(scope.themes.themes.map((t) => t.name), contains('Plugin theme'));

    // The main tab is at the top of the sidebar.
    await _sidebar(tester, 'Welcome', up: true);
    await tester.tap(find.text('Welcome'));
    await _until(tester, () => find.text('Welcome home').evaluate().isNotEmpty);

    // Albums shows the plugin's page instead, and a press renders it again.
    await _sidebar(tester, 'Records', up: true);
    await tester.tap(find.text('Records'));
    await _until(tester, () => find.text('pressed 0').evaluate().isNotEmpty);
    expect(find.text('My own albums page'), findsOneWidget);
    await tester.tap(find.byTooltip('Press'));
    await _until(tester, () => find.text('pressed 1').evaluate().isNotEmpty);
    await _shot(tester, 'plugins-4-replaced');

    // The player bar's button, and the shortcut.
    await tester.tap(find.byTooltip('Plugin button').first);
    await _until(
      tester,
      () => find.textContaining('button pressed').evaluate().isNotEmpty,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _until(
      tester,
      () => find.textContaining('shortcut').evaluate().isNotEmpty,
    );

    // Its Settings section.
    await tester.tap(find.byTooltip('Settings'));
    await _wait(tester, 600);
    await tester.scrollUntilVisible(
      find.text('Set me'),
      200,
      // Settings' General tab, held on to: its first heading scrolls out of it.
      scrollable: find.byWidget(
        tester.widget<Scrollable>(
          find
              .ancestor(
                of: find.text('Halcyn account'),
                matching: find.byType(Scrollable),
              )
              .first,
        ),
      ),
    );
    expect(find.text('Reshape settings'), findsOneWidget);

    // beforePlay: starting an album from the app plays only the song picked.
    final album = scope.library.albums.firstWhere((a) => a.tracks.length > 2);
    player.playTracks(album.tracks, 1);
    await _until(
      tester,
      () => player.queue.length == 1 && player.current == album.tracks[1],
    );
    player.pause();

    // Off: the built-in tabs come back.
    await tester.runAsync(() => plugins.setEnabled('test.reshape', false));
    await _wait(tester, 400);
    expect(plugins.isHidden('smartPlaylists'), isFalse);
    expect(player.beforePlay, isNull);
    expect(
      scope.themes.themes.map((t) => t.name),
      isNot(contains('Plugin theme')),
    );
    await tester.tap(find.byTooltip('Settings'));
    await _wait(tester, 300);

    // Events and saved values: the diary hears the next track and keeps it.
    final diary = File('plugins/examples/listening-diary.js')
        .readAsStringSync();
    expect(await tester.runAsync(() => plugins.install(diary)), isNull);
    await _wait(tester, 300);
    // Something other than what's playing.
    final others = scope.library.tracks
        .where((t) => t != player.current)
        .take(5)
        .toList();
    player.playTracks(others, 0);
    final title = others.first.title;
    await _sidebar(tester, 'Listening diary');
    await tester.tap(find.text('Listening diary'));
    await _until(
      tester,
      () => find.textContaining(title).evaluate().isNotEmpty,
    );
    await _shot(tester, 'plugins-3-diary');
    player.pause();

    // Off: its page and song-menu entry go. Removed: it's gone, saved values too.
    await tester.runAsync(
      () => plugins.setEnabled('io.github.varixxl.discover', false),
    );
    await _wait(tester, 300);
    expect(
      plugins.tabs(TabPlace.sidebar).map((p) => p.title),
      isNot(contains('Discover')),
    );
    // Only the bundled Play Counts' entry is left.
    expect(plugins.trackActions.map((a) => a.title), ['Show play count']);
    await tester.runAsync(
      () => plugins.remove('io.github.varixxl.listening-diary'),
    );
    expect(
      plugins.plugins.containsKey('io.github.varixxl.listening-diary'),
      isFalse,
    );
    expect(
      File('${folder.path}/io.github.varixxl.listening-diary.data.json')
          .existsSync(),
      isFalse,
    );
  });
}

/// Scrolls the sidebar until `label` is built and on screen.
Future<void> _sidebar(
  WidgetTester tester,
  String label, {
  bool up = false,
}) async {
  // The sidebar's list, not the search field's own scrollable.
  final list = find.descendant(
    of: find.descendant(
      of: find.byType(Sidebar),
      matching: find.byType(ListView),
    ),
    matching: find.byType(Scrollable),
  );
  final target = find.descendant(
    of: find.byType(Sidebar),
    matching: find.text(label),
  );
  await tester.scrollUntilVisible(
    target,
    label == 'Songs' || up ? -120 : 120,
    scrollable: list.first,
  );
  await _wait(tester, 200);
}

Future<void> _wait(WidgetTester tester, int ms) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _until(
  WidgetTester tester,
  bool Function() done, {
  int ms = 6000,
}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out after $ms ms');
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Flutter's own frame (not the screen, which may show other windows).
Future<void> _shot(WidgetTester tester, String name) async {
  final dir = Platform.environment['HALCYN_SHOTS'];
  if (dir == null) return;
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  await tester.runAsync(() async {
    final image = await layer.toImage(
      Offset.zero & view.size,
      pixelRatio: tester.view.devicePixelRatio,
    );
    final png = await image.toByteData(format: ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(png!.buffer.asUint8List());
  });
}
