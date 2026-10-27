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

  /// Of the songs queued since the queue was last empty: how many are finished
  /// (downloaded, or skipped as already here) and how many failed.
  int done = 0;
  int failed = 0;
  int skipped = 0;
  Track? current;
  String? lastError;

  int get total => done + failed + _queue.length + (current == null ? 0 : 1);
  bool get busy => current != null || _queue.isNotEmpty;

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
    final queued = {for (final t in _queue) t.path, ?current?.path};
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
    notifyListeners();
    if (current == null) unawaited(_run());
  }

  /// Stops after the song downloading now.
  void cancel() {
    _queue.clear();
    notifyListeners();
  }

  Future<void> _run() async {
    var saved = 0;
    while (_queue.isNotEmpty) {
      final track = _queue.removeAt(0);
      current = track;
      notifyListeners();
      try {
        if (await _download(track)) {
          saved++;
        } else {
          skipped++;
        }
        done++;
      } on Object catch (e) {
        failed++;
        lastError = '${track.title}: ${streamingError(e)}';
        debugPrint('download ${track.path}: $e');
      }
      // Show them in the library a few at a time.
      if (saved > 0 && saved % 10 == 0) await _addToLibrary();
    }
    current = null;
    notifyListeners();
    if (saved > 0) await _addToLibrary();
  }

  /// Downloads the best copy of [track]. False when skipped: the user has the song as
  /// good already.
  Future<bool> _download(Track track) async {
    final best = await streaming.best(track);
    if (streaming.localCopy(best) != null) return false;
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

  /// The folder is part of the library (added the first time), and rescanned.
  Future<void> _addToLibrary() async {
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
