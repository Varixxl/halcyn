import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/src/rust/api/library.dart';
import 'package:halcyn/src/rust/api/player.dart';
import 'package:halcyn/src/state/fetcher.dart';
import 'package:halcyn/src/state/library.dart';
import 'package:halcyn/src/state/player.dart';

Track _track(String path, String title, {String? album = 'Blue "Hour"'}) =>
    Track(
      id: 0,
      path: path,
      title: title,
      artists: const ['Someone'],
      album: album,
      durationSecs: 201.4,
      sampleRate: 44100,
      channels: 2,
      codec: 'FLAC',
      added: 0,
      plays: 0,
    );

void main() {
  late Directory dir;
  late LibraryController library;
  late List<Uri> asked;
  late List<(List<String>, Uint8List)> stored;

  Fetcher fetcher({bool art = true}) => Fetcher(
    library: library,
    player: PlayerController(events: const Stream<PlayerEvent>.empty()),
    settings: File('${dir.path}/fetch.json'),
    userAgent: 'Halcyn/test',
    musicBrainzGap: Duration.zero,
    get: (url) async {
      asked.add(url);
      final body = switch (url.host) {
        'musicbrainz.org' => jsonEncode({
          'release-groups': [
            {'id': 'weak', 'score': 40},
            {'id': 'rg1', 'score': 100},
          ],
        }),
        'coverartarchive.org' when url.path.contains('rg1') => 'JPEG',
        'lrclib.net' when url.queryParameters['track_name'] == 'One' =>
          jsonEncode({'syncedLyrics': '[00:01.00] hello'}),
        _ => null,
      };
      return body == null
          ? (404, Uint8List(0))
          : (200, Uint8List.fromList(utf8.encode(body)));
    },
    storeArt: (paths, image) async {
      stored.add((paths, image));
      return 'key';
    },
    reload: () async {},
  )..art = art;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('halcyn-fetcher');
    downloadedLyricsDir = Directory('${dir.path}/lyrics');
    asked = [];
    stored = [];
    final tracks = [_track('/m/1.flac', 'One'), _track('/m/2.flac', 'Two')];
    final album = Album('Blue "Hour"', 'Someone')..tracks.addAll(tracks);
    library = LibraryController()
      ..tracks = tracks
      ..albums = [album];
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('finds a cover and lyrics, then leaves them be', () async {
    final f = fetcher();
    await f.run();

    // MusicBrainz is asked about the album (quotes escaped); a weak match is skipped.
    final search = asked.firstWhere((u) => u.host == 'musicbrainz.org');
    expect(
      search.queryParameters['query'],
      r'releasegroup:"Blue \"Hour\"" AND artist:"Someone"',
    );
    expect(
      asked.where((u) => u.host == 'coverartarchive.org').map((u) => u.path),
      ['/release-group/rg1/front-500'],
    );
    expect(stored.single.$1, ['/m/1.flac', '/m/2.flac']);
    expect(utf8.decode(stored.single.$2), 'JPEG');

    // LRCLIB is asked about both songs; one had lyrics, saved in Halcyn's folder.
    final lyric = asked.firstWhere((u) => u.host == 'lrclib.net');
    expect(lyric.queryParameters, {
      'artist_name': 'Someone',
      'track_name': 'One',
      'album_name': 'Blue "Hour"',
      'duration': '201',
    });
    expect(library.withLyrics, {'/m/1.flac'});
    expect(
      downloadedLyrics('/m/1.flac')!.readAsStringSync(),
      '[00:01.00] hello',
    );

    // Everything was looked for: a second pass asks nothing, even after a restart.
    asked.clear();
    await f.run();
    expect(asked, isEmpty);
    final again = fetcher();
    await again.load();
    await again.run();
    expect(asked, isEmpty);
  });

  test('a server hiccup skips a song for now, not the rest', () async {
    var calls = 0;
    final f = Fetcher(
      library: library,
      player: PlayerController(events: const Stream<PlayerEvent>.empty()),
      settings: File('${dir.path}/fetch.json'),
      userAgent: 'Halcyn/test',
      persist: false,
      get: (url) async {
        asked.add(url);
        // The first song's request fails; the second finds nothing.
        return calls++ == 0 ? (503, Uint8List(0)) : (404, Uint8List(0));
      },
    )..art = false;
    await f.run();
    expect(asked.map((u) => u.queryParameters['track_name']), ['One', 'Two']);
    asked.clear();
    await f.run();
    expect(asked.map((u) => u.queryParameters['track_name']), ['One']);
  });

  test('each kind can be turned off', () async {
    final f = fetcher(art: false)..lyrics = false;
    await f.run();
    expect(asked, isEmpty);
    f.setLyrics(true);
    await f.run();
    expect(asked.map((u) => u.host).toSet(), {'lrclib.net'});
  });

  test('a streamed song gets its lyrics as it plays, searched for', () async {
    final stream = _track('tidal:5', 'Three (2012 Remaster)', album: 'Other');
    final f = Fetcher(
      library: library,
      player: PlayerController(events: const Stream<PlayerEvent>.empty()),
      settings: File('${dir.path}/fetch.json'),
      userAgent: 'Halcyn/test',
      persist: false,
      get: (url) async {
        asked.add(url);
        if (url.path != '/api/search') return (404, Uint8List(0));
        // The same title, one far longer (a live take), then the recording.
        expect(url.queryParameters['track_name'], 'Three');
        final body = jsonEncode([
          {'duration': 320, 'syncedLyrics': '[00:01.00] live'},
          {'duration': 202, 'plainLyrics': 'plain'},
          {'duration': 200, 'syncedLyrics': '[00:01.00] studio'},
        ]);
        return (200, Uint8List.fromList(utf8.encode(body)));
      },
    );
    expect(await f.lyricsNow(stream), '[00:01.00] studio');
    expect(
      downloadedLyrics('tidal:5')!.readAsStringSync(),
      '[00:01.00] studio',
    );
    expect(library.withLyrics, contains('tidal:5'));
    // Downloaded once: read from the file after that.
    asked.clear();
    expect(await f.lyricsNow(stream), '[00:01.00] studio');
    expect(asked, isEmpty);
  });

  test('clears only the lyrics not used for a week', () async {
    final f = fetcher(art: false);
    final old = downloadedLyrics('/m/1.flac')!
      ..createSync(recursive: true)
      ..writeAsStringSync('[00:01.00] one');
    final recent = downloadedLyrics('/m/2.flac')!
      ..writeAsStringSync('[00:01.00] two');
    final weekAgo = DateTime.now().subtract(const Duration(days: 8));
    old.setLastModifiedSync(weekAgo);
    recent.setLastModifiedSync(weekAgo);
    library.addLyrics({'/m/1.flac', '/m/2.flac'});
    // Playing the second song counts as using its lyrics.
    expect(await f.lyricsNow(library.tracks[1]), '[00:01.00] two');

    expect(await f.clearUnusedLyrics(), 1);
    expect(old.existsSync(), isFalse);
    expect(recent.existsSync(), isTrue);
    expect(library.withLyrics, {'/m/2.flac'});
    // Not fetched again in the background straight away.
    await f.run();
    expect(asked, isEmpty);
  });
}
