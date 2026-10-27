import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/src/cast/protocol.dart';
import 'package:halcyn/src/rust/api/library.dart';
import 'package:halcyn/src/rust/api/player.dart';

Track _track(
  String path, {
  String title = 'Song',
  List<String> artists = const ['Artist'],
  String? album = 'Album',
  double duration = 200,
  String codec = 'FLAC',
  int rate = 44100,
  int? bits = 16,
}) => Track(
  id: 1,
  path: path,
  title: title,
  artists: artists,
  album: album,
  durationSecs: duration,
  sampleRate: rate,
  bits: bits,
  channels: 2,
  codec: codec,
  art: '0123456789abcdef',
  added: 1700000000,
  plays: 3,
);

void main() {
  test('fnv1a matches the reference values', () {
    expect(fnv1a(''), 'cbf29ce484222325');
    expect(fnv1a('a'), 'af63dc4c8601ec8c');
    expect(fnv1a('foobar'), '85944171f73967e8');
  });

  test('cast names are stable, per file, and accepted by the receiver', () {
    final a = _track('/Music/A/song.FLAC');
    expect(castName(a), castName(_track('/Music/A/song.FLAC')));
    expect(castName(a), isNot(castName(_track('/Music/B/song.FLAC'))));
    expect(castName(a), endsWith('.flac'));
    expect(castFileName.hasMatch(castName(a)), isTrue);
    expect(castName(_track('/Music/no extension')), endsWith('.audio'));
    expect(castFileName.hasMatch('../../etc/passwd'), isFalse);
    expect(castFileName.hasMatch('0123456789abcdef.flac/x'), isFalse);
    expect(artFileName.hasMatch('0123456789abcdef-512.jpg'), isTrue);
    expect(artFileName.hasMatch('0123456789abcdef-512.jpg.part'), isFalse);
  });

  test('tracks and signal paths survive the trip', () {
    final t = _track('/Music/x.flac', title: 'Ünïcode ✓', album: null);
    final back = trackFromJson(
      trackToJson(t),
      id: 7,
      path: '/cache/x.flac',
      art: t.art,
    );
    // A cover this device doesn't have is left out.
    expect(trackFromJson(trackToJson(t), id: 7).art, isNull);
    expect(back.title, t.title);
    expect(back.album, isNull);
    expect(back.path, '/cache/x.flac');
    expect(back.id, 7);
    expect(back.art, t.art);
    expect(copyTrack(back, art: 'ffffffffffffffff').art, 'ffffffffffffffff');
    const p = SignalPath(
      source: 'FLAC',
      processing: 'Bit-exact',
      output: 'PipeWire',
      bitExact: true,
      warning: null,
    );
    expect(signalPathFromJson(signalPathToJson(p)), p);
  });

  test('the receiver uses its own copy only if it is as good', () {
    final cd = _track('/d/cd.flac');
    final hires = _track('/d/hires.flac', bits: 24, rate: 96000);
    final mp3 = _track('/d/song.mp3', codec: 'MP3', bits: null, rate: 44100);
    final aac = _track('/d/song.m4a', codec: 'AAC/ALAC', bits: null);
    final alac = _track('/d/song-alac.m4a', codec: 'AAC/ALAC', bits: 24);

    // Same song with different punctuation and case.
    final phone = _track(
      '/p/x.flac',
      title: 'song!',
      artists: ['ARTIST', 'Guest'],
      album: 'album ',
    );
    expect(TrackMatcher([cd]).match(phone)?.path, cd.path);
    // The best copy wins.
    expect(TrackMatcher([cd, hires, mp3]).match(phone)?.path, hires.path);
    // A worse copy doesn't: the phone's file is sent.
    expect(TrackMatcher([mp3]).match(phone), isNull);
    expect(TrackMatcher([aac]).match(phone), isNull);
    expect(TrackMatcher([alac]).match(phone)?.path, alac.path);
    // A different length is a different recording.
    expect(
      TrackMatcher([_track('/d/live.flac', duration: 260)]).match(phone),
      isNull,
    );
    expect(
      TrackMatcher([_track('/d/close.flac', duration: 201.5)]).match(phone),
      isNotNull,
    );
    expect(
      TrackMatcher([_track('/d/other.flac', album: 'Live')]).match(phone),
      isNull,
    );
  });
}
