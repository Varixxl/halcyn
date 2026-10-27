import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../cast/sender.dart';
import 'library.dart';
import 'player.dart';

const _channel = MethodChannel('halcyn/android');

/// What to call this device when casting: the name set in Android's settings, or the
/// computer's host name.
Future<String> deviceName() async {
  if (Platform.isAndroid) {
    try {
      final name = await _channel.invokeMethod<String>('deviceName');
      if (name != null && name.isNotEmpty) return name;
    } on Object {
      // Older build of the Android side.
    }
  }
  return Platform.localHostname;
}

/// Android: whether Halcyn may read the music folder. Asking opens Android's "All files
/// access" page; coming back to the app checks again and scans once it's allowed.
class MusicAccess extends ChangeNotifier with WidgetsBindingObserver {
  MusicAccess(this._library);

  final LibraryController _library;

  /// True everywhere but on an Android that hasn't allowed it yet.
  bool granted = !Platform.isAndroid;

  Future<void> start() async {
    if (!Platform.isAndroid) return;
    WidgetsBinding.instance.addObserver(this);
    granted = await _channel.invokeMethod<bool>('canReadMusic') ?? false;
    notifyListeners();
    unawaited(_channel.invokeMethod('askToNotify'));
  }

  Future<void> ask() => _channel.invokeMethod('askToReadMusic');

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state != AppLifecycleState.resumed || granted) return;
    granted = await _channel.invokeMethod<bool>('canReadMusic') ?? false;
    notifyListeners();
    if (granted) unawaited(_library.rescan());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// Android: the notification and lock-screen controls, headset buttons, and pausing when
/// headphones are unplugged or a call comes in. Mirrors [PlayerController].
class MediaSession extends BaseAudioHandler with SeekHandler {
  MediaSession._(this._player, this._library, this._artDir, this._cast) {
    _player.addListener(_sync);
    _player.position.addListener(_onPosition);
    _cast.addListener(_syncVolume);
    _sync();
  }

  /// Starts the media service. Only on Android; elsewhere it does nothing.
  static Future<void> start(
    PlayerController player,
    LibraryController library,
    String artDir,
    CastController cast,
  ) async {
    if (!Platform.isAndroid) return;
    await AudioService.init(
      builder: () => MediaSession._(player, library, artDir, cast),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'io.github.varixxl.halcyn.playback',
        androidNotificationChannelName: 'Playback',
        androidNotificationIcon: 'drawable/ic_stat_halcyn',
        // Staying in the foreground while paused, so Android lets playback resume
        // from the notification later.
        androidStopForegroundOnPause: false,
      ),
    );
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    var resume = false;
    // While casting, the music isn't coming out of this phone, so unplugging its
    // headphones or taking a call leaves it alone.
    session.becomingNoisyEventStream.listen((_) {
      if (!player.casting) player.pause();
    });
    session.interruptionEventStream.listen((event) {
      if (player.casting) return;
      if (event.begin) {
        resume = player.playing && event.type != AudioInterruptionType.unknown;
        player.pause();
      } else if (resume) {
        resume = false;
        player.play();
      }
    });
  }

  final PlayerController _player;
  final LibraryController _library;
  final String _artDir;
  final CastController _cast;

  /// Volume key presses from silent to full on the other device.
  static const _volumeSteps = 20;
  bool _remoteVolume = false;
  int? _shownVolume;
  String? _shown;
  double _syncedAt = 0;
  DateTime _syncedTime = DateTime.now();

  @override
  Future<void> play() async => _player.play();

  @override
  Future<void> pause() async => _player.pause();

  @override
  Future<void> skipToNext() async => _player.next();

  @override
  Future<void> skipToPrevious() async => _player.previous();

  @override
  Future<void> seek(Duration position) async =>
      _player.seek(position.inMilliseconds / 1000);

  @override
  Future<void> stop() async => _player.pause();

  @override
  Future<void> androidSetRemoteVolume(int volumeIndex) async =>
      _cast.setVolume(volumeIndex / _volumeSteps);

  @override
  Future<void> androidAdjustRemoteVolume(
    AndroidVolumeDirection direction,
  ) async {
    final step = AndroidVolumeDirection.values.entries
        .firstWhere((e) => e.value == direction)
        .key;
    final now = (_cast.volume * _volumeSteps).round();
    _cast.setVolume((now + step).clamp(0, _volumeSteps) / _volumeSteps);
  }

  /// While casting, the phone's volume keys (and its volume panel) set the other
  /// device's volume: the session says its playback is remote. Otherwise they're the
  /// phone's own.
  void _syncVolume() {
    final remote = _player.casting && _cast.connected;
    final volume = (_cast.volume * _volumeSteps).round();
    if (remote == _remoteVolume && (!remote || volume == _shownVolume)) return;
    _remoteVolume = remote;
    _shownVolume = volume;
    androidPlaybackInfo.add(
      remote
          ? RemoteAndroidPlaybackInfo(
              volumeControlType: AndroidVolumeControlType.absolute,
              maxVolume: _volumeSteps,
              volume: volume,
            )
          : LocalAndroidPlaybackInfo(),
    );
  }

  void _sync() {
    _syncVolume();
    final track = _player.current;
    if (track != null && track.path != _shown) {
      _shown = track.path;
      final art = track.art;
      mediaItem.add(
        MediaItem(
          id: track.path,
          title: track.title,
          artist: track.artists.join(', '),
          album: track.album,
          duration: Duration(milliseconds: (track.durationSecs * 1000).round()),
          artUri: art == null ? null : Uri.file('$_artDir/$art-512.jpg'),
          extras: {'plays': _library.plays(track)},
        ),
      );
    }
    _publish();
  }

  /// Android moves the position along by itself; a jump (a seek) needs telling.
  void _onPosition() {
    final expected = _player.playing
        ? _syncedAt +
              DateTime.now().difference(_syncedTime).inMilliseconds / 1000
        : _syncedAt;
    if ((_player.position.value - expected).abs() > 1.5) _publish();
  }

  void _publish() {
    _syncedAt = _player.position.value;
    _syncedTime = DateTime.now();
    final playing = _player.playing;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: _player.current == null
            ? AudioProcessingState.idle
            : AudioProcessingState.ready,
        playing: playing,
        updatePosition: Duration(milliseconds: (_syncedAt * 1000).round()),
      ),
    );
  }
}
