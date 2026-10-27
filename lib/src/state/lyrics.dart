import 'dart:io';

import 'library.dart';

class LyricLine {
  const LyricLine(this.secs, this.text);

  /// When the line starts; null in unsynced lyrics.
  final double? secs;
  final String text;
}

class Lyrics {
  const Lyrics(this.lines);

  final List<LyricLine> lines;

  bool get synced => lines.isNotEmpty && lines.first.secs != null;

  /// The line being sung at `secs`, or -1 before the first.
  int lineAt(double secs) {
    if (!synced) return -1;
    var lo = 0, hi = lines.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (lines[mid].secs! <= secs) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }
}

/// The `.lrc` beside the track, else downloaded ones, else null. `fetch` gets it from
/// elsewhere when it isn't here.
Future<Lyrics?> loadLyrics(
  String trackPath, {
  Future<String?> Function(String trackPath)? fetch,
}) async {
  for (final file in [
    File(lyricsPath(trackPath)),
    ?downloadedLyrics(trackPath),
  ]) {
    try {
      return parseLrc(await file.readAsString());
    } on Object {
      // Not there, or unreadable.
    }
  }
  if (await fetch?.call(trackPath) case final text?) return parseLrc(text);
  return null;
}

final _stamp = RegExp(r'\[(\d+):(\d+(?:[.:]\d+)?)\]');
final _tag = RegExp(r'^\[[a-zA-Z#]+:.*\]$');

/// LRC: `[mm:ss.xx]` stamps before each line, possibly several. Lines without stamps make
/// unsynced lyrics; `[ar:...]`-style tags are skipped.
Lyrics? parseLrc(String text) {
  final synced = <LyricLine>[];
  final plain = <LyricLine>[];
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty || _tag.hasMatch(line)) continue;
    final stamps = _stamp.allMatches(line).toList();
    if (stamps.isEmpty || stamps.first.start != 0) {
      plain.add(LyricLine(null, line));
      continue;
    }
    final words = line.substring(stamps.last.end).trim();
    for (final m in stamps) {
      final secs =
          int.parse(m[1]!) * 60 + double.parse(m[2]!.replaceAll(':', '.'));
      synced.add(LyricLine(secs, words));
    }
  }
  if (synced.isNotEmpty) {
    synced.sort((a, b) => a.secs!.compareTo(b.secs!));
    return Lyrics(synced);
  }
  return plain.isEmpty ? null : Lyrics(plain);
}
