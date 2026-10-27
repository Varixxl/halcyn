import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/src/state/library.dart';
import 'package:halcyn/src/state/lyrics.dart';

void main() {
  test('parses synced lines, repeated stamps and skips tags', () {
    final lyrics = parseLrc('''
[ar:Someone]
[ti:Song]
[00:09.68] Oh-oh
[00:21.83][01:02.5] Serendipity (ooh)
[00:30.65]
''')!;
    expect(lyrics.synced, isTrue);
    expect(
      [for (final l in lyrics.lines) l.text],
      ['Oh-oh', 'Serendipity (ooh)', '', 'Serendipity (ooh)'],
    );
    expect(lyrics.lines[1].secs, closeTo(21.83, 1e-9));
    expect(lyrics.lines[3].secs, closeTo(62.5, 1e-9));
    expect(lyrics.lineAt(0), -1);
    expect(lyrics.lineAt(9.68), 0);
    expect(lyrics.lineAt(25), 1);
    expect(lyrics.lineAt(500), 3);
  });

  test('keeps unsynced lyrics as plain lines', () {
    final lyrics = parseLrc('First line\nSecond line\n')!;
    expect(lyrics.synced, isFalse);
    expect(lyrics.lines.length, 2);
    expect(lyrics.lineAt(10), -1);
  });

  test('finds the .lrc beside the track', () {
    expect(lyricsPath('/m/a.b/song.flac'), '/m/a.b/song.lrc');
    expect(lyricsPath('/m/a.b/song'), '/m/a.b/song.lrc');
  });
}
