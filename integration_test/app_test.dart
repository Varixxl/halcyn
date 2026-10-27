// Drives the real app on the desktop: browse, play, Now Playing (visualizer, lyrics, queue),
// next, albums, a smart playlist, making and deleting a playlist, search, mini player,
// themes, the equalizer and volume.
//
//   HALCYN_PW_TARGET=<pipewire node> flutter test integration_test -d linux
//
// HALCYN_PW_TARGET is required so the test never plays through the speakers; point it at a
// null sink. Set HALCYN_SHOTS=<dir> to save a screenshot of each step (Hyprland + grim).

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/main.dart' as app;
import 'package:halcyn/src/rust/api/player.dart';
import 'package:halcyn/src/signal_path_view.dart';
import 'package:halcyn/src/state/sort.dart';
import 'package:halcyn/src/ui/albums_page.dart';
import 'package:halcyn/src/ui/artists_page.dart';
import 'package:halcyn/src/ui/equalizer.dart';
import 'package:halcyn/src/ui/mini_mode.dart';
import 'package:halcyn/src/ui/now_playing.dart';
import 'package:halcyn/src/ui/queue_page.dart';
import 'package:halcyn/src/ui/search_page.dart';
import 'package:halcyn/src/ui/sidebar.dart';
import 'package:halcyn/src/ui/slate.dart';
import 'package:halcyn/src/ui/track_list.dart';
import 'package:halcyn/src/ui/visualizer.dart';
import 'package:halcyn/src/ui/widgets.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('browse, play, Now Playing, lyrics, queue, playlists, search', (
    tester,
  ) async {
    expect(
      Platform.environment['HALCYN_PW_TARGET'],
      isNotNull,
      reason: 'set HALCYN_PW_TARGET so the test plays into a null sink',
    );

    await app.main(const []);
    await _wait(tester, 2500);
    expect(find.byType(TrackRow), findsWidgets);
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    final state = scope.player;

    // Play the first song: it shows up in the sidebar card with its signal path.
    final first = tester.widget<TrackRow>(find.byType(TrackRow).first).track;
    final second = tester.widget<TrackRow>(find.byType(TrackRow).at(1)).track;
    await tester.tap(find.byType(TrackRow).first);
    // The signal path arrives once the output has opened; give it up to 4 s.
    for (var i = 0; i < 40 && state.signalPath == null; i++) {
      await _wait(tester, 100);
    }
    await _wait(tester, 300);
    await _shot('1-songs');
    expect(state.error, isNull);
    expect(state.signalPath, isNotNull);
    expect(
      find.descendant(
        of: find.byType(NowPlayingCard),
        matching: find.text(first.title),
      ),
      findsOneWidget,
    );

    // The cover card floats at the bottom right, above the volume; it hides from its
    // corner and comes back from the player bar.
    final card = tester.getRect(find.byType(NowPlayingCard));
    final volume = tester.getRect(find.byType(VolumeSlider));
    expect(card.right, greaterThan(volume.left));
    expect(card.bottom, lessThan(volume.top));
    await tester.tap(find.byTooltip('Hide'));
    await _wait(tester, 600);
    expect(
      find.descendant(
        of: find.byType(NowPlayingCard),
        matching: find.text(first.title),
      ),
      findsNothing,
    );
    await _shot('1b-card-hidden');
    await tester.tap(find.byTooltip('Show the cover card'));
    await _wait(tester, 600);
    expect(find.byTooltip('Hide the cover card'), findsOneWidget);

    // Now Playing from the card: the visualizer runs behind it, the controls sit under
    // the cover, and a wide window shows Up Next beside them.
    await tester.tap(find.byType(NowPlayingCard));
    await _wait(tester, 1500);
    expect(find.byType(SignalBadge), findsWidgets);
    final wide = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(
      find.byType(QueuePage),
      wide >= 1180 ? findsOneWidget : findsNothing,
    );
    expect(find.byType(VisualizerBackdrop), findsOneWidget);
    await _shot('2-now-playing');

    // Lyrics beside the cover, then the queue.
    await tester.tap(find.widgetWithText(Pill, 'Lyrics'));
    await _wait(tester, 1200);
    expect(find.byType(LyricsView), findsOneWidget);
    await _shot('3-lyrics');
    await tester.tap(
      find.byWidgetPredicate((w) => w is Pill && w.label.startsWith('Queue')),
    );
    await _wait(tester, 1000);
    expect(find.text(second.title), findsWidgets);
    await _shot('4-queue');

    // A phone on its side, with the queue open and closed: every control is on screen
    // and can be pressed, without scrolling.
    final queuePill = find.byWidgetPredicate(
      (w) => w is Pill && w.label.startsWith('Queue'),
    );
    for (final open in [true, false]) {
      for (final size in const [Size(915, 412), Size(740, 340)]) {
        tester.view.physicalSize = size * tester.view.devicePixelRatio;
        await _wait(tester, 900);
        final controls = {
          'close': find.byTooltip('Close (Esc)'),
          'equalizer': find.byTooltip(RegExp('^Equalizer')),
          'lyrics': find.widgetWithText(Pill, 'Lyrics'),
          'queue': queuePill,
          'shuffle': find.byTooltip(RegExp('^Shuffle')),
          'previous': find.byTooltip('Previous'),
          'play': find.byTooltip('Play/Pause (Space)'),
          'next': find.byTooltip('Next'),
          'repeat': find.byTooltip(RegExp('^Repeat')),
          'seek': find.descendant(
            of: find.byType(SeekBar),
            matching: find.byType(Slider),
          ),
        };
        for (final MapEntry(:key, :value) in controls.entries) {
          expect(
            value.hitTestable(),
            findsWidgets,
            reason:
                '$key reachable at $size, queue ${open ? 'open' : 'closed'}',
          );
        }
        expect(tester.takeException(), isNull, reason: 'overflow at $size');
        await _render(
          tester,
          '4b-landscape-${size.width.round()}-${open ? 'queue' : 'player'}',
        );
      }
      await tester.tap(queuePill.hitTestable().first);
      await _wait(tester, 900);
    }
    tester.view.resetPhysicalSize();
    await _wait(tester, 900);

    // Next track.
    await tester.tap(find.byTooltip('Next').last);
    await _wait(tester, 1500);
    expect(state.current!.path, second.path);
    expect(find.text(second.title), findsWidgets);
    // The big title follows the track (it used to stay on the first one).
    Finder headline(String title) => find.byWidgetPredicate(
      (w) => w is Text && w.data == title && w.maxLines == 2,
    );
    expect(headline(second.title), findsOneWidget);
    expect(headline(first.title), findsNothing);

    // Escape closes it.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _wait(tester, 1500);
    expect(find.byType(VisualizerBackdrop), findsNothing);

    // Albums, then one album.
    await _side(tester, 'Albums');
    await _wait(tester, 1200);
    await _shot('5-albums');
    await tester.tap(find.byType(AlbumTile).first);
    await _wait(tester, 1200);
    expect(find.widgetWithText(FilledButton, 'Play'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await _wait(tester, 800);

    // A smart playlist.
    await _side(tester, 'Hi-Res picks');
    await _wait(tester, 1000);
    for (final row in tester.widgetList<TrackRow>(find.byType(TrackRow))) {
      final t = row.track;
      expect((t.bits ?? 0) > 16 || t.sampleRate > 48000, isTrue);
    }
    await _shot('6-hi-res');

    // A playlist of our own: make it, add a song from its menu, then delete it.
    await tester.ensureVisible(find.byTooltip('New playlist'));
    await _wait(tester, 300);
    await tester.tap(find.byTooltip('New playlist'));
    await _wait(tester, 600);
    await tester.enterText(find.byType(TextField).last, 'Halcyn test');
    await _wait(tester, 300);
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await _wait(tester, 1000);
    final made = scope.playlists.playlists.last;
    // Gone even if a later step fails: playlists live in the real library.
    addTearDown(() {
      if (scope.playlists.byId(made.id) != null) scope.playlists.delete(made);
    });
    expect(made.name, 'Halcyn test');
    expect(find.text('Halcyn test'), findsWidgets);

    await _side(tester, 'Songs');
    await _wait(tester, 800);
    await tester.tap(find.byType(TrackRow).first, buttons: kSecondaryButton);
    await _wait(tester, 600);
    await tester.tap(find.text('Add to playlist…'));
    await _wait(tester, 600);
    await tester.tap(find.text('Halcyn test').last);
    await _wait(tester, 800);
    expect(scope.playlists.byId(made.id)!.paths, [first.path]);

    await _side(tester, 'Halcyn test');
    await _wait(tester, 1000);
    expect(find.byType(TrackRow), findsOneWidget);
    await _shot('7-playlist');
    await tester.tap(find.byTooltip('Playlist options'));
    await _wait(tester, 600);
    await tester.tap(find.text('Delete…'));
    await _wait(tester, 600);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await _wait(tester, 1000);
    expect(scope.playlists.byId(made.id), isNull);
    expect(find.widgetWithText(SideItem, 'Halcyn test'), findsNothing);

    // Search the songs page (top right).
    Finder field(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint,
    );
    await _side(tester, 'Songs');
    await _wait(tester, 600);
    await tester.enterText(field('Search this page'), 'joji');
    await _wait(tester, 800);
    final hits = tester.widgetList<TrackRow>(find.byType(TrackRow));
    expect(hits, isNotEmpty);
    for (final row in hits) {
      final t = row.track;
      final text = [
        t.title,
        ...t.artists,
        t.album ?? '',
      ].join(' ').toLowerCase();
      expect(text, contains('joji'));
    }
    await _shot('8-search');
    await tester.enterText(field('Search this page'), '');
    await _wait(tester, 400);

    // Search everything (sidebar): songs, albums and artists together.
    await tester.enterText(field('Search all'), 'joji');
    await _wait(tester, 1000);
    expect(find.byType(SearchPage), findsOneWidget);
    expect(find.textContaining('SONGS · '), findsOneWidget);
    expect(find.textContaining('ARTISTS · '), findsOneWidget);
    expect(find.byType(ArtistTile), findsWidgets);
    await _shot('8c-search-everything');
    await tester.enterText(field('Search all'), '');
    await _wait(tester, 300);
    await _side(tester, 'Songs');
    await _wait(tester, 600);

    // A song with synced lyrics: the Lyrics button opens them, following along.
    await tester.tap(
      find.widgetWithText(
        Pill,
        'Has lyrics · ${scope.library.withLyrics.length}',
      ),
    );
    await _wait(tester, 600);
    final sung = tester.widget<TrackRow>(find.byType(TrackRow).first).track;
    expect(scope.library.withLyrics, contains(sung.path));
    await tester.tap(find.byType(TrackRow).first);
    await _wait(tester, 1500);
    await tester.tap(find.widgetWithText(Pill, 'Lyrics'));
    await _wait(tester, 2500);
    expect(find.byType(LyricsView), findsOneWidget);
    expect(
      find.text(
        'No lyrics for this song.\nHalcyn reads a .lrc file next to it.',
      ),
      findsNothing,
    );
    await _shot('8b-lyrics');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _wait(tester, 1200);
    await tester.tap(
      find.widgetWithText(Pill, 'All · ${scope.library.tracks.length}'),
    );
    await _wait(tester, 600);

    // Mini player: on Hyprland the window floats, pinned, at phone width. Space still
    // plays and pauses, the pin toggles, and Esc brings the full app back.
    await tester.tap(find.byTooltip('Mini player (Ctrl+M)'));
    await _wait(tester, 1500);
    expect(find.byType(MiniModeView), findsOneWidget);
    expect(find.text(scope.player.current!.title), findsWidgets);
    final hyprland = Platform.environment.containsKey(
      'HYPRLAND_INSTANCE_SIGNATURE',
    );
    if (hyprland) {
      final mini = (await _client())!;
      expect(mini['floating'], isTrue);
      expect(mini['pinned'], isTrue);
      expect((mini['size'] as List)[0], 400);
    }
    await _shot('9-mini');

    // Skipping updates the mini player: titles, cover and backdrop.
    final before = scope.player.current!;
    await tester.tap(
      find.descendant(
        of: find.byType(MiniModeView),
        matching: find.byTooltip('Next'),
      ),
    );
    await _wait(tester, 2000);
    final after = scope.player.current!;
    expect(after.path, isNot(before.path));
    final mini = find.byType(MiniModeView);
    expect(
      find.descendant(of: mini, matching: find.text(after.title)),
      findsWidgets,
    );
    expect(
      tester
          .widgetList<Artwork>(
            find.descendant(of: mini, matching: find.byType(Artwork)),
          )
          .last
          .art,
      after.art,
    );
    await _shot('9b-mini-next');

    // Repeat: the button cycles off → all → one; on one, a song that ends starts again.
    final repeat = find.descendant(
      of: mini,
      matching: find.byType(RepeatButton),
    );
    await tester.tap(repeat);
    await _wait(tester, 300);
    expect(scope.player.repeat, Repeat.all);
    await tester.tap(repeat);
    await _wait(tester, 300);
    expect(scope.player.repeat, Repeat.one);
    scope.player.seek(after.durationSecs - 1.5);
    await _wait(tester, 4500);
    expect(scope.player.current!.path, after.path);
    expect(scope.player.playing, isTrue);
    expect(scope.player.position.value, lessThan(3));
    await tester.tap(repeat);
    await _wait(tester, 300);
    expect(scope.player.repeat, Repeat.off);

    final playing = scope.player.playing;
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _wait(tester, 800);
    expect(scope.player.playing, !playing);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _wait(tester, 800);
    expect(scope.player.playing, playing);

    await tester.tap(find.byTooltip('Unpin'));
    await _wait(tester, 600);
    expect(find.byTooltip('Pin on top'), findsOneWidget);
    if (hyprland) expect((await _client())!['pinned'], isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _wait(tester, 1500);
    expect(find.byType(MiniModeView), findsNothing);
    expect(find.byType(TrackRow), findsWidgets);
    if (hyprland) expect((await _client())!['floating'], isFalse);
    await _shot('10-full-again');

    // Sorting: a column title sorts the songs, again reverses them.
    await _side(tester, 'Songs');
    await _wait(tester, 800);
    List<String> artists() => [
      for (final row in tester.widgetList<TrackRow>(find.byType(TrackRow)))
        (row.track.artists.firstOrNull ?? '').toLowerCase(),
    ];
    await tester.tap(find.text('ARTIST'));
    await _wait(tester, 600);
    final up = artists();
    expect(up, [...up]..sort());
    await tester.tap(find.text('ARTIST'));
    await _wait(tester, 600);
    final down = artists();
    expect(down, [...down]..sort((a, b) => b.compareTo(a)));
    await _shot('10b-sorted');
    scope.sort.setTracks('songs', const TrackSort(TrackSortKey.title));
    await _wait(tester, 400);

    // Settings → Theme: every template is listed, and clicking one switches to it.
    await tester.tap(find.byTooltip('Settings'));
    await _wait(tester, 800);
    final themes = scope.themes;
    final original = themes.current;
    expect(themes.themes.length, greaterThanOrEqualTo(17));
    expect(find.text(original.name), findsOneWidget);
    await _shot('11-settings');
    final other = themes.themes.firstWhere((t) => t.id != original.id);
    await tester.tap(find.text(other.name));
    await _wait(tester, 800);
    expect(themes.current.id, other.id);
    await _shot('12-settings-other-theme');
    await themes.select(original);
    await _wait(tester, 400);

    // Sound: a headphone correction and bass turn the EQ on and show in the signal path;
    // volume does too. (Nothing is saved while testing.)
    final sound = scope.sound;
    await tester.tap(find.byType(EqButton).first);
    await _wait(tester, 800);
    expect(find.text('Bass'), findsOneWidget);
    sound.setBass(6);
    await _wait(tester, 600);
    expect(sound.eq, isTrue);
    expect(sound.preampDb, lessThan(0));
    expect(find.text('+6 dB'), findsOneWidget);
    expect(scope.player.signalPath?.processing, contains('EQ'));
    await _shot('13-equalizer');
    await tester.tap(find.textContaining('Headphones'));
    await _wait(tester, 800);
    await tester.enterText(find.byType(TextField).last, 'XM6');
    await _wait(tester, 400);
    await tester.tap(find.text('Sony WH-1000XM6 · cable'));
    await _wait(tester, 600);
    expect(sound.headphone, 'sony-wh-1000xm6-cable');
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await _shot('14-headphones');
    await tester.tap(find.byTooltip('Close'));
    await _wait(tester, 600);
    sound.setEq(false);
    sound.setVolume(0.5);
    await _wait(tester, 600);
    expect(scope.player.signalPath?.processing, contains('Volume'));
    expect(scope.player.signalPath?.processing, isNot(contains('EQ')));
    sound.setVolume(1);
    await _wait(tester, 600);
    expect(scope.player.signalPath?.processing, isNot(contains('Volume')));

    // Pause before leaving.
    await tester.tap(find.byTooltip('Play/Pause (Space)').first);
    await _wait(tester, 500);
  });
}

/// Pumps frames for `ms` of wall-clock time; the app has live animations, so it never
/// "settles".
Future<void> _wait(WidgetTester tester, int ms) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// This test's own window (the user may have Halcyn open too).
Future<Map<String, dynamic>?> _client() async {
  final clients = await Process.run('hyprctl', ['clients', '-j']);
  return (jsonDecode(clients.stdout as String) as List)
      .cast<Map<String, dynamic>>()
      .where((c) => c['pid'] == pid)
      .firstOrNull;
}

/// Taps a sidebar entry, scrolling the sidebar to it first: on a short window its
/// list only builds what's near the screen.
Future<void> _side(WidgetTester tester, String label) async {
  final target = find.widgetWithText(SideItem, label);
  final list = find.descendant(
    of: find.descendant(
      of: find.byType(Sidebar),
      matching: find.byType(ListView),
    ),
    matching: find.byType(Scrollable),
  );
  // Up to the top first, then down.
  for (final dy in [200.0, -200.0]) {
    for (var i = 0; i < 15 && target.evaluate().isEmpty; i++) {
      await tester.drag(list.first, Offset(0, dy));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(target);
}

/// Flutter's own frame, for when the test resizes the view without resizing the window.
Future<void> _render(WidgetTester tester, String name) async {
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

Future<void> _shot(String name) async {
  final dir = Platform.environment['HALCYN_SHOTS'];
  if (dir == null) return;
  final w = await _client();
  if (w == null) return;
  final at = w['at'] as List, size = w['size'] as List;
  await Process.run('grim', [
    '-g',
    '${at[0]},${at[1]} ${size[0]}x${size[1]}',
    '$dir/$name.png',
  ]);
}
