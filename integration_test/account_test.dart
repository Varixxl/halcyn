// Against the real account server, with a throwaway account, a library of its own and
// keyring entries of its own: `HALCYN_TEST_ACCOUNT=1 flutter test
// integration_test/account_test.dart -d linux`. Skipped otherwise.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/src/rust/api/library.dart';
import 'package:halcyn/src/rust/api/player.dart';
import 'package:halcyn/src/rust/api/streaming.dart';
import 'package:halcyn/src/rust/frb_generated.dart';
import 'package:halcyn/src/state/account.dart';
import 'package:halcyn/src/state/discord.dart';
import 'package:halcyn/src/state/library.dart';
import 'package:halcyn/src/state/player.dart';
import 'package:halcyn/src/state/playlists.dart';
import 'package:halcyn/src/state/streaming.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('an account carries sign-ins and playlists to another device', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await RustLib.init();
      final temp = Directory.systemTemp.createTempSync('halcyn-account');
      final data = Directory('${temp.path}/data')..createSync();
      final cache = Directory('${temp.path}/cache')..createSync();
      await libraryOpen(dataDir: data.path, cacheDir: cache.path);
      await streamingInit(dataDir: data.path, cacheDir: cache.path);
      final library = LibraryController();
      await library.load();
      final playlists = PlaylistsController();
      await playlists.load();
      final player = PlayerController(
        events: const Stream<PlayerEvent>.empty(),
      );
      final streaming = StreamingController(
        library: library,
        player: player,
        playlists: playlists,
        settings: File('${data.path}/streaming.json'),
        persist: false,
      );
      await streaming.load();
      AccountController device(String name) => AccountController(
        library: library,
        playlists: playlists,
        streaming: streaming,
        state: File('${data.path}/account-$name.json'),
        keyPrefix: 'halcyn-test-$name',
      );
      Future<void> settle(AccountController account) async {
        await account.sync();
        while (account.syncing) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(account.syncError, isNull);
      }

      final email =
          'halcyn-test-${Random().nextInt(1 << 32).toRadixString(16)}@example.com';
      const password = 'correct horse battery';

      // Device A: a new account, YouTube Music linked, a playlist with a streamed
      // song and a file from some other computer.
      final a = device('a');
      await a.load();
      await a.signUp(email, password);
      try {
        expect(a.signedIn, isTrue);
        expect(a.recoveryKey!.split('-'), hasLength(14));
        await streamingImport(
          serviceName: 'ytm',
          saved: jsonEncode({
            'cookie': 'SAPISID=abc; HSID=x',
            'name': 'Tester',
          }),
        );
        await streaming.refreshAccounts();
        final [song] = await streamingRemember(
          tracks: [
            RemoteTrack(
              path: 'ytm:dQw4w9WgXcQ',
              title: 'Never Gonna Give You Up',
              artists: ['Rick Astley'],
              album: 'Whenever You Need Somebody',
              durationSecs: 213,
              artUrl: null,
              quality: 'AAC',
              isrc: null,
            ),
          ],
        );
        library.addStreams([song]);
        final list = await playlists.create('Synced', [
          song.path,
          '/elsewhere/Music/x.flac',
        ]);
        await settle(a);

        // The server has the sign-in only as ciphertext, and the songs' tags.
        final db = Supabase.instance.client;
        final items = await db.from('vault_items').select();
        expect(items.single['service'], 'ytm');
        expect(items.single['ciphertext'], isNot(contains('SAPISID')));
        final rows = await db.from('playlists').select();
        expect(rows.single['name'], 'Synced');
        expect(
          (rows.single['entries'] as List).first,
          containsPair('t', 'Never Gonna Give You Up'),
        );

        // Device B: nothing linked, no playlists. A wrong password is refused.
        await a.signOut();
        await streamingYoutubeSignOut();
        await streaming.refreshAccounts();
        playlists.delete(list);
        expect(streaming.youtube, isFalse);
        final b = device('b');
        await b.load();
        await expectLater(
          b.signIn(email, 'not the password'),
          throwsA(isA<AuthException>()),
        );
        await b.signIn(email, password);
        await settle(b);
        expect(streaming.youtube, isTrue);
        expect(streaming.accounts!.youtube, 'Tester');
        final synced = playlists.playlists.single;
        expect(synced.name, 'Synced');
        expect(synced.paths, [song.path, '/elsewhere/Music/x.flac']);

        // A phone's song reaches the computer, for Discord.
        final phoneEvents = StreamController<PlayerEvent>();
        final phonePlayer = PlayerController(events: phoneEvents.stream);
        final phone = DiscordPresence(
          player: phonePlayer,
          account: b,
          settings: File('${data.path}/discord-phone.json'),
          device: 'Pixel 10a',
          persist: false,
          local: false,
        )..start();
        final shown = <Map?>[];
        final computer = DiscordPresence(
          player: player,
          account: b,
          settings: File('${data.path}/discord.json'),
          device: 'Desktop',
          persist: false,
          local: true,
          send: (json) =>
              shown.add(json == null ? null : jsonDecode(json) as Map),
        )..start();
        phonePlayer.queue = [song];
        phonePlayer.index = 0;
        phoneEvents.add(const PlayerEvent.playing(playing: true));
        final until = DateTime.now().add(const Duration(seconds: 20));
        while (shown.lastOrNull?['details'] != song.title &&
            DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        expect(shown.last!['details'], song.title);
        expect(
          (shown.last!['assets'] as Map)['small_text'],
          'Halcyn on Pixel 10a',
        );
        // Paused on the phone: gone from the computer too.
        phoneEvents.add(const PlayerEvent.playing(playing: false));
        final until2 = DateTime.now().add(const Duration(seconds: 20));
        while (shown.last != null && DateTime.now().isBefore(until2)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        expect(shown.last, isNull);
        phone.dispose();
        computer.dispose();

        // Deleting it on B deletes it everywhere.
        playlists.delete(synced);
        await settle(b);
        final after = await db.from('playlists').select();
        expect(after.single['deleted'], isTrue);
        await b.deleteAccount();
        expect(b.signedIn, isFalse);
      } finally {
        // Gone even if a step failed.
        if (Supabase.instance.client.auth.currentUser != null) {
          await Supabase.instance.client.rpc<void>('delete_account');
        }
        temp.deleteSync(recursive: true);
      }
    });
  }, skip: !Platform.environment.containsKey('HALCYN_TEST_ACCOUNT'));
}
