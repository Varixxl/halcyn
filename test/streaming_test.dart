import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/src/rust/api/library.dart';
import 'package:halcyn/src/rust/api/player.dart';
import 'package:halcyn/src/rust/api/streaming.dart';
import 'package:halcyn/src/state/library.dart';
import 'package:halcyn/src/state/player.dart';
import 'package:halcyn/src/state/playlists.dart';
import 'package:halcyn/src/state/streaming.dart';

Track _track(
  String path,
  String title, {
  List<String> artists = const ['Daft Punk'],
  double duration = 248,
  String codec = 'FLAC',
  int sampleRate = 44100,
  int? bits = 16,
}) => Track(
  id: 0,
  path: path,
  title: title,
  artists: artists,
  durationSecs: duration,
  sampleRate: sampleRate,
  bits: bits,
  channels: 2,
  codec: codec,
  added: 0,
  plays: 0,
);

void main() {
  test('tells the same recording from another one', () {
    expect(
      sameSong(
        'Get Lucky (feat. Pharrell Williams)',
        ['Daft Punk'],
        248,
        'Get Lucky',
        ['Daft Punk', 'Pharrell Williams'],
        249,
      ),
      greaterThan(0.9),
    );
    // A live or remixed recording isn't the same song, nor is one far longer.
    expect(
      sameSong('Get Lucky', ['Daft Punk'], 248, 'Get Lucky (Live)', [
        'Daft Punk',
      ], 248),
      0,
    );
    expect(
      sameSong('Get Lucky', ['Daft Punk'], 248, 'Get Lucky', ['Daft Punk'], 369),
      0,
    );
    expect(
      sameSong('Get Lucky', ['Daft Punk'], 248, 'Get Lucky', ['Someone'], 248),
      0,
    );
    expect(bareTitle('Song 2 - 2012 Remaster'), 'Song 2');
    expect(
      matchKey('Get Lucky [Radio Edit]', ['Daft Punk']),
      matchKey('get lucky', ['DAFT PUNK']),
    );
  });

  group('with a library', () {
    late Directory dir;
    late LibraryController library;
    late PlayerController player;
    late StreamingController streaming;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('halcyn-streaming');
      library = LibraryController()
        ..tracks = [
          _track('/m/lucky.flac', 'Get Lucky'),
          _track('/m/song2.mp3', 'Song 2', artists: ['Blur'], codec: 'MP3'),
        ];
      player = PlayerController(events: const Stream<PlayerEvent>.empty());
      streaming = StreamingController(
        library: library,
        player: player,
        playlists: PlaylistsController(),
        settings: File('${dir.path}/streaming.json'),
        persist: false,
      );
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('plays a file of the user\'s own when it\'s as good', () async {
      final lossless = _track('tidal:1', 'Get Lucky', codec: 'Lossless');
      final hiRes = _track('tidal:2', 'Get Lucky', codec: 'Hi-res');
      final lossy = _track('ytm:a', 'Song 2', artists: ['Blur'], codec: 'AAC');
      final tidalSong2 = _track(
        'tidal:3',
        'Song 2',
        artists: ['Blur'],
        codec: 'Lossless',
      );
      // load() needs the core: index the library the way it does.
      streaming.debugIndexLocal();

      // A 16-bit FLAC is as good as Tidal's lossless, not its hi-res.
      expect(streaming.preferred(lossless).path, '/m/lucky.flac');
      expect(streaming.preferred(hiRes).path, 'tidal:2');
      // An MP3 is as good as YouTube's AAC, not Tidal's FLAC.
      expect(streaming.preferred(lossy).path, '/m/song2.mp3');
      expect(streaming.preferred(tidalSong2).path, 'tidal:3');
      // Unless turned off.
      streaming.setPreferLocal(false);
      expect(streaming.preferred(lossless).path, 'tidal:1');
    });

    test('only shows linked services, in the chosen order', () {
      streaming.accounts = StreamingAccounts(
        tidalAvailable: true,
        tidal: 'Someone',
        youtube: null,
        youtubePlayable: true,
      );
      expect(streaming.linked, isTrue);
      expect(streaming.services, ['tidal']);
      streaming.accounts = StreamingAccounts(
        tidalAvailable: true,
        tidal: 'Someone',
        youtube: '',
        youtubePlayable: true,
      );
      streaming.setOrder(['ytm', 'tidal']);
      expect(streaming.services, ['ytm', 'tidal']);
      expect(serviceOf('tidal:1'), 'tidal');
      expect(serviceOf('/m/x.flac'), 'local');
    });
  });
}
