import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../rust/api/library.dart';
import '../rust/api/streaming.dart';
import 'library.dart';
import 'streaming.dart';

/// Downloads streamed songs into a folder of their own, `Artist/Album/Title`, each from
/// whichever linked service has it best (Tidal's FLAC over YouTube Music's AAC), skipping
/// songs the user already has as good. The folder is part of the library, so downloads
/// show up with the rest.
class DownloadsController extends ChangeNotifier {
  DownloadsController({
    required this.library,
    required this.streaming,
    required this.settings,
    String? folder,
    this.persist = true,
  }) : folder = folder ?? defaultFolder();

  final LibraryController library;
  final StreamingController streaming;

  /// `downloads.json`: the folder.
  final File settings;
  final bool persist;

  String folder;

  final _queue = <Track>[];

  /// Songs downloading now, and which service's copy each is (once that's chosen).
  final _active = <Track, String?>{};

  /// Of the songs queued since the queue was last empty: how many are finished
  /// (downloaded, or skipped as already here) and how many failed.
  int done = 0;
  int failed = 0;
  int skipped = 0;
  String? lastError;
  int _saved = 0;
  Timer? _ticker;
  Future<void>? _adding;

  /// Songs downloaded at once, as VarMusic does: each also fetches several parts at once.
  static const atOnce = 3;

  int get total => done + failed + _queue.length + _active.length;
  bool get busy => _active.isNotEmpty || _queue.isNotEmpty;
  Iterable<Track> get downloading => _active.keys;

  /// How far along the songs downloading now are, 0 to 1 each.
  double progressOf(Track track) {
    final path = _active[track];
    if (path == null) return 0;
    try {
      return streamingDownloadProgress(path: path) ?? 0;
    } on Object {
      return 0;
    }
  }

  /// Of everything queued, how much is done, songs under way counting in part.
  double get progress {
    if (total == 0) return 0;
    final partly = _active.keys.fold(0.0, (sum, t) => sum + progressOf(t));
    return ((done + failed + partly) / total).clamp(0, 1);
  }

  static String defaultFolder() {
    if (Platform.isAndroid) return '/storage/emulated/0/Music/Halcyn Downloads';
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    return '$home${Platform.pathSeparator}Music${Platform.pathSeparator}'
        'Halcyn Downloads';
  }

  Future<void> load() async {
    if (!persist) return;
    try {
      final json = jsonDecode(await settings.readAsString()) as Map;
      if (json['folder'] case final String f when f.isNotEmpty) folder = f;
    } on Object {
      // The default, then.
    }
  }

  Future<void> setFolder(String folder) async {
    this.folder = folder;
    notifyListeners();
    if (!persist) return;
    try {
      await settings.writeAsString(jsonEncode({'folder': folder}));
    } on Object catch (e) {
      debugPrint('saving download settings: $e');
    }
  }

  /// Queues the streamed songs among [tracks] (the user's own files are here already).
  void add(Iterable<Track> tracks) {
    final queued = {
      for (final t in _queue) t.path,
      for (final t in _active.keys) t.path,
    };
    final adding = [
      for (final t in tracks)
        if (isStream(t.path) && queued.add(t.path)) t,
    ];
    if (adding.isEmpty) return;
    if (!busy) {
      done = 0;
      failed = 0;
      skipped = 0;
      lastError = null;
    }
    _queue.addAll(adding);
    // The bars move between songs too.
    _ticker ??= Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => notifyListeners(),
    );
    _next();
    notifyListeners();
  }

  /// Stops after the songs downloading now.
  void cancel() {
    _queue.clear();
    notifyListeners();
  }

  void _next() {
    while (_active.length < atOnce && _queue.isNotEmpty) {
      final track = _queue.removeAt(0);
      _active[track] = null;
      unawaited(_one(track));
    }
  }

  Future<void> _one(Track track) async {
    try {
      if (await _download(track)) {
        _saved++;
      } else {
        skipped++;
      }
      done++;
    } on Object catch (e) {
      failed++;
      lastError = '${track.title}: ${streamingError(e)}';
      debugPrint('download ${track.path}: $e');
    }
    _active.remove(track);
    _next();
    notifyListeners();
    if (busy) {
      // Show them in the library a few at a time.
      if (_saved >= 10) {
        _saved = 0;
        await _addToLibrary();
      }
      return;
    }
    _ticker?.cancel();
    _ticker = null;
    if (_saved > 0) {
      _saved = 0;
      await _addToLibrary();
    }
  }

  /// Downloads the best copy of [track]. False when skipped: the user has the song as
  /// good already.
  Future<bool> _download(Track track) async {
    final best = await streaming.best(track);
    if (streaming.localCopy(best) != null) return false;
    _active[track] = best.path;
    await streamingSave(
      path: best.path,
      folder: folder,
      title: track.title,
      artists: track.artists,
      album: track.album ?? best.album,
      art: best.art ?? track.art,
    );
    return true;
  }

  /// The folder is part of the library (added the first time), and rescanned. One at a
  /// time: songs finish together.
  Future<void> _addToLibrary() async {
    for (var other = _adding; other != null; other = _adding) {
      await other;
    }
    final adding = _addFolder();
    _adding = adding;
    try {
      await adding;
    } finally {
      _adding = null;
    }
  }

  Future<void> _addFolder() async {
    // A scan under way might have passed the new files by.
    while (library.scanning != null) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    final inside = library.folders.any(
      (f) =>
          folder == f ||
          folder.startsWith('$f${Platform.pathSeparator}') ||
          folder.startsWith('$f/'),
    );
    if (inside) {
      await library.rescan();
    } else {
      await library.setFolders([...library.folders, folder]);
    }
  }
}
