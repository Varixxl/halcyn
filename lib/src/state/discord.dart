import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../rust/api/discord.dart';
import '../rust/api/streaming.dart';
import 'account.dart';
import 'player.dart';
import 'streaming.dart';

/// Halcyn's application on Discord: its name is the "Listening to Halcyn".
const discordAppId = '1564564305989472326';
const downloadPage = 'https://github.com/Varixxl/halcyn/releases/latest';
const _files = 'https://raw.githubusercontent.com/Varixxl/halcyn/main';
const _icon = '$_files/linux/halcyn.png';
const _visualizer = '$_files/docs/discord/visualizer.gif';

/// A song as Discord shows it: from this device's player, or another device's (see
/// [DiscordPresence]).
@immutable
class PresenceSong {
  const PresenceSong({
    required this.path,
    required this.title,
    required this.artists,
    this.album,
    this.art,
    required this.duration,
    required this.start,
    this.device,
  });

  factory PresenceSong.fromJson(Map json, DateTime start, String device) =>
      PresenceSong(
        path: json['path'] as String? ?? '',
        title: json['title'] as String? ?? '',
        artists: [...(json['artists'] as List? ?? const []).cast<String>()],
        album: json['album'] as String?,
        art: json['art'] as String?,
        duration: (json['duration'] as num?)?.toDouble() ?? 0,
        start: start,
        device: device,
      );

  final String path;
  final String title;
  final List<String> artists;
  final String? album;

  /// The cover's web address (streamed songs only: a file's cover is on this device).
  final String? art;
  final double duration;

  /// When it would have started, had it played straight through to where it is.
  final DateTime start;

  /// The other device it's playing on; null for this one.
  final String? device;

  DateTime get end =>
      start.add(Duration(milliseconds: (duration * 1000).round()));

  Map<String, Object?> toJson() => {
    'path': path,
    'title': title,
    'artists': artists,
    'album': album,
    'art': art,
    'duration': duration,
  };
}

/// The song's page on its service, for the button that opens it.
({String service, String url})? songPage(String path) {
  final id = path.substring(path.indexOf(':') + 1);
  return switch (serviceOf(path)) {
    'tidal' => (service: 'Tidal', url: 'https://tidal.com/browse/track/$id'),
    'ytm' => (
      service: 'YouTube Music',
      url: 'https://music.youtube.com/watch?v=$id',
    ),
    _ => null,
  };
}

/// Discord's activity for [song]: "Listening to Halcyn", the song and its artists, its
/// cover with the visualizer beside it (or the visualizer alone), how far in it is, and
/// buttons to open the song and to get Halcyn.
Map<String, Object?> discordActivity(PresenceSong song) {
  // Discord takes 2 to 128 characters.
  String text(String? s) {
    final t = (s ?? '').trim();
    // A blank Braille pattern: Discord doesn't count spaces.
    return (t.length > 128 ? t.substring(0, 128) : t).padRight(2, '\u{2800}');
  }

  final cover = song.art?.startsWith('https://') ?? false;
  final page = songPage(song.path);
  return {
    'type': 2,
    'status_display_type': 0,
    'details': text(song.title),
    'state': text(song.artists.isEmpty ? null : song.artists.join(', ')),
    'timestamps': {
      'start': song.start.millisecondsSinceEpoch,
      if (song.duration > 0) 'end': song.end.millisecondsSinceEpoch,
    },
    'assets': {
      'large_image': cover ? song.art : _visualizer,
      if (song.album case final album? when album.isNotEmpty)
        'large_text': text(album),
      'small_image': cover ? _visualizer : _icon,
      'small_text': song.device == null
          ? 'Halcyn'
          : text('Halcyn on ${song.device}'),
    },
    if (page != null) 'details_url': page.url,
    'buttons': [
      if (page != null) {'label': 'Play on ${page.service}', 'url': page.url},
      {'label': 'Get Halcyn', 'url': downloadPage},
    ],
  };
}

/// What's playing, on the user's Discord profile ("Listening to Halcyn"), as Spotify does.
/// Paused or stopped, it's cleared.
///
/// A computer tells the Discord app on it (see `rust/src/discord.rs`). A phone can't (Discord
/// has no way in there), so while the user is signed in to their Halcyn account the phone
/// puts what it plays in the account's `now_playing` row, and their computer shows that
/// while it isn't playing anything itself.
class DiscordPresence extends ChangeNotifier {
  DiscordPresence({
    required this.player,
    required this.account,
    required this.settings,
    required this.device,
    this.persist = true,
    this.online = true,
    bool? local,
    void Function(String? activity)? send,
  }) : local = local ?? !Platform.isAndroid,
       _send =
           send ??
           ((activity) {
             if (discordAppId.isEmpty) return;
             discordSet(appId: discordAppId, activity: activity);
           });

  final PlayerController player;
  final AccountController account;

  /// `discord.json`: whether it's on.
  final File settings;

  /// This device's name, shown on the computer for songs playing here.
  final String device;
  final bool persist;

  /// Tests leave the account server alone.
  final bool online;

  /// Whether this device has a Discord app to tell (a computer), rather than going
  /// through the account (a phone).
  final bool local;
  final void Function(String? activity) _send;

  bool on = true;

  /// What another device is playing, from the account.
  PresenceSong? remote;

  /// What Discord was last told, to notice a seek.
  PresenceSong? _shown;
  String? _key;
  Timer? _soon;
  Timer? _ends;
  Timer? _status;
  Timer? _poll;
  RealtimeChannel? _channel;
  String? _uid;

  /// For Settings: whether Discord shows it, or why not.
  String get status {
    if (!on) return 'Off';
    if (!local) {
      return account.signedIn
          ? 'Shown through your computer\'s Halcyn while you\'re signed in there too'
          : 'Sign in to your Halcyn account here and on your computer';
    }
    return switch (discordStatus()) {
      'on' => 'Showing on Discord',
      '' => 'Shows once something plays',
      final why => why,
    };
  }

  Future<void> load() async {
    if (!persist) return;
    try {
      final json = jsonDecode(await settings.readAsString()) as Map;
      if (json['on'] case final bool saved) on = saved;
    } on Object {
      // On, then.
    }
  }

  void start() {
    player.addListener(_changed);
    player.position.addListener(_moved);
    account.addListener(_accountChanged);
    _accountChanged();
    _changed();
  }

  Future<void> setOn(bool on) async {
    this.on = on;
    notifyListeners();
    _changed();
    if (!persist) return;
    try {
      await settings.writeAsString(jsonEncode({'on': on}));
    } on Object catch (e) {
      debugPrint('saving Discord settings: $e');
    }
  }

  /// The song playing here, if one is.
  PresenceSong? _playing() {
    final t = player.current;
    if (t == null || !player.playing || player.casting) return null;
    return PresenceSong(
      path: t.path,
      title: t.title,
      artists: t.artists,
      album: t.album,
      duration: t.durationSecs,
      start: DateTime.now().subtract(
        Duration(milliseconds: (player.position.value * 1000).round()),
      ),
    );
  }

  void _changed() {
    final t = player.playing && !player.casting ? player.current : null;
    final key = '$on ${t?.path} ${remote?.path} ${remote?.start}';
    if (key == _key) return;
    _key = key;
    _later();
  }

  /// A seek: the bar on Discord would be off.
  void _moved() {
    final shown = _shown;
    if (shown == null || shown.device != null || !player.playing) return;
    final there = DateTime.now().difference(shown.start).inMilliseconds;
    if ((there - player.position.value * 1000).abs() > 3000) _later();
  }

  /// In a moment, once the position has caught up. A wait already under way isn't
  /// pushed back: a new song's position ticks would otherwise keep putting it off.
  void _later() {
    _soon ??= Timer(const Duration(milliseconds: 300), () {
      _soon = null;
      unawaited(_update());
    });
  }

  Future<void> _update() async {
    var song = on ? _playing() : null;
    if (song != null && isStream(song.path)) {
      try {
        final [art] = await streamingArtUrls(paths: [song.path]);
        song = PresenceSong(
          path: song.path,
          title: song.title,
          artists: song.artists,
          album: song.album,
          art: art,
          duration: song.duration,
          start: song.start,
        );
      } on Object {
        // Without its cover.
      }
    }
    _shown = song;
    if (!local) {
      await _publish(song);
      return;
    }
    final other = remote;
    if (song == null &&
        on &&
        other != null &&
        DateTime.now().isBefore(other.end.add(const Duration(seconds: 5)))) {
      song = other;
      _shown = song;
    }
    _send(song == null ? null : jsonEncode(discordActivity(song)));
    // Settings shows whether Discord took it, which it says in a moment.
    _status?.cancel();
    _status = Timer(const Duration(seconds: 6), notifyListeners);
    // A song from the phone goes when it would have ended, if the phone says nothing.
    _ends?.cancel();
    if (song != null && song.device != null) {
      _ends = Timer(
        song.end.difference(DateTime.now()) + const Duration(seconds: 6),
        () {
          remote = null;
          _changed();
        },
      );
    }
    notifyListeners();
  }

  // The account: a phone writes, a computer listens. ------------------------------

  SupabaseClient? get _db {
    if (!online || !account.signedIn) return null;
    try {
      return Supabase.instance.client;
    } on Object {
      return null;
    }
  }

  Future<void> _publish(PresenceSong? song) async {
    final db = _db;
    final uid = account.user?.id;
    if (db == null || uid == null) return;
    try {
      await db.from('now_playing').upsert({
        'user_id': uid,
        'device': device,
        'track': song?.toJson(),
        'playing': song != null,
        'started_at': song?.start.toUtc().toIso8601String(),
      });
    } on Object catch (e) {
      debugPrint('now playing: $e');
    }
  }

  void _accountChanged() {
    final uid = local ? account.user?.id : null;
    if (uid == _uid) return;
    _uid = uid;
    final old = _channel;
    _channel = null;
    _poll?.cancel();
    if (old != null) unawaited(old.unsubscribe());
    remote = null;
    final db = _db;
    if (uid == null || db == null) return;
    _channel = db
        .channel('now_playing:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'now_playing',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: uid,
          ),
          callback: (change) => heard(change.newRecord),
        )
        .subscribe((status, [error]) {
          // What's playing already, once listening.
          if (status == RealtimeSubscribeStatus.subscribed) _fetch();
        });
    // Changes missed while the connection was down, too.
    _poll = Timer.periodic(const Duration(minutes: 1), (_) => _fetch());
  }

  Future<void> _fetch() async {
    final db = _db;
    final uid = _uid;
    if (db == null || uid == null) return;
    try {
      final row = await db
          .from('now_playing')
          .select()
          .eq('user_id', uid)
          .maybeSingle();
      if (row != null && uid == _uid) heard(row);
    } on Object catch (e) {
      debugPrint('now playing: $e');
    }
  }

  /// The account's `now_playing` row changed.
  @visibleForTesting
  void heard(Map<String, dynamic> row) {
    final track = row['track'];
    final started = DateTime.tryParse(row['started_at'] as String? ?? '');
    final from = row['device'] as String? ?? 'phone';
    remote = row['playing'] == true && track is Map && started != null
        ? PresenceSong.fromJson(track, started.toLocal(), from)
        : null;
    _changed();
  }

  @override
  void dispose() {
    player.removeListener(_changed);
    player.position.removeListener(_moved);
    account.removeListener(_accountChanged);
    _soon?.cancel();
    _ends?.cancel();
    _status?.cancel();
    _poll?.cancel();
    unawaited(_channel?.unsubscribe());
    super.dispose();
  }
}
