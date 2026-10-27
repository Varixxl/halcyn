import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/src/rust/api/library.dart';
import 'package:halcyn/src/rust/api/player.dart';
import 'package:halcyn/src/state/account.dart';
import 'package:halcyn/src/state/discord.dart';
import 'package:halcyn/src/state/library.dart';
import 'package:halcyn/src/state/player.dart';
import 'package:halcyn/src/state/playlists.dart';
import 'package:halcyn/src/state/streaming.dart';

Track _track(String path, String title) => Track(
  id: 0,
  path: path,
  title: title,
  artists: const ['Someone', 'Another'],
  album: 'An Album',
  durationSecs: 200,
  sampleRate: 44100,
  channels: 2,
  codec: 'FLAC',
  added: 0,
  plays: 0,
);

void main() {
  test('a streamed song shows its cover, the visualizer and both buttons', () {
    final start = DateTime.fromMillisecondsSinceEpoch(1000000);
    final a = discordActivity(
      PresenceSong(
        path: 'tidal:123',
        title: 'A',
        artists: const ['Someone'],
        album: 'x' * 200,
        art: 'https://resources.tidal.com/images/a/640x640.jpg',
        duration: 60,
        start: start,
      ),
    );
    expect(a['type'], 2);
    // Discord wants 2 to 128 characters.
    expect(a['details'], 'A\u{2800}');
    expect((a['assets']! as Map)['large_text'], hasLength(128));
    expect(a['timestamps'], {'start': 1000000, 'end': 1060000});
    final assets = a['assets']! as Map;
    expect(assets['large_image'], startsWith('https://resources.tidal.com'));
    expect(assets['small_image'], endsWith('visualizer.gif'));
    expect(a['buttons'], [
      {'label': 'Play on Tidal', 'url': 'https://tidal.com/browse/track/123'},
      {'label': 'Get Halcyn', 'url': downloadPage},
    ]);
  });

  test('a file shows the visualizer as its picture', () {
    final a = discordActivity(
      PresenceSong(
        path: '/music/a.flac',
        title: 'Song',
        artists: const [],
        duration: 0,
        start: DateTime.now(),
        device: 'Pixel 10a',
      ),
    );
    final assets = a['assets']! as Map;
    expect(assets['large_image'], endsWith('visualizer.gif'));
    expect(assets['small_image'], endsWith('halcyn.png'));
    expect(assets['small_text'], 'Halcyn on Pixel 10a');
    expect((a['timestamps']! as Map).containsKey('end'), isFalse);
    expect(a['buttons'], [
      {'label': 'Get Halcyn', 'url': downloadPage},
    ]);
  });

  group('DiscordPresence', () {
    late StreamController<PlayerEvent> events;
    late PlayerController player;
    late DiscordPresence presence;
    late List<Map?> sent;
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('halcyn-discord');
      events = StreamController<PlayerEvent>();
      player = PlayerController(events: events.stream);
      final library = LibraryController();
      final playlists = PlaylistsController();
      final account = AccountController(
        library: library,
        playlists: playlists,
        streaming: StreamingController(
          library: library,
          player: player,
          playlists: playlists,
          settings: File('${dir.path}/streaming.json'),
          persist: false,
        ),
        state: File('${dir.path}/account.json'),
        online: false,
      );
      sent = [];
      presence = DiscordPresence(
        player: player,
        account: account,
        settings: File('${dir.path}/discord.json'),
        device: 'Desktop',
        online: false,
        local: true,
        send: (json) => sent.add(json == null ? null : jsonDecode(json) as Map),
      )..start();
    });

    tearDown(() {
      presence.dispose();
      dir.deleteSync(recursive: true);
    });

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 900));

    test('the next song shows at once, position ticks and all', () async {
      player.queue = [
        _track('/music/a.flac', 'First'),
        _track('/music/b.flac', 'Second'),
      ];
      player.index = 0;
      events.add(const PlayerEvent.playing(playing: true));
      for (var i = 0; i < 6; i++) {
        events.add(PlayerEvent.position(secs: 30.0 + i * 0.25));
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      expect(sent.last!['details'], 'First');
      // The next song: the position starts again from 0, ticking as songs do.
      player.index = 1;
      events.add(const PlayerEvent.playing(playing: true));
      final changed = DateTime.now();
      for (var i = 0; i < 8 && sent.last!['details'] != 'Second'; i++) {
        events.add(PlayerEvent.position(secs: i * 0.1));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(sent.last!['details'], 'Second');
      expect(DateTime.now().difference(changed).inMilliseconds, lessThan(700));
    });

    test('shows what plays, clears on pause and comes back', () async {
      await settle();
      expect(sent, [null]);
      player.queue = [_track('/music/a.flac', 'First')];
      player.index = 0;
      events.add(const PlayerEvent.playing(playing: true));
      await settle();
      expect(sent.last!['details'], 'First');
      expect(sent.last!['state'], 'Someone, Another');

      events.add(const PlayerEvent.playing(playing: false));
      await settle();
      expect(sent.last, isNull);

      // A song on the phone shows while nothing plays here.
      presence.heard({
        'device': 'Pixel 10a',
        'playing': true,
        'started_at': DateTime.now().toUtc().toIso8601String(),
        'track': PresenceSong(
          path: 'ytm:abc',
          title: 'From the phone',
          artists: const ['Someone'],
          duration: 100,
          start: DateTime.now(),
        ).toJson(),
      });
      await settle();
      expect(sent.last!['details'], 'From the phone');
      expect(
        (sent.last!['assets'] as Map)['small_text'],
        'Halcyn on Pixel 10a',
      );

      // This computer's own song wins.
      events.add(const PlayerEvent.playing(playing: true));
      await settle();
      expect(sent.last!['details'], 'First');

      await presence.setOn(false);
      await settle();
      expect(sent.last, isNull);
    });
  });
}
