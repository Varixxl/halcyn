import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/src/rust/api/library.dart';
import 'package:halcyn/src/state/sort.dart';

Track _track(
  String title, {
  String artist = 'A',
  String? album,
  int? trackNo,
  int added = 0,
  double secs = 180,
  int rate = 44100,
  int? bits = 16,
}) => Track(
  id: 0,
  path: '/$title.flac',
  title: title,
  artists: [artist],
  album: album,
  trackNo: trackNo,
  durationSecs: secs,
  sampleRate: rate,
  bits: bits,
  channels: 2,
  codec: 'FLAC',
  added: added,
  plays: 0,
);

List<String> _titles(List<Track> tracks) => [for (final t in tracks) t.title];

void main() {
  final tracks = [
    _track('banana', artist: 'Zed', album: 'Two', trackNo: 2, added: 30),
    _track(
      'Apple',
      artist: 'amy',
      album: 'One',
      secs: 300,
      rate: 96000,
      bits: 24,
    ),
    _track('cherry', artist: 'Zed', album: 'Two', trackNo: 1, added: 10),
  ];
  int plays(Track t) => t.title == 'cherry' ? 5 : 0;

  test('sorts by each key, case-insensitively, either way', () {
    expect(_titles(const TrackSort(TrackSortKey.title).apply(tracks, plays)), [
      'Apple',
      'banana',
      'cherry',
    ]);
    expect(
      _titles(const TrackSort(TrackSortKey.title, true).apply(tracks, plays)),
      ['cherry', 'banana', 'Apple'],
    );
    // Artist, then album order (disc and track number).
    expect(_titles(const TrackSort(TrackSortKey.artist).apply(tracks, plays)), [
      'Apple',
      'cherry',
      'banana',
    ]);
    expect(
      _titles(const TrackSort(TrackSortKey.added, true).apply(tracks, plays)),
      ['banana', 'cherry', 'Apple'],
    );
    expect(
      _titles(const TrackSort(TrackSortKey.plays, true).apply(tracks, plays)),
      ['cherry', 'banana', 'Apple'],
    );
    expect(
      _titles(const TrackSort(TrackSortKey.quality, true).apply(tracks, plays)),
      ['Apple', 'banana', 'cherry'],
    );
  });

  test("the list's own order, and reversing it", () {
    expect(_titles(const TrackSort().apply(tracks, plays)), [
      'banana',
      'Apple',
      'cherry',
    ]);
    expect(_titles(const TrackSort(null, true).apply(tracks, plays)), [
      'cherry',
      'Apple',
      'banana',
    ]);
  });

  test('clicking a column picks its direction, then flips it', () {
    const none = TrackSort();
    expect(none.by(TrackSortKey.title), const TrackSort(TrackSortKey.title));
    expect(
      none.by(TrackSortKey.added),
      const TrackSort(TrackSortKey.added, true),
    );
    expect(
      const TrackSort(TrackSortKey.title).by(TrackSortKey.title),
      const TrackSort(TrackSortKey.title, true),
    );
  });
}
