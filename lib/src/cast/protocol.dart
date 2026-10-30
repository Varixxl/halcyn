import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../rust/api/library.dart';
import '../rust/api/player.dart';

/// Casting: one Halcyn (the sender, usually a phone) plays through and controls another
/// (the receiver, usually a desktop) on the same network.
///
/// - Discovery: the sender broadcasts `{"halcyn":"discover"}` over UDP to
///   [discoveryPort]; receivers answer `{"halcyn":"here", id, name, port}`.
/// - Control: a WebSocket at `ws://host:port/ws?device=&name=&token=`. A device without a
///   valid token is shown on the receiver to approve, then sent its token.
/// - Files: `PUT /file/<cast id>.<ext>` (and the `.lrc` beside it) and `PUT /art/<key>`,
///   for songs the receiver doesn't have. `GET /art/<key>` and `GET /lyrics?path=` go the
///   other way. All of them need `Authorization: Bearer <token>`.
const discoveryPort = 47230;
const defaultPort = 47231;

/// Ports from the environment, so a test receiver can run beside the real one.
int castPort(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

/// A random id or token, as hex.
String randomHex(int bytes) {
  final random = Random.secure();
  return [
    for (var i = 0; i < bytes; i++)
      random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// 64-bit FNV-1a, as 16 hex digits. The same hash the art cache uses for its keys.
String fnv1a(String text) {
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  final mask = (BigInt.one << 64) - BigInt.one;
  for (final byte in utf8.encode(text)) {
    hash = ((hash ^ BigInt.from(byte)) * prime) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

/// The name a sender's file gets on the receiver: the same file (same path, same
/// modification time) always gets the same name, so it's only sent once.
String castName(Track track) {
  final dot = track.path.lastIndexOf('.');
  final ext = dot > track.path.lastIndexOf('/') && track.path.length - dot <= 6
      ? track.path.substring(dot + 1).toLowerCase()
      : 'audio';
  return '${fnv1a('${track.path}\n${track.added}')}.$ext';
}

/// File names the receiver accepts: a cast name, or the lyrics beside one.
final castFileName = RegExp(r'^[0-9a-f]{16}\.[a-z0-9]{1,5}$');

/// Art cache file names, as `artFile` writes them.
final artFileName = RegExp(r'^[0-9a-f]{16}-(128|512|full)\.jpg$');

Map<String, Object?> trackToJson(Track t) => {
  'path': t.path,
  'title': t.title,
  'artists': t.artists,
  'album': t.album,
  'albumArtist': t.albumArtist,
  'trackNo': t.trackNo,
  'discNo': t.discNo,
  'year': t.year,
  'duration': t.durationSecs,
  'rate': t.sampleRate,
  'bits': t.bits,
  'channels': t.channels,
  'codec': t.codec,
  'art': t.art,
  'added': t.added,
  'plays': t.plays,
};

/// `id` stands in for the library's: tracks from another device aren't in this one's.
/// The cover is left out unless this device has it (`art`).
Track trackFromJson(Map json, {required int id, String? path, String? art}) =>
    Track(
      id: id,
      path: path ?? json['path'] as String,
      title: json['title'] as String,
      artists: (json['artists'] as List).cast<String>(),
      album: json['album'] as String?,
      albumArtist: json['albumArtist'] as String?,
      trackNo: json['trackNo'] as int?,
      discNo: json['discNo'] as int?,
      year: json['year'] as int?,
      durationSecs: (json['duration'] as num).toDouble(),
      sampleRate: json['rate'] as int,
      bits: json['bits'] as int?,
      channels: json['channels'] as int,
      codec: json['codec'] as String,
      art: art,
      added: json['added'] as int,
      plays: json['plays'] as int? ?? 0,
    );

Map<String, Object?> signalPathToJson(SignalPath p) => {
  'source': p.source,
  'processing': p.processing,
  'output': p.output,
  'bitExact': p.bitExact,
  'warning': p.warning,
};

SignalPath signalPathFromJson(Map json) => SignalPath(
  source: json['source'] as String,
  processing: json['processing'] as String,
  output: json['output'] as String,
  bitExact: json['bitExact'] as bool,
  warning: json['warning'] as String?,
);

/// MP4 files are "AAC/ALAC" in the library; only ALAC has a bit depth.
bool _lossless(Track t) => switch (t.codec) {
  'FLAC' || 'WAV' || 'AIFF' => true,
  'AAC/ALAC' => t.bits != null,
  _ => false,
};

/// Lossless beats lossy, then more bits, then a higher sample rate.
int qualityRank(Track t) =>
    (_lossless(t) ? 1 << 40 : 0) + ((t.bits ?? 16) << 24) + t.sampleRate;

String _norm(String? s) => (s ?? '').toLowerCase().replaceAll(
  RegExp(r'[^\p{L}\p{N}]+', unicode: true),
  '',
);

String _matchKey(String title, List<String> artists, String? album) =>
    '${_norm(title)}|${_norm(artists.firstOrNull)}|${_norm(album)}';

/// Finds the receiver's own copy of a sender's song: same title, first artist and album,
/// and within two seconds of the same length.
class TrackMatcher {
  TrackMatcher(Iterable<Track> library) {
    for (final t in library) {
      (_byKey[_matchKey(t.title, t.artists, t.album)] ??= []).add(t);
    }
  }

  final _byKey = <String, List<Track>>{};

  /// The best local copy that's at least as good as `remote`, if there is one.
  Track? match(Track remote) {
    final candidates =
        _byKey[_matchKey(remote.title, remote.artists, remote.album)];
    if (candidates == null) return null;
    Track? best;
    for (final t in candidates) {
      if ((t.durationSecs - remote.durationSecs).abs() > 2) continue;
      if (best == null || qualityRank(t) > qualityRank(best)) best = t;
    }
    return best != null && qualityRank(best) >= qualityRank(remote)
        ? best
        : null;
  }
}

Track copyTrack(Track t, {String? art, double? durationSecs}) => Track(
  id: t.id,
  path: t.path,
  title: t.title,
  artists: t.artists,
  album: t.album,
  albumArtist: t.albumArtist,
  trackNo: t.trackNo,
  discNo: t.discNo,
  year: t.year,
  durationSecs: durationSecs ?? t.durationSecs,
  sampleRate: t.sampleRate,
  bits: t.bits,
  channels: t.channels,
  codec: t.codec,
  art: art ?? t.art,
  added: t.added,
  plays: t.plays,
  lastPlayed: t.lastPlayed,
  isrc: t.isrc,
);
