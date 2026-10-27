// Casting, end to end on one machine: the app is the receiver, and the test plays a phone
// (a second PlayerController plus a CastController) connecting to it over the network.
//
//   HALCYN_PW_TARGET=<null sink> HALCYN_CAST_PORT=47331 HALCYN_CAST_DISCOVERY_PORT=47330 \
//     flutter test integration_test/cast_test.dart -d linux
//
// Its own ports keep it apart from a Halcyn the user has open. HALCYN_SHOTS=<dir> saves
// screenshots.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/main.dart' as app;
import 'package:halcyn/src/cast/protocol.dart';
import 'package:halcyn/src/cast/sender.dart';
import 'package:halcyn/src/rust/api/library.dart';
import 'package:halcyn/src/signal_path_view.dart';
import 'package:halcyn/src/state/library.dart';
import 'package:halcyn/src/state/player.dart';
import 'package:halcyn/src/state/spectrum.dart';
import 'package:halcyn/src/ui/cast.dart';
import 'package:halcyn/src/ui/widgets.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a phone finds, pairs with, plays through and controls the app', (
    tester,
  ) async {
    final env = Platform.environment;
    expect(env['HALCYN_PW_TARGET'], isNotNull, reason: 'use a null sink');
    expect(env['HALCYN_CAST_PORT'], isNotNull, reason: 'use test ports');
    expect(env['HALCYN_CAST_DISCOVERY_PORT'], isNotNull);

    await app.main(const []);
    await _wait(tester, 2500);
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    final desktop = scope.player;
    final receiver = scope.receiver;
    await receiver.setEnabled(true);
    expect(receiver.port, int.parse(env['HALCYN_CAST_PORT']!));

    // The phone: its own player (no engine) and art cache.
    final temp = await Directory.systemTemp.createTemp('halcyn-cast-');
    final phoneArt = Directory('${temp.path}/art')..createSync();
    final phone = PlayerController(events: const Stream.empty());
    final cast = CastController(
      player: phone,
      artDir: phoneArt.path,
      settings: File('${temp.path}/cast.json'),
      receiverId: () => 'phone',
      persist: false,
    );
    await cast.load(deviceName: 'Test phone');

    // Discovery: the app answers a probe. (Sent straight to it: this machine's firewall
    // may drop broadcasts, which the phone needs allowed.)
    final reply = await tester.runAsync(() async {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final answer = Completer<Map>();
      socket.listen((_) {
        final d = socket.receive();
        if (d != null && !answer.isCompleted) {
          answer.complete(jsonDecode(utf8.decode(d.data)) as Map);
        }
      });
      socket.send(
        utf8.encode(jsonEncode({'halcyn': 'discover', 'id': 'phone'})),
        InternetAddress.loopbackIPv4,
        int.parse(env['HALCYN_CAST_DISCOVERY_PORT']!),
      );
      final m = await answer.future.timeout(const Duration(seconds: 2));
      socket.close();
      return m;
    });
    expect(reply, {
      'halcyn': 'here',
      'id': receiver.id,
      'name': receiver.name,
      'port': receiver.port,
    });
    final address = '127.0.0.1:${receiver.port}';

    // First connection: the app asks before letting it in.
    unawaited(cast.connectTo(address));
    await _until(tester, () => cast.status == CastStatus.approving);
    await _until(tester, () => find.text('Allow').evaluate().isNotEmpty);
    expect(find.text('Let Test phone play here?'), findsOneWidget);
    await _shot(tester, 'cast-1-approve');
    await tester.tap(find.text('Allow'));
    await _until(tester, () => cast.connected);
    expect(phone.casting, isTrue);
    expect(receiver.connected, ['Test phone']);
    expect(receiver.devices.single.name, 'Test phone');

    // A song the desktop has too (same tags, the phone's own path): the desktop plays its
    // own copy, so nothing is sent.
    final library = scope.library.tracks;
    final own = library.firstWhere(
      (t) => t.codec == 'FLAC' && t.durationSecs > 60 && t.durationSecs < 600,
    );
    final phoneCopy = _withPath(own, '/storage/emulated/0/Music/copy.flac');
    phone.playTracks([phoneCopy], 0);
    await _until(tester, () => desktop.current?.path == own.path);
    await _until(tester, () => desktop.playing && phone.playing);
    expect(cast.sending, isNull);
    // The phone mirrors the desktop: its own track, with the desktop's signal path.
    expect(phone.current?.path, phoneCopy.path);
    await _until(tester, () => phone.signalPath != null);
    expect(phone.signalPath!.output, desktop.signalPath!.output);
    // …which the phone labels as the desktop's.
    expect(
      outputLine(phone.signalPath!, cast.device!.name),
      'On ${cast.device!.name} · ${desktop.signalPath!.output}',
    );

    // Controls.
    phone.pause();
    await _until(tester, () => !desktop.playing && !phone.playing);
    phone.seek(30);
    await _until(tester, () => (desktop.position.value - 30).abs() < 1);
    phone.play();
    await _until(tester, () => desktop.playing);
    await _until(tester, () => phone.position.value > 30.2);
    cast.setVolume(0.4);
    await _until(tester, () => scope.sound.volume == 0.4);

    // The visualizer's bands come over too.
    final bands = Completer<Float32List>();
    final listening = spectrum.listen((b) {
      if (!bands.isCompleted && b.any((v) => v > 0)) bands.complete(b);
    });
    await _until(tester, () => bands.isCompleted, ms: 4000);
    await listening.cancel();
    expect((await bands.future).length, 64);

    // A song only the phone has: the phone sends it, then the desktop plays it.
    final source = library.firstWhere(
      (t) => t.codec == 'FLAC' && t.path != own.path && t.durationSecs < 400,
    );
    final phoneOnly = File('${temp.path}/phone only.flac');
    await tester.runAsync(() => File(source.path).copy(phoneOnly.path));
    final lrc = File(lyricsPath(phoneOnly.path))
      ..writeAsStringSync(
        '[00:00.00]Only on the phone\n[00:10.00]Second line\n',
      );
    final unique = _withPath(source, phoneOnly.path, title: 'Cast test song');
    phone.playTracks([unique, phoneCopy], 0);
    await _wait(tester, 100);
    await _shot(tester, 'cast-2-sending');
    final sentPath = '${receiver.castDir.path}/${castName(unique)}';
    await _until(tester, () => desktop.current?.path == sentPath, ms: 15000);
    await _until(tester, () => desktop.playing && desktop.error == null);
    expect(desktop.current!.title, 'Cast test song');
    expect(
      File(sentPath).lengthSync(),
      File(source.path).lengthSync(),
      reason: 'the file arrives whole',
    );
    expect(
      File(lyricsPath(sentPath)).readAsStringSync(),
      lrc.readAsStringSync(),
    );
    // The phone shows its own track, not a copy of the desktop's.
    await _until(tester, () => identical(phone.current, unique));
    expect(phone.queue.length, 2);

    // Next moves to the song the desktop has.
    phone.next();
    await _until(tester, () => desktop.current?.path == own.path);
    await _until(tester, () => phone.index == 1);

    // Songs queued on the desktop show up on the phone, with their covers fetched.
    final desktopSongs = library
        .where((t) => t.art != null && t.path != own.path)
        .take(3)
        .toList();
    desktop.addToQueue(desktopSongs);
    await _until(tester, () => phone.queue.length == 5);
    await _until(
      tester,
      () => phone.queue.skip(2).every((t) => t.art != null),
      ms: 5000,
    );
    expect(
      File('${phoneArt.path}/${desktopSongs.first.art}-512.jpg').existsSync(),
      isTrue,
    );
    // Lyrics for a desktop song come from the desktop.
    final withLyrics = library
        .where((t) => File(lyricsPath(t.path)).existsSync())
        .firstOrNull;
    if (withLyrics != null) {
      desktop.addToQueue([withLyrics]);
      await _until(tester, () => phone.queue.length == 6);
      final text = await tester.runAsync(() => cast.lyrics(withLyrics.path));
      expect(text, File(lyricsPath(withLyrics.path)).readAsStringSync());
    }
    // But not files that aren't queued.
    final other = await tester.runAsync(() => cast.lyrics('/etc/passwd'));
    expect(other, isNull);

    // Jumping in the queue from the phone.
    phone.jumpTo(2);
    await _until(
      tester,
      () => desktop.current?.path == desktopSongs.first.path,
    );

    // The app's own cast panel and settings.
    await tester.tap(find.byType(CastButton).first);
    await _wait(tester, 2500);
    await _shot(tester, 'cast-3-panel');
    await tester.tapAt(const Offset(8, 8));
    await _wait(tester, 400);

    // Settings shows who's casting here, and the updates section.
    await tester.tap(find.byTooltip('Settings').first);
    await _wait(tester, 600);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -3000));
    await _wait(tester, 600);
    expect(find.text('Let other devices play here'), findsOneWidget);
    expect(find.text('Playing from Test phone'), findsOneWidget);
    expect(find.text('Check for updates automatically'), findsOneWidget);
    await _shot(tester, 'cast-4-settings');

    // Stopping: the phone gets its own queue back and the desktop plays on.
    await tester.runAsync(cast.disconnect);
    expect(phone.casting, isFalse);
    expect(phone.queue, isEmpty);
    await _until(tester, () => receiver.connected.isEmpty);
    expect(desktop.playing, isTrue);

    // Reconnecting needs no approval, with the token from before.
    unawaited(cast.connectTo(address));
    await _until(tester, () => cast.connected);
    expect(find.text('Allow'), findsNothing);
    await tester.runAsync(cast.disconnect);

    // Taking the approval back makes it ask again.
    receiver.forget(receiver.devices.single.id);
    unawaited(cast.connectTo(address));
    await _until(tester, () => find.text('Allow').evaluate().isNotEmpty);
    await tester.tap(find.text('Don\'t allow'));
    await _until(tester, () => cast.status == CastStatus.idle);
    expect(cast.error, contains('didn\'t allow'));

    desktop.pause();
    await _wait(tester, 300);
    cast.dispose();
    await tester.runAsync(() => temp.delete(recursive: true));
    await tester.runAsync(() async {
      for (final f in receiver.castDir.listSync()) {
        f.deleteSync();
      }
    });
  });
}

Track _withPath(Track t, String path, {String? title}) => trackFromJson(
  {...trackToJson(t), 'title': title ?? t.title},
  id: t.id,
  path: path,
  art: t.art,
);

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
