import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../rust/api/library.dart';
import 'widgets.dart';

const _extensions = ['m3u', 'm3u8', 'pls', 'xspf'];

/// Asks for a playlist file (.m3u, .m3u8, .pls, .xspf) from anywhere and copies it into a
/// playlist of the songs it lists that are in the library. Returns that playlist.
Future<Playlist?> importPlaylistFile(BuildContext context) async {
  final playlists = AppScope.of(context).playlists;
  final file = await openFile(
    // Phones' file pickers know these files by unreliable types: offer every file there.
    acceptedTypeGroups: Platform.isAndroid
        ? const []
        : const [
            XTypeGroup(
              label: 'Playlist files',
              extensions: _extensions,
              mimeTypes: [
                'audio/x-mpegurl',
                'audio/mpegurl',
                'application/vnd.apple.mpegurl',
                'audio/x-scpls',
                'application/xspf+xml',
              ],
            ),
          ],
  );
  if (file == null || !context.mounted) return null;
  final ext = file.name.split('.').last.toLowerCase();
  if (!_extensions.contains(ext)) {
    _tell(context, '${file.name} isn\'t a playlist file (.m3u, .pls or .xspf)');
    return null;
  }
  final PlaylistFile read;
  try {
    read = await libraryReadPlaylistFile(
      path: file.path,
      name: file.name,
      bytes: await file.readAsBytes(),
    );
  } on Object catch (e) {
    if (context.mounted) _tell(context, 'Couldn\'t read ${file.name}: $e');
    return null;
  }
  if (!context.mounted) return null;
  if (read.paths.isEmpty) {
    _tell(
      context,
      read.entries == 0
          ? '"${read.name}" is empty'
          : 'None of the ${read.entries} songs in "${read.name}" are in your library',
    );
    return null;
  }
  final playlist = await playlists.create(read.name, read.paths);
  if (context.mounted) {
    final missing = read.entries - read.paths.length;
    _tell(
      context,
      'Imported "${read.name}": ${read.paths.length} songs'
      '${missing > 0 ? ' ($missing not in your library)' : ''}',
    );
  }
  return playlist;
}

void _tell(BuildContext context, String message) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
