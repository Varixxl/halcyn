import 'dart:async';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../rust/api/library.dart';
import '../rust/api/streaming.dart';
import '../state/streaming.dart';
import '../theme.dart';
import 'slate.dart';
import 'track_list.dart';
import 'widgets.dart';

const _android = MethodChannel('halcyn/android');

/// Opens `url` in the computer's browser.
Future<void> openInBrowser(String url) async {
  if (Platform.isWindows) {
    await Process.start('rundll32', ['url.dll,FileProtocolHandler', url]);
  } else {
    await Process.start('xdg-open', [url]);
  }
}

void _tell(BuildContext context, String message) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );

// ---- Home ----

/// The linked services' suggestions, mixed, and the accounts' playlists to open or
/// import.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _lists = <String, Future<List<RemotePlaylist>>>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final streaming = AppScope.of(context).streaming;
    if (streaming.linked) unawaited(streaming.loadHome());
  }

  Future<List<RemotePlaylist>> _playlists(
    StreamingController s,
    String service,
  ) => _lists[service] ??= s.playlistsOf(service);

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final streaming = scope.streaming;
    return ListenableBuilder(
      listenable: streaming,
      builder: (context, _) {
        if (!streaming.linked) {
          return const EmptyState(
            icon: Icons.cloud_outlined,
            message:
                'Sign in to Tidal or YouTube Music in Settings to see what '
                'they suggest for you here.',
          );
        }
        if (streaming.home == null && !streaming.loadingHome) {
          unawaited(streaming.loadHome());
        }
        final home = streaming.home;
        return RefreshIndicator(
          onRefresh: () {
            _lists.clear();
            return streaming.loadHome(again: true);
          },
          child: ListView(
            padding: EdgeInsets.only(bottom: 24 + dockInset(context)),
            children: [
              for (final service in streaming.services)
                FutureBuilder(
                  future: _playlists(streaming, service),
                  builder: (context, snap) => _Shelf(
                    title: 'Your ${serviceNames[service]} playlists',
                    error: snap.hasError ? streamingError(snap.error!) : null,
                    loading: !snap.hasData && !snap.hasError,
                    lists: snap.data ?? const [],
                  ),
                ),
              if (streaming.homeError case final error?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
                  child: Text(error, style: TextStyle(color: Palette.warm)),
                ),
              if (home == null)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                for (final shelf in home)
                  _Shelf(
                    title: shelf.title,
                    service: shelf.service,
                    tracks: [
                      for (final t in shelf.tracks)
                        ?scope.library.byPath(t.path),
                    ],
                    lists: shelf.lists,
                  ),
            ],
          ),
        );
      },
    );
  }
}

/// A row of songs, or of playlists to open.
class _Shelf extends StatelessWidget {
  const _Shelf({
    required this.title,
    this.service,
    this.tracks = const [],
    this.lists = const [],
    this.loading = false,
    this.error,
  });

  final String title;
  final String? service;
  final List<Track> tracks;
  final List<RemotePlaylist> lists;
  final bool loading;
  final String? error;

  static const _card = 148.0;

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    if (!loading && error == null && tracks.isEmpty && lists.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(
          service == null ? title : '$title · ${serviceNames[service]}',
          trailing: tracks.length > 1
              ? TextButton(
                  onPressed: () => player.playTracks(tracks, 0),
                  child: const Text('Play all'),
                )
              : null,
        ),
        if (error case final error?)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Text(error, style: TextStyle(color: Palette.warm)),
          )
        else if (loading)
          const SizedBox(
            height: _card + 48,
            child: Center(child: CircularProgressIndicator()),
          )
        else
          SizedBox(
            height: _card + 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final (i, t) in tracks.indexed)
                  _Card(
                    image: Artwork(
                      art: t.art,
                      size: _card,
                      radius: 12,
                      resolution: ArtSize.medium,
                    ),
                    title: t.title,
                    subtitle: t.artists.join(', '),
                    onTap: () => player.playTracks(tracks, i),
                  ),
                for (final l in lists)
                  _Card(
                    image: _RemoteCover(url: l.artUrl, size: _card),
                    title: l.name,
                    subtitle: l.count == null ? '' : '${l.count} songs',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => RemoteListPage(list: l),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.image,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final Widget image;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Palette.r(12)),
        child: SizedBox(
          width: _Shelf._card,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                image,
                const SizedBox(height: 6),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Palette.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A playlist's cover from the service, or a placeholder.
class _RemoteCover extends StatelessWidget {
  const _RemoteCover({required this.url, required this.size});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Palette.surfaceHigh,
      child: Icon(
        Icons.queue_music_rounded,
        size: size * 0.4,
        color: Palette.textMuted,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(Palette.r(12)),
      child: SizedBox.square(
        dimension: size,
        child: switch (url) {
          final url? => Image.network(
            url,
            fit: BoxFit.cover,
            cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
            errorBuilder: (_, _, _) => placeholder,
          ),
          null => placeholder,
        },
      ),
    );
  }
}

// ---- a service's playlist ----

/// A playlist (or mix, or album) on a service: its songs, to play or import.
class RemoteListPage extends StatefulWidget {
  const RemoteListPage({super.key, required this.list});

  final RemotePlaylist list;

  @override
  State<RemoteListPage> createState() => _RemoteListPageState();
}

class _RemoteListPageState extends State<RemoteListPage> {
  late Future<List<Track>> _tracks;
  double? _importing;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tracks = AppScope.of(context).streaming.tracksOf(widget.list);
  }

  Future<void> _import() async {
    final streaming = AppScope.of(context).streaming;
    setState(() => _importing = 0);
    try {
      final playlist = await streaming.import(
        widget.list,
        progress: (done, total) {
          if (!mounted) return;
          setState(() => _importing = total == 0 ? 1 : done / total);
        },
      );
      if (mounted) {
        _tell(
          context,
          'Imported "${playlist.name}": ${playlist.paths.length} songs',
        );
      }
    } on Object catch (e) {
      if (mounted) _tell(context, 'Couldn\'t import: ${streamingError(e)}');
    } finally {
      if (mounted) setState(() => _importing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = AppScope.of(context).player;
    final list = widget.list;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: FutureBuilder(
        future: _tracks,
        builder: (context, snap) {
          final tracks = snap.data ?? const <Track>[];
          return LayoutBuilder(
            builder: (context, box) {
              final columns = TrackColumns.of(box.maxWidth);
              return CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _RemoteCover(url: list.artUrl, size: 132),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TextButton.icon(
                                  onPressed: () => Navigator.of(context).pop(),
                                  icon: const Icon(
                                    Icons.arrow_back_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Back'),
                                ),
                                Text(
                                  list.name,
                                  style: theme.textTheme.headlineSmall,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  [
                                    serviceNames[list.service] ?? '',
                                    if (snap.hasData) '${tracks.length} songs',
                                  ].join(' · '),
                                  style: TextStyle(color: Palette.textMuted),
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    FilledButton.icon(
                                      onPressed: tracks.isEmpty
                                          ? null
                                          : () => player.playTracks(tracks, 0),
                                      icon: const Icon(
                                        Icons.play_arrow_rounded,
                                      ),
                                      label: const Text('Play'),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed:
                                          tracks.isEmpty || _importing != null
                                          ? null
                                          : _import,
                                      icon: const Icon(Icons.download_rounded),
                                      label: Text(
                                        _importing == null
                                            ? 'Import to Halcyn'
                                            : 'Importing ${(_importing! * 100).round()}%',
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (snap.hasError)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          streamingError(snap.error!),
                          style: TextStyle(color: Palette.warm),
                        ),
                      ),
                    )
                  else if (!snap.hasData)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    )
                  else
                    SliverFixedExtentList.builder(
                      itemExtent: TrackRow.height,
                      itemCount: tracks.length,
                      itemBuilder: (context, i) => TrackRow(
                        track: tracks[i],
                        number: i + 1,
                        columns: columns,
                        onTap: () => player.playTracks(tracks, i),
                      ),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.only(bottom: 24 + dockInset(context)),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

// ---- search ----

/// What the linked services have for a search, below the library's own results.
class RemoteResults extends StatefulWidget {
  const RemoteResults({super.key, required this.query});

  final String query;

  @override
  State<RemoteResults> createState() => _RemoteResultsState();
}

class _RemoteResultsState extends State<RemoteResults> {
  static const _few = 6;
  final _found = <String, Future<List<Track>>>{};
  final _all = <String>{};
  Timer? _settle;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _later();
  }

  @override
  void didUpdateWidget(RemoteResults old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _later();
  }

  /// Searches once typing stops for a moment.
  void _later() {
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      setState(() {
        _query = widget.query.trim();
        _found.clear();
        _all.clear();
      });
    });
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final streaming = scope.streaming;
    if (_query.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, box) {
        final columns = TrackColumns.of(box.maxWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final service in streaming.services)
              FutureBuilder(
                future: _found[service] ??= streaming.search(service, _query),
                builder: (context, snap) {
                  final songs = snap.data ?? const <Track>[];
                  final all = _all.contains(service);
                  final shown = all ? songs : songs.take(_few).toList();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SectionLabel(
                        'On ${serviceNames[service]}',
                        trailing: songs.length > _few
                            ? TextButton(
                                onPressed: () => setState(
                                  () => all
                                      ? _all.remove(service)
                                      : _all.add(service),
                                ),
                                child: Text(all ? 'Fewer' : 'Show all'),
                              )
                            : null,
                      ),
                      if (snap.hasError)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                          child: Text(
                            streamingError(snap.error!),
                            style: TextStyle(color: Palette.warm),
                          ),
                        )
                      else if (!snap.hasData)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: LinearProgressIndicator(),
                        )
                      else if (songs.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                          child: Text(
                            'Nothing there.',
                            style: TextStyle(color: Palette.textMuted),
                          ),
                        )
                      else
                        for (final (i, t) in shown.indexed)
                          SizedBox(
                            height: TrackRow.height,
                            child: TrackRow(
                              track: t,
                              number: i + 1,
                              columns: columns,
                              onTap: () => scope.player.playTracks(songs, i),
                            ),
                          ),
                    ],
                  );
                },
              ),
          ],
        );
      },
    );
  }
}

// ---- Settings ----

/// Linking Tidal and YouTube Music, and how their songs are used.
class StreamingSettings extends StatelessWidget {
  const StreamingSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final streaming = AppScope.of(context).streaming;
    return ListenableBuilder(
      listenable: streaming,
      builder: (context, _) {
        final accounts = streaming.accounts;
        if (accounts == null) return const SizedBox.shrink();
        String signedIn(String? name) =>
            name == null || name.isEmpty ? 'Signed in' : 'Signed in as $name';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
              child: Text('Streaming', style: theme.textTheme.titleMedium),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.waves_rounded),
              title: const Text('Tidal'),
              subtitle: Text(
                !accounts.tidalAvailable
                    ? 'This build of Halcyn can\'t sign in to Tidal'
                    : accounts.tidal == null
                    ? 'Lossless and hi-res FLAC, with a Tidal subscription'
                    : signedIn(accounts.tidal),
              ),
              trailing: !accounts.tidalAvailable
                  ? null
                  : accounts.tidal == null
                  ? FilledButton.tonal(
                      onPressed: () => signInToTidal(context),
                      child: const Text('Sign in'),
                    )
                  : OutlinedButton(
                      onPressed: streaming.tidalSignOut,
                      child: const Text('Sign out'),
                    ),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.smart_display_outlined),
              title: const Text('YouTube Music'),
              subtitle: Text(
                accounts.youtube == null
                    ? 'Your library, mixes and history. Songs play in AAC'
                    : accounts.youtubePlayable
                    ? signedIn(accounts.youtube)
                    : '${signedIn(accounts.youtube)}. Its songs need yt-dlp '
                          'installed to play',
              ),
              trailing: accounts.youtube == null
                  ? FilledButton.tonal(
                      onPressed: () => signInToYouTube(context),
                      child: const Text('Sign in'),
                    )
                  : OutlinedButton(
                      onPressed: streaming.youtubeSignOut,
                      child: const Text('Sign out'),
                    ),
            ),
            if (streaming.linked) ...[
              if (accounts.tidal != null && accounts.youtube != null)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  title: const Text('Importing, look for songs on'),
                  subtitle: const Text(
                    'A playlist\'s songs come from the first service that has '
                    'them as good or better',
                  ),
                  trailing: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'tidal', label: Text('Tidal')),
                      ButtonSegment(value: 'ytm', label: Text('YouTube')),
                    ],
                    selected: {streaming.order.first},
                    onSelectionChanged: (s) => streaming.setOrder([
                      s.first,
                      ...streaming.order.where((o) => o != s.first),
                    ]),
                  ),
                ),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                title: const Text('Prefer my own files'),
                subtitle: const Text(
                  'Play a song from your music folders instead of streaming it '
                  'when your copy is as good or better',
                ),
                value: streaming.preferLocal,
                onChanged: streaming.setPreferLocal,
              ),
              if (accounts.youtube != null)
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  title: const Text('Add what I play to YouTube Music history'),
                  subtitle: const Text(
                    'Streamed songs, and your own files when YouTube Music has '
                    'them. (Tidal has no way to add to its history.)',
                  ),
                  value: streaming.shareHistory,
                  onChanged: streaming.setShareHistory,
                ),
            ],
          ],
        );
      },
    );
  }
}

/// Google's sign-in, ending on YouTube Music.
const _youtubeSignIn =
    'https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&passive=true'
    '&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue'
    '%26next%3Dhttps%3A%2F%2Fmusic.youtube.com%2F';

/// The sign-in window couldn't open (no WebKitGTK or WebView2).
class _NoWindow implements Exception {}

/// A service's sign-in page in a window of its own, on a computer. Pops (returns) the
/// address it ends on once it starts with `redirect`, or, with `cookie`, the cookie
/// header for `domain` once that cookie is set. Null if the window was closed first.
Future<String?> _signInWindow({
  required String title,
  required String url,
  String? redirect,
  String? cookie,
  String domain = '',
}) async {
  final support = await getApplicationSupportDirectory();
  final Webview web;
  try {
    web = await WebviewWindow.create(
      configuration: CreateConfiguration(
        title: title,
        windowWidth: 520,
        windowHeight: 760,
        titleBar: const TitleBarOptions(showReload: false),
        windows: WindowsWebviewOptions(
          userDataFolder: '${support.path}/WebView2',
        ),
      ),
    );
  } on Object {
    throw _NoWindow();
  }
  final done = Completer<String?>();
  unawaited(
    web.onClose.then((_) {
      if (!done.isCompleted) done.complete(null);
    }),
  );
  if (redirect != null) {
    await web.setOnUrlRequestCallback((address) {
      if (!address.startsWith(redirect)) return true;
      if (!done.isCompleted) done.complete(address);
      return false;
    });
  } else {
    unawaited(() async {
      while (!done.isCompleted) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (done.isCompleted) break;
        try {
          bool ours(WebviewCookie c) => c.domain.endsWith(domain);
          final cookies = (await web.getAllCookies()).where(ours);
          if (!cookies.any((c) => c.name == cookie && c.value.isNotEmpty)) {
            continue;
          }
          // Let the page finish setting the rest of its cookies.
          await Future<void>.delayed(const Duration(seconds: 2));
          final seen = <String>{};
          final header = [
            for (final c in (await web.getAllCookies()).where(ours))
              if (seen.add(c.name)) '${c.name}=${c.value}',
          ].join('; ');
          if (!done.isCompleted) done.complete(header);
        } on Object {
          // The window is going away.
        }
      }
    }());
  }
  await web.launch(url);
  final result = await done.future;
  try {
    await web.close();
  } on Object {
    // Already closed.
  }
  return result;
}

/// Tidal's sign-in: in a web view on a phone; on a computer, in the browser (Tidal's bot
/// check blanks the page in an app's own web view there), then the address it ends on
/// copied back: Halcyn sees it on the clipboard.
Future<void> signInToTidal(BuildContext context) async {
  final streaming = AppScope.of(context).streaming;
  final String url;
  try {
    url = await streaming.tidalLoginUrl();
  } on Object catch (e) {
    if (context.mounted) _tell(context, streamingError(e));
    return;
  }
  if (!context.mounted) return;
  if (Platform.isAndroid) {
    final redirected = await Navigator.of(context, rootNavigator: true)
        .push<String>(
          MaterialPageRoute(
            builder: (_) => _SignInPage(
              title: 'Sign in to Tidal',
              url: url,
              done: (address) async =>
                  address.startsWith(streaming.tidalRedirect) ? address : null,
            ),
          ),
        );
    if (redirected == null || !context.mounted) return;
    await _finish(context, () => streaming.tidalFinishLogin(redirected));
    return;
  }
  await openInBrowser(url);
  if (!context.mounted) return;
  final pasted = await showDialog<String>(
    context: context,
    builder: (_) => _PasteDialog(
      title: 'Sign in to Tidal',
      explanation:
          'Tidal\'s sign-in page opened in your browser. Once you\'ve signed '
          'in, Tidal shows an "Oops" page: copy that page\'s address from the '
          'address bar and come back here. Halcyn finishes signing in.',
      label: 'Or paste the address here',
      action: 'Sign in',
      watch: streaming.tidalRedirect,
      reopen: () => openInBrowser(url),
    ),
  );
  if (pasted == null || pasted.trim().isEmpty || !context.mounted) return;
  await _finish(context, () => streaming.tidalFinishLogin(pasted));
}

/// YouTube Music's sign-in: Google's page in a web view on a phone, or in a window of
/// its own on a computer (without one: a browser's cookies, read by yt-dlp, or cookies
/// pasted in).
Future<void> signInToYouTube(BuildContext context) async {
  final streaming = AppScope.of(context).streaming;
  if (Platform.isAndroid) {
    final cookie = await Navigator.of(context, rootNavigator: true)
        .push<String>(
          MaterialPageRoute(
            builder: (_) => _SignInPage(
              title: 'Sign in to YouTube Music',
              url: _youtubeSignIn,
              done: (address) async {
                if (!address.startsWith('https://music.youtube.com')) {
                  return null;
                }
                final cookie = await _android.invokeMethod<String>('cookies', {
                  'url': 'https://music.youtube.com',
                });
                return cookie != null && cookie.contains('SAPISID')
                    ? cookie
                    : null;
              },
            ),
          ),
        );
    if (cookie == null || !context.mounted) return;
    await _finish(context, () => streaming.youtubeSignIn(cookie));
    return;
  }
  try {
    final cookie = await _signInWindow(
      title: 'Sign in to YouTube Music',
      url: _youtubeSignIn,
      cookie: '__Secure-3PAPISID',
      domain: 'youtube.com',
    );
    if (cookie == null || !context.mounted) return;
    await _finish(context, () => streaming.youtubeSignIn(cookie));
    return;
  } on _NoWindow {
    // A browser's cookies or pasted ones, then.
  }
  if (!context.mounted) return;
  final choice = await showDialog<(String, String)>(
    context: context,
    builder: (_) => const _YouTubeDialog(),
  );
  if (choice == null || !context.mounted) return;
  final (how, value) = choice;
  await _finish(
    context,
    () => how == 'browser'
        ? streaming.youtubeSignInFromBrowser(value)
        : streaming.youtubeSignIn(value),
  );
}

Future<void> _finish(BuildContext context, Future<void> Function() step) async {
  try {
    await step();
  } on Object catch (e) {
    if (!context.mounted) return;
    _tell(context, 'Couldn\'t sign in: ${streamingError(e)}');
  }
}

class _PasteDialog extends StatefulWidget {
  const _PasteDialog({
    required this.title,
    required this.explanation,
    required this.label,
    required this.action,
    this.watch,
    this.reopen,
  });

  final String title;
  final String explanation;
  final String label;
  final String action;

  /// Text starting with this, once copied, is taken as the answer.
  final String? watch;

  /// Opens the page again.
  final VoidCallback? reopen;

  @override
  State<_PasteDialog> createState() => _PasteDialogState();
}

class _PasteDialogState extends State<_PasteDialog> {
  final _text = TextEditingController();
  Timer? _clipboard;

  @override
  void initState() {
    super.initState();
    if (widget.watch case final prefix?) {
      var reading = false;
      _clipboard = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (reading) return;
        reading = true;
        final copied = (await _copied())?.trim();
        reading = false;
        if (copied == null || !copied.startsWith(prefix) || !mounted) return;
        _clipboard?.cancel();
        Navigator.of(context).pop(copied);
      });
    }
  }

  /// What's copied. Wayland only shows the app in front the clipboard, and the user
  /// copies in their browser, so ask wl-paste there.
  static Future<String?> _copied() async {
    if (Platform.isLinux && Platform.environment['WAYLAND_DISPLAY'] != null) {
      try {
        final pasted = await Process.run('wl-paste', [
          '--no-newline',
          '--type',
          'text',
        ]).timeout(const Duration(seconds: 2));
        if (pasted.exitCode == 0) return pasted.stdout as String;
      } on Object {
        // No wl-paste: the app's own clipboard, then.
      }
    }
    try {
      return (await Clipboard.getData(Clipboard.kTextPlain)
              .timeout(const Duration(seconds: 2)))
          ?.text;
    } on Object {
      return null;
    }
  }

  @override
  void dispose() {
    _clipboard?.cancel();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.explanation),
          const SizedBox(height: 16),
          TextField(
            controller: _text,
            autofocus: true,
            decoration: InputDecoration(labelText: widget.label),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
        ],
      ),
    ),
    actions: [
      if (widget.reopen case final reopen?)
        TextButton(onPressed: reopen, child: const Text('Open the page again')),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_text.text),
        child: Text(widget.action),
      ),
    ],
  );
}

/// On a computer: which browser's sign-in to use, or cookies to paste.
/// Pops ('browser', name) or ('cookie', header).
class _YouTubeDialog extends StatefulWidget {
  const _YouTubeDialog();

  @override
  State<_YouTubeDialog> createState() => _YouTubeDialogState();
}

class _YouTubeDialogState extends State<_YouTubeDialog> {
  static const _browsers = {
    'firefox': 'Firefox',
    'chrome': 'Chrome',
    'chromium': 'Chromium',
    'brave': 'Brave',
    'edge': 'Edge',
    'vivaldi': 'Vivaldi',
    'opera': 'Opera',
  };
  String _browser = Platform.isWindows ? 'edge' : 'firefox';
  final _cookie = TextEditingController();

  @override
  void dispose() {
    _cookie.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Sign in to YouTube Music'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Halcyn uses the sign-in of a browser where you\'re signed in to '
              'music.youtube.com (yt-dlp reads its cookies).',
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _browser,
                    decoration: const InputDecoration(labelText: 'Browser'),
                    items: [
                      for (final MapEntry(:key, :value) in _browsers.entries)
                        DropdownMenuItem(value: key, child: Text(value)),
                    ],
                    onChanged: (b) => setState(() => _browser = b ?? _browser),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(context).pop(('browser', _browser)),
                  child: const Text('Use it'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text('Or paste cookies', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'In the browser\'s developer tools (Network), copy the Cookie '
              'header of any request to music.youtube.com.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Palette.textMuted,
              ),
            ),
            TextField(
              controller: _cookie,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Cookie'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(('cookie', _cookie.text)),
          child: const Text('Use pasted cookies'),
        ),
      ],
    );
  }
}

/// A service's sign-in page on a phone. Pops with what `done` makes of the first page
/// it accepts.
class _SignInPage extends StatefulWidget {
  const _SignInPage({
    required this.title,
    required this.url,
    required this.done,
  });

  final String title;
  final String url;
  final Future<String?> Function(String address) done;

  @override
  State<_SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<_SignInPage> {
  late final WebViewController _web;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) async {
            final result = await _check(request.url);
            return result
                ? NavigationDecision.prevent
                : NavigationDecision.navigate;
          },
          onPageFinished: _check,
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  Future<bool> _check(String address) async {
    if (_finished) return true;
    final value = await widget.done(address);
    if (value == null || !mounted || _finished) return false;
    _finished = true;
    Navigator.of(context).pop(value);
    return true;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: WebViewWidget(controller: _web),
  );
}
