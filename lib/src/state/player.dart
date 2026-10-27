import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../rust/api/library.dart';
import '../rust/api/player.dart';

/// Where commands go while casting: another Halcyn, which plays them and sends its state
/// back through [PlayerController.applyRemote].
abstract class RemotePlayer {
  void command(String op, [Map<String, Object?> args = const {}]);

  /// `mode` is 'replace' (play `tracks` from `start`), 'next' or 'append'.
  void play(List<Track> tracks, int start, String mode);
}

/// Mirrors the engine: the queue, what's playing, and where. Also keeps the session (queue
/// and position) in `session` so the next start picks up where this one left off.
///
/// While casting ([remote] set) it mirrors the other device instead: every command goes
/// there, and this device's own queue waits, paused, until casting stops.
class PlayerController extends ChangeNotifier {
  PlayerController({
    this.session,
    this.onListened,
    Stream<PlayerEvent>? events,
  }) {
    _events = (events ?? playerEvents()).listen(_onEvent);
  }

  /// Where the queue and position are saved. Null keeps nothing, e.g. under test.
  final File? session;

  /// Called once per track that has been listened to (half of it, or 4 minutes).
  final void Function(Track track)? onListened;

  late final StreamSubscription<PlayerEvent> _events;

  List<Track> queue = const [];
  int index = -1;
  bool playing = false;
  bool shuffle = false;
  Repeat repeat = Repeat.off;
  SignalPath? signalPath;
  String? error;

  /// Updated several times a second, so it has its own notifier: only the widgets showing
  /// the position rebuild.
  final position = ValueNotifier<double>(0);

  RemotePlayer? _remote;

  /// This device's own state while casting.
  ({
    List<Track> queue,
    int index,
    double position,
    bool shuffle,
    Repeat repeat,
    SignalPath? signalPath,
    List<Track>? unshuffled,
  })?
  _local;

  /// The queue in its own order, while shuffle is on and it hasn't been edited since.
  List<Track>? _unshuffled;
  bool _counted = false;
  Timer? _saveTimer;
  double _savedAt = 0;

  Track? get current =>
      index >= 0 && index < queue.length ? queue[index] : null;
  bool get hasNext =>
      repeat == Repeat.off ? index + 1 < queue.length : queue.isNotEmpty;
  List<Track> get upNext =>
      index + 1 < queue.length ? queue.sublist(index + 1) : const [];

  bool get casting => _remote != null;

  /// Starts mirroring `remote`. This device pauses and keeps its queue for [stopCasting].
  void startCasting(RemotePlayer remote) {
    if (_remote == null) {
      if (playing) playerPause();
      _saveTimer?.cancel();
      _local = (
        queue: queue,
        index: index,
        position: position.value,
        shuffle: shuffle,
        repeat: repeat,
        signalPath: signalPath,
        unshuffled: _unshuffled,
      );
      queue = const [];
      index = -1;
      playing = false;
      signalPath = null;
      error = null;
      position.value = 0;
    }
    _remote = remote;
    notifyListeners();
  }

  /// Back to this device's own queue, paused where it was.
  void stopCasting() {
    final local = _local;
    _remote = null;
    _local = null;
    if (local == null) return;
    queue = local.queue;
    index = local.index;
    position.value = local.position;
    shuffle = local.shuffle;
    repeat = local.repeat;
    signalPath = local.signalPath;
    _unshuffled = local.unshuffled;
    playing = false;
    error = null;
    _counted = true;
    notifyListeners();
  }

  /// The other device's state while casting. `queue` is null when it hasn't changed.
  void applyRemote({
    List<Track>? queue,
    required int index,
    required bool playing,
    required bool shuffle,
    required Repeat repeat,
    SignalPath? signalPath,
    String? error,
  }) {
    if (_remote == null) return;
    final before = current;
    if (queue != null) this.queue = List.unmodifiable(queue);
    this.index = index;
    this.playing = playing;
    this.shuffle = shuffle;
    this.repeat = repeat;
    this.signalPath = signalPath;
    this.error = error;
    if (current?.path != before?.path) {
      _counted = false;
    }
    notifyListeners();
  }

  void remotePosition(double secs) {
    if (_remote != null) _onPosition(secs);
  }

  /// Plugins' say before something plays from the app (see `PluginManager`): what to
  /// play instead, or null to play nothing.
  Future<({List<Track> tracks, int start})?> Function(
    List<Track> tracks,
    int start,
  )?
  beforePlay;

  /// What actually plays for a track: the streaming settings swap a stream for an
  /// equally good file of the user's own.
  Track Function(Track track)? substitute;

  List<Track> _substituted(List<Track> tracks) => switch (substitute) {
    final swap? => [for (final t in tracks) swap(t)],
    null => tracks,
  };

  /// `hooks`: let [beforePlay] change it first.
  void playTracks(List<Track> tracks, int start, {bool hooks = true}) {
    if (hooks && beforePlay != null && tracks.isNotEmpty) {
      beforePlay!(tracks, start).then((changed) {
        if (changed != null) {
          playTracks(changed.tracks, changed.start, hooks: false);
        }
      });
      return;
    }
    tracks = _substituted(tracks);
    if (_remote case final remote?) {
      return remote.play(tracks, start, 'replace');
    }
    var queue = tracks;
    _unshuffled = null;
    if (shuffle && tracks.length > 1) {
      _unshuffled = List.unmodifiable(tracks);
      final rest = [...tracks]..removeAt(start);
      queue = [tracks[start], ...rest..shuffle(Random())];
      start = 0;
    }
    this.queue = List.unmodifiable(queue);
    index = start;
    signalPath = null;
    error = null;
    position.value = 0;
    _counted = false;
    notifyListeners();
    playerPlayQueue(paths: [for (final t in queue) t.path], start: start);
    _save();
  }

  /// Plays `tracks` right after the current one.
  void playNext(List<Track> tracks) {
    tracks = _substituted(tracks);
    if (_remote case final remote?) return remote.play(tracks, 0, 'next');
    if (current == null) return playTracks(tracks, 0);
    _edit([
      ...queue.sublist(0, index + 1),
      ...tracks,
      ...queue.sublist(index + 1),
    ], index);
  }

  void addToQueue(List<Track> tracks) {
    tracks = _substituted(tracks);
    if (_remote case final remote?) return remote.play(tracks, 0, 'append');
    if (current == null) return playTracks(tracks, 0);
    _edit([...queue, ...tracks], index);
  }

  /// Plays queue entry `i`, keeping the queue.
  void jumpTo(int i) {
    if (i < 0 || i >= queue.length) return;
    if (_remote case final remote?) return remote.command('jump', {'index': i});
    final unshuffled = _unshuffled;
    final wasShuffled = shuffle;
    shuffle = false;
    playTracks(queue, i, hooks: false);
    shuffle = wasShuffled;
    _unshuffled = unshuffled;
  }

  void removeAt(int i) {
    if (i == index || i < 0 || i >= queue.length) return;
    if (_remote case final remote?) {
      return remote.command('remove', {'index': i});
    }
    _edit([...queue]..removeAt(i), i < index ? index - 1 : index);
  }

  /// Moves queue entry `from` so it ends up at `to` (an index in the list after removal).
  void move(int from, int to) {
    if (from == to) return;
    if (_remote case final remote?) {
      return remote.command('move', {'from': from, 'to': to});
    }
    final track = queue[from];
    final edited = [...queue]..removeAt(from);
    edited.insert(to, track);
    final now = current!;
    _edit(edited, edited.indexWhere((t) => identical(t, now)));
  }

  /// Swaps queue entries for updated copies of the same files (new art, say) without
  /// touching playback.
  void updateTracks(Track Function(Track) update) {
    queue = List.unmodifiable(queue.map(update));
    notifyListeners();
  }

  void clearUpNext() {
    if (_remote case final remote?) return remote.command('clearUpNext');
    _edit(queue.sublist(0, index + 1), index);
  }

  void toggleShuffle() {
    if (_remote case final remote?) return remote.command('shuffle');
    shuffle = !shuffle;
    final now = current;
    if (now == null) return notifyListeners();
    if (shuffle) {
      final unshuffled = queue;
      _edit([
        ...queue.sublist(0, index + 1),
        ...[...upNext]..shuffle(Random()),
      ], index);
      _unshuffled = unshuffled;
    } else if (_unshuffled case final original?) {
      _edit(original, original.indexWhere((t) => identical(t, now)));
    } else {
      notifyListeners();
    }
  }

  /// Off → all → one → off.
  void cycleRepeat() =>
      setRepeat(Repeat.values[(repeat.index + 1) % Repeat.values.length]);

  void setRepeat(Repeat mode) {
    if (_remote case final remote?) {
      return remote.command('repeat', {'mode': mode.name});
    }
    repeat = mode;
    playerSetRepeat(mode: mode);
    notifyListeners();
    _save();
  }

  void _edit(List<Track> edited, int index) {
    _unshuffled = null;
    queue = List.unmodifiable(edited);
    this.index = index;
    notifyListeners();
    playerEditQueue(paths: [for (final t in queue) t.path], index: index);
    _save();
  }

  void toggle() {
    if (current == null) return;
    if (_remote case final remote?) return remote.command('toggle');
    playing ? playerPause() : playerPlay();
  }

  void play() {
    if (current == null || playing) return;
    if (_remote case final remote?) return remote.command('play');
    playerPlay();
  }

  void pause() {
    if (!playing) return;
    if (_remote case final remote?) return remote.command('pause');
    playerPause();
  }

  void next() => _remote != null ? _remote!.command('next') : playerNext();
  void previous() =>
      _remote != null ? _remote!.command('previous') : playerPrevious();

  void seek(double secs) {
    position.value = secs;
    if (_remote case final remote?) {
      return remote.command('seek', {'secs': secs});
    }
    playerSeek(secs: secs);
    _save();
  }

  /// Loads the last session's queue, paused where it was left. `find` maps a saved path
  /// back to a library track (or null if it's gone).
  Future<void> restore(Track? Function(String path) find) async {
    final session = this.session;
    if (session == null || current != null || _remote != null) return;
    try {
      final saved = jsonDecode(await session.readAsString()) as Map;
      final paths = (saved['queue'] as List).cast<String>();
      var start = saved['index'] as int;
      final tracks = <Track>[];
      for (final (i, path) in paths.indexed) {
        final track = find(path);
        if (track != null) {
          tracks.add(track);
        } else if (i < start) {
          start--;
        }
      }
      if (tracks.isEmpty || current != null) return;
      start = start.clamp(0, tracks.length - 1);
      final at =
          paths[min(saved['index'] as int, paths.length - 1)] ==
              tracks[start].path
          ? (saved['position'] as num).toDouble()
          : 0.0;
      shuffle = saved['shuffle'] == true;
      repeat = Repeat.values.asNameMap()[saved['repeat']] ?? Repeat.off;
      playerSetRepeat(mode: repeat);
      queue = List.unmodifiable(tracks);
      index = start;
      position.value = at;
      _savedAt = at;
      _counted = true;
      notifyListeners();
      playerCueQueue(
        paths: [for (final t in tracks) t.path],
        start: start,
        at: at,
      );
    } on Object {
      // Nothing saved yet, or from an older version.
    }
  }

  /// Writes the session soon, once things settle.
  void _save() {
    if (session == null || _remote != null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), saveNow);
  }

  /// Writes the session right away, e.g. before quitting.
  Future<void> saveNow() async {
    _saveTimer?.cancel();
    final session = this.session;
    if (session == null || _remote != null) return;
    _savedAt = position.value;
    try {
      await session.writeAsString(
        jsonEncode({
          'queue': [for (final t in queue) t.path],
          'index': index,
          'position': position.value,
          'shuffle': shuffle,
          'repeat': repeat.name,
        }),
      );
    } on Object catch (e) {
      debugPrint('saving the session: $e');
    }
  }

  void _onPosition(double secs) {
    position.value = secs;
    if ((secs - _savedAt).abs() >= 10) _save();
    final track = current;
    if (!_counted &&
        track != null &&
        secs >= min(240, track.durationSecs / 2)) {
      _counted = true;
      onListened?.call(track);
    }
  }

  void _onEvent(PlayerEvent event) {
    // This device's engine stays paused while casting; anything still on its way from
    // before is about the queue in _local.
    if (_remote != null) return;
    switch (event) {
      case PlayerEvent_Loaded(:final index):
        this.index = index;
        signalPath = null;
        error = null;
        position.value = 0;
        _counted = false;
        _save();
      case PlayerEvent_Path(:final path):
        signalPath = path;
      case PlayerEvent_Playing(:final playing):
        this.playing = playing;
        _save();
      case PlayerEvent_Position(:final secs):
        _onPosition(secs);
        return;
      case PlayerEvent_Ended():
        position.value = 0;
      case PlayerEvent_Error(:final message, :final index):
        error = message;
        if (index < queue.length) this.index = index;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _events.cancel();
    _saveTimer?.cancel();
    position.dispose();
    super.dispose();
  }
}
