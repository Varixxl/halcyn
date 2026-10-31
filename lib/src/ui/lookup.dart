import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../rust/api/library.dart';
import '../rust/api/streaming.dart';
import '../state/library.dart';
import '../state/streaming.dart';
import '../theme.dart';
import 'albums_page.dart';
import 'artists_page.dart';
import 'shell.dart';
import 'slate.dart';
import 'streaming.dart';
import 'track_list.dart';
import 'widgets.dart';
import 'window_frame.dart';

// Going from an artist's or album's name to its page: the library's own when it's there,
// else what Tidal or YouTube Music has.

/// Opens [page] in the main view, closing Now Playing (or anything else on top) first.
void _go(BuildContext context, Widget page) {
  appNavigator.currentState?.popUntil((route) => route.isFirst);
  (contentPages.currentState ?? Navigator.of(context)).push(
    MaterialPageRoute<void>(builder: (_) => page),
  );
}

void _tell(BuildContext context, String message) =>
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          width: 320,
        ),
      );

/// Lowercase letters and digits, without "(Remastered)", "[Deluxe]" and the like.
String _plain(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[(\[].*?[)\]]'), '')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

/// The first of several artists in one tag: "A, B", "A & B", "A feat. B".
String _lead(String name) => name
    .split(RegExp(r',|;|&| feat\.? | ft\.? | x | with ', caseSensitive: false))
    .first
    .trim();

String _albumArtist(Track track) =>
    track.albumArtist ?? track.artists.firstOrNull ?? 'Unknown artist';

/// Whether [openArtist] / [openAlbum] have somewhere to go for [track].
bool canOpenArtist(BuildContext context, String name) {
  final scope = AppScope.of(context);
  return scope.streaming.linked ||
      scope.library.artists.any(
        (a) => a.name.toLowerCase() == name.toLowerCase(),
      );
}

bool canOpenAlbum(BuildContext context, Track track) =>
    track.album != null &&
    (AppScope.of(context).streaming.linked ||
        _localAlbum(context, track) != null);

/// The artist's page in the library, or else on the first linked service.
void openArtist(BuildContext context, String name) {
  final scope = AppScope.of(context);
  final key = name.toLowerCase();
  final local = scope.library.artists
      .where((a) => a.name.toLowerCase() == key)
      .firstOrNull;
  if (local != null) return _go(context, ArtistPage(artist: local));
  if (!scope.streaming.linked) {
    return _tell(context, '$name isn\'t in your library');
  }
  _go(context, ServiceArtistPage(name: name));
}

/// The artist's page on a service ([service], or the first linked one).
void openRemoteArtist(
  BuildContext context,
  String name, {
  String? service,
  String? id,
}) => _go(context, ServiceArtistPage(name: name, service: service, id: id));

Album? _localAlbum(BuildContext context, Track track) {
  final title = track.album?.toLowerCase();
  final artist = _albumArtist(track).toLowerCase();
  return AppScope.of(context).library.albums
      .where(
        (a) =>
            a.title.toLowerCase() == title && a.artist.toLowerCase() == artist,
      )
      .firstOrNull;
}

/// The album [track] is on: the library's, or else the first linked service's.
void openAlbum(BuildContext context, Track track) {
  final title = track.album;
  if (title == null) return;
  final local = _localAlbum(context, track);
  if (local != null) return _go(context, AlbumPage(album: local));
  if (!AppScope.of(context).streaming.linked) {
    return _tell(context, '$title isn\'t in your library');
  }
  _go(context, ServiceAlbumPage(title: title, artist: _albumArtist(track)));
}

/// Buttons that look an artist (or, with [album], an album) up on each linked service.
class FindOnServices extends StatelessWidget {
  const FindOnServices({super.key, required this.artist, this.album});

  final String artist;
  final String? album;

  @override
  Widget build(BuildContext context) {
    final streaming = AppScope.of(context).streaming;
    return ListenableBuilder(
      listenable: streaming,
      builder: (context, _) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final s in streaming.services)
            OutlinedButton.icon(
              onPressed: () => _go(context, switch (album) {
                final album? => ServiceAlbumPage(
                  title: album,
                  artist: artist,
                  service: s,
                ),
                null => ServiceArtistPage(name: artist, service: s),
              }),
              icon: const Icon(Icons.travel_explore_rounded, size: 18),
              label: Text(serviceNames[s]!),
            ),
        ],
      ),
    );
  }
}

/// Picks one of the linked services, when there's more than one.
class _ServiceSwitch extends StatelessWidget {
  const _ServiceSwitch({required this.service, required this.onChanged});

  final String service;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context).streaming.services;
    if (services.length < 2) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      children: [
        for (final s in services)
          ChoiceChip(
            label: Text(serviceNames[s]!),
            selected: s == service,
            onSelected: (_) => onChanged(s),
          ),
      ],
    );
  }
}

/// Names to click, like "Artist, Artist": each opens with [onOpen].
class NameLinks extends StatefulWidget {
  const NameLinks({
    super.key,
    required this.names,
    required this.onOpen,
    this.style,
    this.suffix,
  });

  final List<String> names;
  final ValueChanged<String> onOpen;
  final TextStyle? style;

  /// Plain text after the names (" · 1997").
  final String? suffix;

  @override
  State<NameLinks> createState() => _NameLinksState();
}

class _NameLinksState extends State<NameLinks> {
  final _taps = <TapGestureRecognizer>[];
  int? _hover;

  @override
  void dispose() {
    for (final t in _taps) {
      t.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final names = widget.names;
    while (_taps.length < names.length) {
      _taps.add(TapGestureRecognizer());
    }
    return Text.rich(
      TextSpan(
        children: [
          for (final (i, name) in names.indexed) ...[
            if (i > 0) const TextSpan(text: ', '),
            TextSpan(
              text: name,
              recognizer: _taps[i]..onTap = () => widget.onOpen(name),
              mouseCursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hover = i),
              onExit: (_) => setState(() => _hover = null),
              style: _hover == i
                  ? const TextStyle(decoration: TextDecoration.underline)
                  : null,
            ),
          ],
          if (widget.suffix case final suffix?) TextSpan(text: suffix),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: widget.style,
    );
  }
}

// ---- an artist on a service ----

typedef _ArtistFound = ({
  RemoteArtistPage? page,
  List<Track> tracks,
  List<RemoteArtist> choices,
});

/// An artist on Tidal or YouTube Music: popular songs, albums, singles and EPs, and
/// artists like them. Found by [name], unless the service's [id] is known.
class ServiceArtistPage extends StatefulWidget {
  const ServiceArtistPage({
    super.key,
    required this.name,
    this.service,
    this.id,
  });

  final String name;
  final String? service;
  final String? id;

  @override
  State<ServiceArtistPage> createState() => _ServiceArtistPageState();
}

class _ServiceArtistPageState extends State<ServiceArtistPage> {
  static const _few = 5;
  late String _service;
  Future<_ArtistFound>? _found;
  bool _all = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_found != null) return;
    final services = AppScope.of(context).streaming.services;
    _service = widget.service ?? services.firstOrNull ?? 'tidal';
    _found = _load(widget.id);
  }

  Future<_ArtistFound> _load(String? id) async {
    final streaming = AppScope.of(context).streaming;
    final service = _service;
    if (id == null) {
      // The whole name first ("Simon & Garfunkel"), then the lead artist of a tag that
      // names several.
      final name = widget.name, lead = _lead(name);
      RemoteArtist? pick(List<RemoteArtist> found) =>
          found.where((a) => _plain(a.name) == _plain(name)).firstOrNull ??
          found.where((a) => _plain(a.name) == _plain(lead)).firstOrNull;
      var found = await streaming.searchArtists(service, name);
      var hit = pick(found);
      if (hit == null && lead != name && lead.isNotEmpty) {
        final more = await streaming.searchArtists(service, lead);
        hit = pick(more);
        found = [
          ...found,
          ...more.where((m) => !found.any((f) => f.id == m.id)),
        ];
      }
      if (hit == null) return (page: null, tracks: <Track>[], choices: found);
      id = hit.id;
    }
    final (page, tracks) = await streaming.artist(service, id);
    return (page: page, tracks: tracks, choices: <RemoteArtist>[]);
  }

  void _switch(String service) {
    if (service == _service) return;
    setState(() {
      _service = service;
      _all = false;
      // An id belongs to one service: look the name up on the other.
      _found = _load(service == widget.service ? widget.id : null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: FutureBuilder(
        future: _found,
        builder: (context, snap) => LayoutBuilder(
          builder: (context, box) => CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _header(context, snap.data)),
              ..._body(context, snap, TrackColumns.of(box.maxWidth)),
              SliverPadding(
                padding: EdgeInsets.only(bottom: 24 + dockInset(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, _ArtistFound? found) {
    final theme = Theme.of(context);
    final player = AppScope.of(context).player;
    final page = found?.page;
    final songs = found?.tracks ?? const <Track>[];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          RemoteCover(url: page?.artist.artUrl, size: 132, round: true),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                  label: const Text('Back'),
                ),
                Text(
                  page?.artist.name ?? widget.name,
                  style: theme.textTheme.headlineSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  'Artist · ${serviceNames[_service]}',
                  style: TextStyle(color: Palette.textMuted),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: songs.isEmpty
                          ? null
                          : () => player.playTracks(songs, 0),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Play'),
                    ),
                    _ServiceSwitch(service: _service, onChanged: _switch),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _body(
    BuildContext context,
    AsyncSnapshot<_ArtistFound> snap,
    TrackColumns columns,
  ) {
    Widget box(Widget child) => SliverToBoxAdapter(child: child);
    if (snap.hasError) {
      return [
        box(
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              streamingError(snap.error!),
              style: TextStyle(color: Palette.warm),
            ),
          ),
        ),
      ];
    }
    final found = snap.data;
    if (found == null) {
      return [
        box(
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ];
    }
    final page = found.page;
    if (page == null) {
      return [
        box(
          SectionLabel(
            found.choices.isEmpty
                ? 'No artist called ${widget.name} on ${serviceNames[_service]}'
                : 'Is it one of these?',
          ),
        ),
        if (found.choices.isNotEmpty) box(_artists(context, found.choices)),
      ];
    }
    final player = AppScope.of(context).player;
    final tracks = found.tracks;
    final shown = _all ? tracks : tracks.take(_few).toList();
    return [
      if (tracks.isNotEmpty) ...[
        box(
          SectionLabel(
            'Popular',
            trailing: tracks.length > _few
                ? TextButton(
                    onPressed: () => setState(() => _all = !_all),
                    child: Text(_all ? 'Fewer' : 'Show all'),
                  )
                : null,
          ),
        ),
        SliverFixedExtentList.builder(
          itemExtent: TrackRow.height,
          itemCount: shown.length,
          itemBuilder: (context, i) => TrackRow(
            track: shown[i],
            number: i + 1,
            columns: columns,
            onTap: () => player.playTracks(tracks, i),
          ),
        ),
      ],
      if (page.albums.isNotEmpty) ...[
        box(const SectionLabel('Albums')),
        box(_albums(context, page.albums)),
      ],
      if (page.singles.isNotEmpty) ...[
        box(const SectionLabel('Singles and EPs')),
        box(_albums(context, page.singles)),
      ],
      if (page.similar.isNotEmpty) ...[
        box(const SectionLabel('Fans also like')),
        box(_artists(context, page.similar)),
      ],
    ];
  }

  Widget _albums(BuildContext context, List<RemoteAlbum> albums) =>
      _Row(children: [for (final a in albums) _AlbumCard(album: a)]);

  Widget _artists(BuildContext context, List<RemoteArtist> artists) => _Row(
    children: [
      for (final a in artists)
        RemoteCard(
          image: RemoteCover(url: a.artUrl, size: _Row.card, round: true),
          title: a.name,
          subtitle: '',
          center: true,
          onTap: () =>
              openRemoteArtist(context, a.name, service: a.service, id: a.id),
        ),
    ],
  );
}

/// Cards in a row that scrolls sideways.
class _Row extends StatelessWidget {
  const _Row({required this.children});

  static const card = 148.0;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: card + 60,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      children: children,
    ),
  );
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album});

  final RemoteAlbum album;

  @override
  Widget build(BuildContext context) => RemoteCard(
    image: RemoteCover(url: album.artUrl, size: _Row.card),
    title: album.title,
    subtitle: [
      if (album.kind case final kind? when kind != 'Album') kind,
      if (album.year case final year?) '$year',
    ].join(' · '),
    onTap: () => _go(
      context,
      RemoteListPage(list: _asList(album), artists: album.artists),
    ),
  );
}

RemotePlaylist _asList(RemoteAlbum album) => RemotePlaylist(
  service: album.service,
  id: album.id,
  name: album.title,
  artUrl: album.artUrl,
);

// ---- an album on a service ----

/// An album on Tidal or YouTube Music, found by its title and artist: its songs, or the
/// closest matches when none is clearly it.
class ServiceAlbumPage extends StatefulWidget {
  const ServiceAlbumPage({
    super.key,
    required this.title,
    required this.artist,
    this.service,
  });

  final String title;
  final String artist;
  final String? service;

  @override
  State<ServiceAlbumPage> createState() => _ServiceAlbumPageState();
}

class _ServiceAlbumPageState extends State<ServiceAlbumPage> {
  late String _service;
  Future<List<RemoteAlbum>>? _found;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_found != null) return;
    final services = AppScope.of(context).streaming.services;
    _service = widget.service ?? services.firstOrNull ?? 'tidal';
    _found = _search();
  }

  Future<List<RemoteAlbum>> _search() =>
      AppScope.of(context).streaming
          .searchAlbums(_service, '${widget.artist} ${widget.title}');

  void _switch(String service) {
    if (service == _service) return;
    setState(() {
      _service = service;
      _found = _search();
    });
  }

  /// The album that's clearly this one: the same title (give or take "(Deluxe)"), by the
  /// same artist when the service names one.
  RemoteAlbum? _match(List<RemoteAlbum> found) {
    final title = _plain(widget.title);
    final artist = {_plain(widget.artist), _plain(_lead(widget.artist))};
    bool byArtist(RemoteAlbum a) =>
        a.artists.isEmpty || a.artists.any((x) => artist.contains(_plain(x)));
    return found
            .where((a) => _plain(a.title) == title && byArtist(a))
            .firstOrNull ??
        found
            .where(
              (a) =>
                  byArtist(a) &&
                  title.isNotEmpty &&
                  _plain(a.title).startsWith(title),
            )
            .firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final switcher = _ServiceSwitch(service: _service, onChanged: _switch);
    return FutureBuilder(
      future: _found,
      builder: (context, snap) {
        final found = snap.data;
        if (found != null) {
          if (_match(found) case final album?) {
            return RemoteListPage(
              key: ValueKey('${album.service} ${album.id}'),
              list: _asList(album),
              artists: album.artists,
              extra: switcher,
            );
          }
        }
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: ListView(
            padding: EdgeInsets.fromLTRB(8, 8, 8, 24 + dockInset(context)),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                  label: const Text('Back'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    Text(
                      '${widget.artist} · ${serviceNames[_service]}',
                      style: TextStyle(color: Palette.textMuted),
                    ),
                    const SizedBox(height: 10),
                    switcher,
                  ],
                ),
              ),
              if (snap.hasError)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    streamingError(snap.error!),
                    style: TextStyle(color: Palette.warm),
                  ),
                )
              else if (found == null)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                SectionLabel(
                  found.isEmpty
                      ? 'Not on ${serviceNames[_service]}'
                      : 'Not found exactly. Is it one of these?',
                ),
                if (found.isNotEmpty)
                  _Row(children: [for (final a in found) _AlbumCard(album: a)]),
              ],
            ],
          ),
        );
      },
    );
  }
}
