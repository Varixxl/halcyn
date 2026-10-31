// Artists and albums open from their names: a song row's artist and album columns, the
// song menu, and Now Playing; the library's pages look them up on Tidal and YouTube Music.
//
//   HALCYN_PW_TARGET=<pipewire node> flutter test integration_test/lookup_test.dart -d linux
//
// The streaming steps run against whichever services the app has linked, live.

import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/main.dart' as app;
import 'package:halcyn/src/state/streaming.dart';
import 'package:halcyn/src/ui/albums_page.dart';
import 'package:halcyn/src/ui/artists_page.dart';
import 'package:halcyn/src/ui/lookup.dart';
import 'package:halcyn/src/ui/now_playing.dart';
import 'package:halcyn/src/ui/streaming.dart';
import 'package:halcyn/src/ui/track_list.dart';
import 'package:halcyn/src/ui/widgets.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('artists and albums open from their names', (tester) async {
    expect(
      Platform.environment['HALCYN_PW_TARGET'],
      isNotNull,
      reason: 'set HALCYN_PW_TARGET so the test plays into a null sink',
    );
    await app.main(const []);
    tester.view.physicalSize =
        const Size(1440, 900) * tester.view.devicePixelRatio;
    await _wait(tester, 2500);
    final scope = tester.widget<AppScope>(find.byType(AppScope));

    // A song by one artist, on an album.
    final rows = find.byType(TrackRow);
    var at = 0;
    while (true) {
      final t = tester.widget<TrackRow>(rows.at(at)).track;
      if (t.artists.length == 1 && t.album != null) break;
      at++;
    }
    final row = rows.at(at);
    final track = tester.widget<TrackRow>(row).track;
    final links = find.descendant(of: row, matching: find.byType(NameLinks));

    // The artist column opens the library's artist page.
    await tester.tap(links.first);
    await _wait(tester, 800);
    expect(find.byType(ArtistPage), findsOneWidget);
    expect(find.text(track.artists.single), findsWidgets);
    await _shot(tester, 'lookup-1-artist');

    final services = scope.streaming.services;
    if (services.isNotEmpty) {
      // …which looks them up on each linked service.
      for (final s in services) {
        expect(
          find.widgetWithText(OutlinedButton, serviceNames[s]!),
          findsOneWidget,
        );
      }
      await tester.tap(
        find.widgetWithText(OutlinedButton, serviceNames[services.first]!),
      );
      await _until(
        tester,
        () =>
            find.text('POPULAR').evaluate().isNotEmpty ||
            find.textContaining('ONE OF THESE').evaluate().isNotEmpty ||
            find.textContaining('NO ARTIST').evaluate().isNotEmpty,
      );
      await _wait(tester, 1500);
      await _shot(tester, 'lookup-2-service-artist');
      expect(find.byType(ServiceArtistPage), findsOneWidget);
      if (find.text('ALBUMS').evaluate().isNotEmpty) {
        // An album card opens its songs.
        final card = find.descendant(
          of: find.byType(ServiceArtistPage),
          matching: find.byType(RemoteCard),
        );
        await tester.tap(card.first);
        await _until(
          tester,
          () => find
              .descendant(
                of: find.byType(RemoteListPage),
                matching: find.byType(TrackRow),
              )
              .evaluate()
              .isNotEmpty,
        );
        await _wait(tester, 1000);
        await _shot(tester, 'lookup-3-service-album');
        await tester.tap(find.text('Back').last);
        await _wait(tester, 600);
      }
      await tester.tap(find.text('Back').last);
      await _wait(tester, 600);
    }
    await tester.tap(find.byTooltip('Back'));
    await _wait(tester, 600);

    // The album column opens the library's album page.
    await tester.tap(links.last);
    await _wait(tester, 800);
    expect(find.byType(AlbumPage), findsOneWidget);
    await _shot(tester, 'lookup-4-album');
    if (services.isNotEmpty) {
      await tester.tap(
        find.widgetWithText(OutlinedButton, serviceNames[services.last]!),
      );
      await _until(
        tester,
        () =>
            find.byType(RemoteListPage).evaluate().isNotEmpty ||
            find.textContaining('ONE OF THESE').evaluate().isNotEmpty ||
            find.textContaining('NOT ON').evaluate().isNotEmpty,
      );
      await _wait(tester, 1500);
      await _shot(tester, 'lookup-5-service-album');
      expect(find.byType(ServiceAlbumPage), findsOneWidget);
      await tester.tap(find.text('Back').last);
      await _wait(tester, 600);
    }
    await tester.tap(find.byTooltip('Back'));
    await _wait(tester, 600);

    // The song menu has both.
    await tester.tap(row, buttons: 2);
    await _wait(tester, 500);
    expect(find.text('Go to artist'), findsOneWidget);
    expect(find.text('Go to album'), findsOneWidget);
    await tester.tap(find.text('Go to album'));
    await _wait(tester, 800);
    expect(find.byType(AlbumPage), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await _wait(tester, 600);

    // From Now Playing, the artist opens in the main view, Now Playing closed.
    await tester.tap(row);
    await _wait(tester, 1000);
    openNowPlaying(tester.element(find.byType(TrackRow).first));
    await _wait(tester, 1500);
    final playing = find.descendant(
      of: find.byType(NowPlayingPage),
      matching: find.byType(NameLinks),
    );
    await tester.tap(playing.first);
    await _wait(tester, 1200);
    expect(find.byType(NowPlayingPage), findsNothing);
    expect(find.byType(ArtistPage), findsOneWidget);
    await _shot(tester, 'lookup-6-from-now-playing');
    scope.player.pause();
  });
}

Future<void> _wait(WidgetTester tester, int ms) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Pumps until [done] (a live service answering), up to 20 s.
Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (!done()) {
    await _shot(tester, 'lookup-timeout');
    for (final t in find.byType(Text).evaluate().take(60)) {
      // ignore: avoid_print
      print(
        '  text: ${(t.widget as Text).data ?? (t.widget as Text).textSpan?.toPlainText()}',
      );
    }
  }
  expect(done(), isTrue, reason: 'the service didn\'t answer in 20 s');
}

/// Flutter's own frame: the test resizes the view, not the window.
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
