// Screenshots every theme template in each window: songs, albums, Now Playing, mini.
//
//   HALCYN_PW_TARGET=<null sink> HALCYN_SHOTS=<dir> flutter test integration_test/themes_tour_test.dart -d linux
//
// Puts the user's own theme choice back at the end.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/main.dart' as app;
import 'package:halcyn/src/ui/sidebar.dart';
import 'package:halcyn/src/ui/track_list.dart';
import 'package:halcyn/src/ui/widgets.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every theme in every window', (tester) async {
    expect(Platform.environment['HALCYN_PW_TARGET'], isNotNull);
    final dir = Platform.environment['HALCYN_SHOTS'];
    expect(dir, isNotNull);

    await app.main(const []);
    await _wait(tester, 2500);
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    final themes = scope.themes;
    final original = themes.current;

    // Something playing, so the sidebar card, Now Playing and the mini player have a cover.
    await tester.tap(find.byType(TrackRow).at(1));
    await _wait(tester, 1500);
    await tester.tap(find.byTooltip('Play/Pause (Space)').first);
    await _wait(tester, 400);

    try {
      for (final theme in themes.themes) {
        await themes.select(theme);
        await _wait(tester, 700);
        await _shot('$dir/${theme.id}-1-songs.png');

        await tester.tap(find.text('Albums').first);
        await _wait(tester, 700);
        await _shot('$dir/${theme.id}-2-albums.png');
        await tester.tap(find.text('Songs').first);
        await _wait(tester, 400);

        await tester.tap(find.byType(NowPlayingCard));
        await _wait(tester, 1200);
        await _shot('$dir/${theme.id}-3-now-playing.png');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _wait(tester, 1200);

        await scope.window.setMini(true);
        await _wait(tester, 1500);
        await _shot('$dir/${theme.id}-4-mini.png');
        await scope.window.setMini(false);
        await _wait(tester, 1500);
      }
    } finally {
      await themes.select(original);
    }
  });
}

Future<void> _wait(WidgetTester tester, int ms) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _shot(String path) async {
  final clients = await Process.run('hyprctl', ['clients', '-j']);
  final w = (jsonDecode(clients.stdout as String) as List)
      .cast<Map<String, dynamic>>()
      .where((c) => c['pid'] == pid)
      .firstOrNull;
  if (w == null) return;
  final at = w['at'] as List, size = w['size'] as List;
  await Process.run('grim', [
    '-g',
    '${at[0]},${at[1]} ${size[0]}x${size[1]}',
    path,
  ]);
}
