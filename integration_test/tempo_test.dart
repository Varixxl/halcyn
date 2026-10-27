// Pitch and speed in the real engine, on the test's null sink (HALCYN_PW_TARGET).
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/main.dart' as app;
import 'package:halcyn/src/rust/api/library.dart';
import 'package:halcyn/src/ui/equalizer.dart';
import 'package:halcyn/src/ui/slate.dart';
import 'package:halcyn/src/ui/widgets.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pitch and speed change apart, and come back bit-exact', (
    tester,
  ) async {
    expect(Platform.environment['HALCYN_PW_TARGET'], isNotNull);
    await app.main(const []);
    tester.view.physicalSize =
        const Size(1280, 800) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await _wait(tester, 2000);
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    final player = scope.player;
    final sound = scope.sound;
    // The user's own settings come back afterwards.
    final (pitch, speed) = (sound.pitch, sound.speed);
    addTearDown(() async {
      sound
        ..setPitch(pitch)
        ..setSpeed(speed);
      player.pause();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 800)),
      );
    });
    sound.resetTempo();

    // A song longer than a minute, from its start.
    final Track song = scope.library.tracks.firstWhere(
      (t) => !t.path.contains(':') && t.durationSecs > 60,
    );
    player.playTracks([song], 0);
    await _until(tester, () => player.playing && player.signalPath != null);
    await _wait(tester, 1000);
    expect(player.signalPath!.processing, isNot(contains('Speed')));

    // Twice as fast: the position runs at twice the clock.
    sound.setSpeed(2);
    await _until(
      tester,
      () => player.signalPath?.processing.contains('Speed 2×') ?? false,
    );
    await _wait(tester, 600);
    var from = player.position.value;
    var clock = DateTime.now();
    await _wait(tester, 3000);
    var rate =
        (player.position.value - from) /
        (DateTime.now().difference(clock).inMilliseconds / 1000);
    expect(rate, closeTo(2, 0.25));
    expect(player.signalPath!.bitExact, isFalse);

    // Pitch up three semitones, back to normal speed: the position runs at the clock.
    sound
      ..setSpeed(1)
      ..setPitch(3);
    await _until(tester, () {
      final p = player.signalPath?.processing ?? '';
      return p.contains('Pitch +3') && !p.contains('Speed');
    });
    await _wait(tester, 600);
    from = player.position.value;
    clock = DateTime.now();
    await _wait(tester, 3000);
    rate =
        (player.position.value - from) /
        (DateTime.now().difference(clock).inMilliseconds / 1000);
    expect(rate, closeTo(1, 0.15));

    // Dragging a slider shows the value but doesn't restart the song until it's let go.
    sound.setPitch(5, live: false);
    await _wait(tester, 800);
    expect(sound.pitch, 5);
    expect(player.signalPath!.processing, contains('Pitch +3'));

    // The panel's tab.
    await tester.tap(find.byType(EqButton).first);
    await _wait(tester, 600);
    await tester.tap(find.textContaining('Pitch & speed'));
    await _wait(tester, 600);
    expect(find.text('+5 semitones'), findsOneWidget);
    expect(find.text('Normal'), findsOneWidget);
    await _shot(tester, 'tempo-panel');
    await tester.tap(find.widgetWithText(Pill, '1.25×'));
    await _until(
      tester,
      () => player.signalPath?.processing.contains('Speed 1.25×') ?? false,
    );
    expect(player.signalPath!.processing, contains('Pitch +5'));

    // Both back: bit-exact again (the library is lossless, and the EQ is the user's).
    sound.resetTempo();
    await _until(tester, () {
      final p = player.signalPath?.processing ?? '';
      return !p.contains('Pitch') && !p.contains('Speed');
    });
    if (!sound.eq && sound.volume == 1) {
      expect(player.signalPath!.bitExact, isTrue);
    }
  });
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
  int ms = 8000,
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
