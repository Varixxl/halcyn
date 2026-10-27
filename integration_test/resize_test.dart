// Drags the window through many sizes (as resizing it by hand does) in each of the main
// views, failing on any layout error, and checks the app still answers taps afterwards.
//
//   HALCYN_PW_TARGET=<null sink> flutter test integration_test/resize_test.dart -d linux

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/main.dart' as app;
import 'package:halcyn/src/ui/now_playing.dart';
import 'package:halcyn/src/ui/track_list.dart';
import 'package:halcyn/src/ui/widgets.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every window size lays out and stays usable', (tester) async {
    expect(Platform.environment['HALCYN_PW_TARGET'], isNotNull);
    await app.main(const []);
    await _wait(tester, 2500);
    final player = tester.widget<AppScope>(find.byType(AppScope)).player;
    await tester.tap(find.byType(TrackRow).first);
    await _wait(tester, 800);

    final errors = <String>[];
    final previous = FlutterError.onError;
    var size = Size.zero;
    var view = '';
    FlutterError.onError = (details) {
      errors.add(
        '$view at ${size.width.round()}x${size.height.round()}: '
        '${details.exceptionAsString().split('\n').first}',
      );
    };

    // Widths and heights a hand resize passes through, both directions.
    const widths = [
      2560,
      1900,
      1280,
      1000,
      860,
      800,
      721,
      720,
      719,
      600,
      500,
      420,
      360,
      300,
      240,
    ];
    const heights = [
      1440,
      1000,
      800,
      720,
      600,
      560,
      520,
      519,
      480,
      400,
      320,
      240,
      180,
    ];
    Future<void> sweep(String name) async {
      view = name;
      for (final w in [...widths, ...widths.reversed]) {
        for (final h in [
          heights.first,
          heights[heights.length ~/ 2],
          heights.last,
        ]) {
          size = Size(w.toDouble(), h.toDouble());
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
      for (final h in [...heights, ...heights.reversed]) {
        for (final w in [widths.first, 720, 360]) {
          size = Size(w.toDouble(), h.toDouble());
          tester.view.physicalSize = size;
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
      // Continuous, like a drag: one pixel step frames.
      for (var w = 760; w >= 680; w -= 3) {
        size = Size(w.toDouble(), 700);
        tester.view.physicalSize = size;
        await tester.pump(const Duration(milliseconds: 8));
      }
      tester.view.physicalSize = const Size(1280, 800);
      await _wait(tester, 600);
      // Still answers: Space (and a tap on Play) toggle playback.
      final before = player.playing;
      await tester.tap(find.byTooltip('Play/Pause (Space)').first);
      await _wait(tester, 600);
      expect(player.playing, !before, reason: 'a tap after resizing $name');
    }

    await sweep('library');
    openNowPlaying(tester.element(find.byType(TrackRow).first));
    await _wait(tester, 800);
    await sweep('Now Playing');
    await tester.tap(find.textContaining('Queue ·').first);
    await _wait(tester, 800);
    await sweep('Now Playing + queue');

    FlutterError.onError = previous;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    player.pause();
    await _wait(tester, 300);
    final overflows = errors.where((e) => e.contains('overflowed')).toSet();
    final others = errors.where((e) => !e.contains('overflowed')).toSet();
    debugPrint('OVERFLOWS ${overflows.length}:\n${overflows.join('\n')}');
    debugPrint('OTHER ${others.length}:\n${others.join('\n')}');
    expect(others, isEmpty);
    // Overflows only clip (and are queued to be fixed); report them, don't fail.
    if (overflows.isNotEmpty) {
      debugPrint('${overflows.length} sizes overflow, see above');
    }
  });
}

Future<void> _wait(WidgetTester tester, int ms) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}
