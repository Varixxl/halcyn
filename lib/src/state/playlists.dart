import 'package:flutter/foundation.dart';

import '../rust/api/library.dart';

/// The user's own playlists. Edits show at once and are saved in the background.
class PlaylistsController extends ChangeNotifier {
  List<Playlist> playlists = const [];

  Future<void> load() async {
    playlists = await libraryPlaylists();
    notifyListeners();
  }

  Playlist? byId(int id) => playlists.where((p) => p.id == id).firstOrNull;

  Future<Playlist> create(String name, [List<String> paths = const []]) async {
    final id = await libraryCreatePlaylist(name: name, paths: paths);
    final playlist = Playlist(id: id, name: name, paths: paths);
    playlists = [...playlists, playlist];
    notifyListeners();
    return playlist;
  }

  void rename(Playlist playlist, String name) {
    _replace(Playlist(id: playlist.id, name: name, paths: playlist.paths));
    libraryRenamePlaylist(id: playlist.id, name: name);
  }

  void delete(Playlist playlist) {
    playlists = [
      for (final p in playlists)
        if (p.id != playlist.id) p,
    ];
    notifyListeners();
    libraryDeletePlaylist(id: playlist.id);
  }

  void add(Playlist playlist, List<String> paths) =>
      _setPaths(playlist, [...?byId(playlist.id)?.paths, ...paths]);

  void removeAt(Playlist playlist, int index) =>
      _setPaths(playlist, [...byId(playlist.id)!.paths]..removeAt(index));

  /// Moves entry `from` so it ends up at `to` (an index in the list after removal).
  void move(Playlist playlist, int from, int to) {
    final paths = [...byId(playlist.id)!.paths];
    paths.insert(to, paths.removeAt(from));
    _setPaths(playlist, paths);
  }

  void _setPaths(Playlist playlist, List<String> paths) {
    _replace(Playlist(id: playlist.id, name: playlist.name, paths: paths));
    librarySetPlaylistTracks(id: playlist.id, paths: paths);
  }

  void _replace(Playlist playlist) {
    playlists = [for (final p in playlists) p.id == playlist.id ? playlist : p];
    notifyListeners();
  }
}
