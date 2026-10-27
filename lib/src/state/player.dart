import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../rust/api/library.dart';
import '../rust/api/player.dart';

/// Mirrors the engine: the queue, what's playing, and where. Also keeps the session (queue
/// and position) in `session` so the next start picks up where this one left off.
class PlayerController extends ChangeNotifier {
  PlayerController({this.session, this.onListened}) {
    _events = playerEvents().listen(_onEvent);
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

  void playTracks(List<Track> tracks, int start) {
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
    if (current == null) return playTracks(tracks, 0);
    _edit([
      ...queue.sublist(0, index + 1),
      ...tracks,
      ...queue.sublist(index + 1),
    ], index);
  }

  void addToQueue(List<Track> tracks) {
    if (current == null) return playTracks(tracks, 0);
    _edit([...queue, ...tracks], index);
  }

  /// Plays queue entry `i`, keeping the queue.
  void jumpTo(int i) {
    if (i < 0 || i >= queue.length) return;
    final unshuffled = _unshuffled;
    final wasShuffled = shuffle;
    shuffle = false;
    playTracks(queue, i);
    shuffle = wasShuffled;
    _unshuffled = unshuffled;
  }

  void removeAt(int i) {
    if (i == index || i < 0 || i >= queue.length) return;
    _edit([...queue]..removeAt(i), i < index ? index - 1 : index);
  }

  /// Moves queue entry `from` so it ends up at `to` (an index in the list after removal).
  void move(int from, int to) {
    if (from == to) return;
    final track = queue[from];
    final edited = [...queue]..removeAt(from);
    edited.insert(to, track);
    final now = current!;
    _edit(edited, edited.indexWhere((t) => identical(t, now)));
  }

  void clearUpNext() => _edit(queue.sublist(0, index + 1), index);

  void toggleShuffle() {
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
    playing ? playerPause() : playerPlay();
  }

  void play() {
    if (current != null && !playing) playerPlay();
  }

  void pause() {
    if (playing) playerPause();
  }

  void next() => playerNext();
  void previous() => playerPrevious();

  void seek(double secs) {
    position.value = secs;
    playerSeek(secs: secs);
    _save();
  }

  /// Loads the last session's queue, paused where it was left. `find` maps a saved path
  /// back to a library track (or null if it's gone).
  Future<void> restore(Track? Function(String path) find) async {
    final session = this.session;
    if (session == null || current != null) return;
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
    if (session == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), () async {
      _savedAt = position.value;
      try {
        await session!.writeAsString(
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
    });
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
      case PlayerEvent_Error(:final message):
        error = message;
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
