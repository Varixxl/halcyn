import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/plugins.dart';
import '../theme.dart';
import 'albums_page.dart';
import 'artists_page.dart';
import 'downloads.dart';
import 'places.dart';
import 'equalizer.dart';
import 'now_playing.dart';
import 'phone_dock.dart';
import 'player_bar.dart';
import 'plugin_view.dart';
import 'playlists_page.dart';
import 'plugins_page.dart';
import 'queue_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'sidebar.dart';
import 'streaming.dart';
import 'slate.dart';
import 'songs_page.dart';
import 'track_list.dart';
import 'widgets.dart';

/// Buttons in the phone's dock, "Everywhere" included; plugins' main tabs fill what's
/// left after the built-in ones.
const _dockButtons = 5;

/// The page area's navigator, for opening an artist or album from anywhere.
final contentPages = GlobalKey<NavigatorState>();

/// The sidebar (or, on a phone, the tabs), the page area with its own navigator so
/// album and artist pages open inside it, and the docked player.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final _pages = contentPages;

  /// Filters the page shown (top right).
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  /// Searches everything (the sidebar, or the phone's Search tab).
  final _global = TextEditingController();
  final _globalFocus = FocusNode();
  final _globalQuery = ValueNotifier('');
  // The page navigator builds its first page once, so the pages listen to these.
  final _section = ValueNotifier(const Section(Place.songs));
  final _query = ValueNotifier('');

  /// The last smart or user playlist shown, kept while another page fades in.
  Section _collection = const Section(Place.hiRes);

  /// Phone layout: the Search tab is open.
  bool _searching = false;

  StreamSubscription<String>? _navigation;
  PluginManager? _plugins;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final plugins = AppScope.of(context).plugins;
    if (plugins != _plugins) {
      _plugins?.removeListener(_pluginsChanged);
      _navigation?.cancel();
      _plugins = plugins..addListener(_pluginsChanged);
      _navigation = plugins.navigation.stream.listen(_navigate);
    }
  }

  /// Plugins add tabs and hide or replace built-in ones.
  void _pluginsChanged() => setState(() {});

  /// Where a plugin asked to go (`halcyn.ui.navigate`).
  void _navigate(String target) {
    if (!mounted) return;
    if (int.tryParse(target) case final key?) {
      return _select(Section(Place.pluginPage, key));
    }
    if (target == 'nowPlaying') return openNowPlaying(context);
    final place = switch (target) {
      'home' => Place.home,
      'songs' => Place.songs,
      'albums' => Place.albums,
      'artists' => Place.artists,
      'queue' => Place.queue,
      'playlists' => Place.playlists,
      'search' => Place.search,
      'settings' => Place.settings,
      'plugins' => Place.plugins,
      _ => null,
    };
    if (place != null) _select(Section(place));
  }

  @override
  void dispose() {
    _navigation?.cancel();
    _plugins?.removeListener(_pluginsChanged);
    _search.dispose();
    _searchFocus.dispose();
    _global.dispose();
    _globalFocus.dispose();
    _globalQuery.dispose();
    _section.dispose();
    _query.dispose();
    super.dispose();
  }

  void _select(Section section, {bool searching = false}) {
    _pages.currentState?.popUntil((route) => route.isFirst);
    setState(() {
      _searching = searching;
      if (section.place.smart || section.place == Place.playlist) {
        _collection = section;
      }
      _section.value = section;
    });
  }

  void _setQuery(String query) => setState(() => _query.value = query.trim());

  void _setGlobal(String query) {
    _globalQuery.value = query.trim();
    if (_globalQuery.value.isNotEmpty && _section.value.place != Place.search) {
      _select(const Section(Place.search), searching: _searching);
    } else {
      setState(() {});
    }
  }

  /// Ctrl+F, or the phone's Search tab: the search across everything.
  void _focusGlobal({required bool phone}) {
    if (phone || _global.text.trim().isNotEmpty) {
      _select(const Section(Place.search), searching: phone);
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _globalFocus.requestFocus(),
    );
  }

  Future<void> _createPlaylist() async {
    final playlists = AppScope.of(context).playlists;
    final name = await askName(
      context,
      title: 'New playlist',
      action: 'Create',
    );
    if (name == null) return;
    final playlist = await playlists.create(name);
    _select(Section(Place.playlist, playlist.id));
  }

  bool get _searchable => switch (_section.value.place) {
    Place.home ||
    Place.queue ||
    Place.settings ||
    Place.playlists ||
    Place.search ||
    Place.plugins ||
    Place.pluginPage => false,
    _ => true,
  };

  static int _stackIndex(Place place) => switch (place) {
    Place.songs => 0,
    Place.albums => 1,
    Place.artists => 2,
    Place.queue => 3,
    Place.settings => 4,
    Place.playlists => 5,
    Place.search => 7,
    Place.plugins => 8,
    Place.pluginPage => 9,
    Place.home => 10,
    _ => 6,
  };

  /// A built-in page, or what a plugin shows instead of it.
  Widget _builtIn(PluginManager plugins, String tab, Widget page) =>
      switch (plugins.replacement(tab)) {
        final r? => PluginPageView(
          key: ValueKey('$tab ${r.key}'),
          pageKey: r.key,
        ),
        null => page,
      };

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final plugins = AppScope.of(context).plugins;

    final pages = Navigator(
      key: _pages,
      observers: [HeroController()],
      onGenerateRoute: (_) => PageRouteBuilder(
        pageBuilder: (_, _, _) => ListenableBuilder(
          listenable: Listenable.merge([
            _section,
            _query,
            _globalQuery,
            plugins,
          ]),
          builder: (context, _) => FadeIndexedStack(
            index: _stackIndex(_section.value.place),
            children: [
              _builtIn(plugins, 'songs', SongsPage(query: _query.value)),
              _builtIn(plugins, 'albums', AlbumsPage(query: _query.value)),
              _builtIn(plugins, 'artists', ArtistsPage(query: _query.value)),
              _builtIn(plugins, 'queue', const QueuePage()),
              const SettingsPage(),
              _builtIn(
                plugins,
                'playlists',
                PlaylistsPage(onOpen: _select, onCreate: _createPlaylist),
              ),
              _builtIn(
                plugins,
                _collection.place.smart ? 'smartPlaylists' : 'playlists',
                AnimatedSwitcher(
                  duration: SlateMotion.page,
                  switchInCurve: Motion.curve,
                  switchOutCurve: Motion.curve,
                  child: CollectionPage(
                    key: ValueKey(_collection),
                    section: _collection,
                    query: _query.value,
                    onDeleted: () => _select(const Section(Place.songs)),
                  ),
                ),
              ),
              _builtIn(
                plugins,
                'search',
                SearchPage(query: _globalQuery.value, onOpen: _select),
              ),
              const PluginsPage(),
              PluginPageView(
                key: ValueKey(_section.value.playlist),
                pageKey: _section.value.playlist ?? 0,
              ),
              const HomePage(),
            ],
          ),
        ),
      ),
    );

    final content = Padding(
      padding: EdgeInsets.fromLTRB(wide ? 16 : 8, 0, wide ? 16 : 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          wide ? _topBar(context) : _phoneTopBar(context),
          const _MusicAccessBanner(),
          Expanded(child: pages),
        ],
      ),
    );

    return Shortcuts(
      // The player's own shortcuts live in WindowFrame, above the mini player too.
      shortcuts: {
        if (!plugins.isHidden('search'))
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              const _Search(),
      },
      child: Actions(
        actions: {
          _Search: CallbackAction<_Search>(
            onInvoke: (_) {
              _focusGlobal(phone: !wide);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          // Android's bars are see-through, over the dock and the background.
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value:
                (Palette.theme.dark
                        ? SystemUiOverlayStyle.light
                        : SystemUiOverlayStyle.dark)
                    .copyWith(
                      statusBarColor: Colors.transparent,
                      systemNavigationBarColor: Colors.transparent,
                      systemNavigationBarDividerColor: Colors.transparent,
                      systemNavigationBarContrastEnforced: false,
                    ),
            child: Scaffold(
              body: SafeArea(
                bottom: false,
                child: wide
                    ? Column(
                        children: [
                          Expanded(
                            child: Stack(
                              children: [
                                Row(
                                  children: [
                                    Sidebar(
                                      section: _section.value,
                                      onSelect: _select,
                                      search: plugins.isHidden('search')
                                          ? null
                                          : _searchField(global: true),
                                    ),
                                    Expanded(
                                      child: NowPlayingCardInset(
                                        child: content,
                                      ),
                                    ),
                                  ],
                                ),
                                const Positioned(
                                  right: 16,
                                  bottom: 12,
                                  child: NowPlayingCard(),
                                ),
                              ],
                            ),
                          ),
                          const DownloadsBar(),
                          PlayerBar(
                            onQueue: () => _select(const Section(Place.queue)),
                          ),
                        ],
                      )
                    : Column(
                        children: [
                          Expanded(child: content),
                          const DownloadsBar(),
                          ListenableBuilder(
                            listenable: Listenable.merge([
                              plugins,
                              AppScope.of(context).streaming,
                            ]),
                            builder: (context, _) => PhoneDock(
                              tabs: _phoneTabs(plugins),
                              everywhere: (
                                icon: Icons.apps_rounded,
                                selected: Icons.apps_rounded,
                                label: 'More',
                                open: () => showEverywhere(
                                  context,
                                  groups: _everywhere(plugins),
                                ),
                                shown: () => false,
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The phone's dock: Home (with a streaming service linked), Library, Search,
  /// Playlists, and plugins' main tabs while there's room; "More" has the rest.
  List<DockTab> _phoneTabs(PluginManager plugins) {
    final place = _section.value.place;
    final library = _libraryPlaces(plugins);
    final libraryTabs = [
      ...plugins.tabs(TabPlace.library),
      ...plugins.tabs(TabPlace.sidebar),
    ];
    final playlists =
        !plugins.isHidden('playlists') || !plugins.isHidden('smartPlaylists');
    final tabs = <DockTab>[
      if (AppScope.of(context).streaming.linked)
        (
          icon: Icons.home_outlined,
          selected: Icons.home_rounded,
          label: 'Home',
          open: () => _select(const Section(Place.home)),
          shown: () => place == Place.home,
        ),
      (
        icon: Icons.library_music_outlined,
        selected: Icons.library_music_rounded,
        label: 'Library',
        open: () => _select(Section(library.firstOrNull ?? Place.songs)),
        shown: () =>
            !_searching &&
            (library.contains(place) ||
                (place == Place.pluginPage &&
                    libraryTabs.any((t) => t.key == _section.value.playlist))),
      ),
      if (!plugins.isHidden('search'))
        (
          icon: Icons.search_rounded,
          selected: Icons.saved_search_rounded,
          label: 'Search',
          open: () => _focusGlobal(phone: true),
          shown: () => place == Place.search || _searching,
        ),
      if (playlists)
        (
          icon: Icons.queue_music_outlined,
          selected: Icons.queue_music_rounded,
          label: 'Playlists',
          open: () => _select(const Section(Place.playlists)),
          shown: () =>
              place == Place.playlists ||
              place == Place.playlist ||
              place.smart,
        ),
    ];
    final room = _dockButtons - 1 - tabs.length;
    return [
      ...tabs,
      for (final t in plugins.tabs(TabPlace.main).take(room.clamp(0, 9)))
        _pluginTab(t),
    ];
  }

  /// Songs, Albums, Artists and Queue, less those a plugin hides.
  List<Place> _libraryPlaces(PluginManager plugins) => [
    for (final (tab, p) in [
      ('songs', Place.songs),
      ('albums', Place.albums),
      ('artists', Place.artists),
      ('queue', Place.queue),
    ])
      if (!plugins.isHidden(tab)) p,
  ];

  /// The phone's "More" sheet: every page there is, grouped.
  List<(String, List<DockTab>)> _everywhere(PluginManager plugins) {
    final scope = AppScope.of(context);
    final section = _section.value;
    DockTab to(Section s, IconData icon, IconData selected, String label) => (
      icon: icon,
      selected: selected,
      label: label,
      open: () => _select(s),
      shown: () => !_searching && _section.value == s,
    );
    final loaded = scope.player.current != null;
    return [
      (
        'Library',
        [
          for (final p in _libraryPlaces(plugins))
            to(
              Section(p),
              switch (p) {
                Place.songs => Icons.music_note_outlined,
                Place.albums => Icons.album_outlined,
                Place.artists => Icons.person_outline_rounded,
                _ => Icons.format_list_numbered_rounded,
              },
              switch (p) {
                Place.songs => Icons.music_note_rounded,
                Place.albums => Icons.album_rounded,
                Place.artists => Icons.person_rounded,
                _ => Icons.format_list_numbered_rounded,
              },
              plugins.replacement(p.name)?.title ??
                  switch (p) {
                    Place.songs => 'Songs',
                    Place.albums => 'Albums',
                    Place.artists => 'Artists',
                    _ => 'Queue',
                  },
            ),
          for (final t in [
            ...plugins.tabs(TabPlace.library),
            ...plugins.tabs(TabPlace.sidebar),
          ])
            _pluginTab(t),
        ],
      ),
      (
        'Halcyn',
        [
          if (loaded) ...[
            (
              icon: Icons.graphic_eq_rounded,
              selected: Icons.graphic_eq_rounded,
              label: 'Playing',
              open: () => openNowPlaying(context),
              shown: () => false,
            ),
            (
              icon: Icons.lyrics_outlined,
              selected: Icons.lyrics_rounded,
              label: 'Lyrics',
              open: () =>
                  openNowPlaying(context, panel: NowPlayingPanel.lyrics),
              shown: () => false,
            ),
          ],
          if (!scope.player.casting)
            (
              icon: Icons.tune_rounded,
              selected: Icons.tune_rounded,
              label: 'Sound',
              open: () => openSound(context),
              shown: () => false,
            ),
          to(
            const Section(Place.plugins),
            Icons.extension_outlined,
            Icons.extension_rounded,
            'Plugins',
          ),
          to(
            const Section(Place.settings),
            Icons.settings_outlined,
            Icons.settings_rounded,
            'Settings',
          ),
        ],
      ),
      (
        'Pages',
        [
          if (scope.streaming.linked)
            to(
              const Section(Place.home),
              Icons.home_outlined,
              Icons.home_rounded,
              'Home',
            ),
          if (!plugins.isHidden('search'))
            (
              icon: Icons.search_rounded,
              selected: Icons.saved_search_rounded,
              label: 'Search',
              open: () => _focusGlobal(phone: true),
              shown: () => section.place == Place.search || _searching,
            ),
          for (final t in plugins.tabs(TabPlace.main)) _pluginTab(t),
        ],
      ),
      (
        'Playlists',
        [
          if (!plugins.isHidden('playlists'))
            to(
              const Section(Place.playlists),
              Icons.queue_music_outlined,
              Icons.queue_music_rounded,
              'All playlists',
            ),
          if (!plugins.isHidden('smartPlaylists'))
            for (final s in SmartList.all)
              to(Section(s.place), s.icon, s.icon, s.name),
        ],
      ),
    ];
  }

  DockTab _pluginTab(PluginPage t) => (
    icon: pluginIcon(t.icon),
    selected: pluginIcon(t.icon),
    label: t.title,
    open: () => _select(Section(Place.pluginPage, t.key)),
    shown: () =>
        _section.value.place == Place.pluginPage &&
        _section.value.playlist == t.key,
  );

  /// Desktop: the page's name on the left, search on the right.
  Widget _topBar(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.library, scope.plugins]),
      builder: (context, _) => _buildTopBar(context),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final library = AppScope.of(context).library;
    final place = _section.value.place;
    final plugins = AppScope.of(context).plugins;
    final replaced = switch (place) {
      Place.songs => plugins.replacement('songs'),
      Place.albums => plugins.replacement('albums'),
      Place.artists => plugins.replacement('artists'),
      Place.queue => plugins.replacement('queue'),
      Place.search => plugins.replacement('search'),
      _ => null,
    };
    final (title, count) = switch (place) {
      _ when replaced != null => (replaced.title, null),
      Place.songs => ('Songs', library.tracks.length),
      Place.albums => ('Albums', library.albums.length),
      Place.artists => ('Artists', library.artists.length),
      Place.home => ('Home', null),
      Place.queue => ('Queue', null),
      Place.settings => ('Settings', null),
      Place.search => ('Search', null),
      Place.plugins => ('Plugins', null),
      Place.pluginPage => (
        plugins.page(_section.value.playlist ?? 0)?.title ?? '',
        null,
      ),
      _ => ('', null),
    };
    return SizedBox(
      height: 68,
      child: Row(
        children: [
          const SizedBox(width: 8),
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          if (count != null) ...[
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '$count',
                style: TextStyle(fontSize: 14, color: Palette.textMuted),
              ),
            ),
          ],
          const Spacer(),
          if (_searchable && replaced == null)
            SizedBox(width: 280, child: _searchField()),
        ],
      ),
    );
  }

  /// Phone: the Library tab's sections, the search box, or a way back from a playlist.
  Widget _phoneTopBar(BuildContext context) {
    final place = _section.value.place;
    if (_searching) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 12),
        child: _searchField(global: true),
      );
    }
    if (place.smart || place == Place.playlist) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: TextButton.icon(
            onPressed: () => _select(const Section(Place.playlists)),
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            label: const Text('Playlists'),
          ),
        ),
      );
    }
    final plugins = AppScope.of(context).plugins;
    final page = place == Place.pluginPage
        ? plugins.page(_section.value.playlist ?? 0)
        : null;
    if (place == Place.settings ||
        place == Place.playlists ||
        place == Place.home ||
        page?.place == TabPlace.main) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        child: Text(
          page?.title ??
              switch (place) {
                Place.settings => 'Settings',
                Place.home => 'Home',
                _ => 'Playlists',
              },
          style: Theme.of(context).textTheme.headlineSmall,
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 12),
      child: Row(
        children: [
          for (final (tab, p, label) in [
            ('songs', Place.songs, 'Songs'),
            ('albums', Place.albums, 'Albums'),
            ('artists', Place.artists, 'Artists'),
            ('queue', Place.queue, 'Queue'),
          ])
            if (!plugins.isHidden(tab)) ...[
              Pill(
                label: plugins.replacement(tab)?.title ?? label,
                selected: place == p,
                onPressed: () => _select(Section(p)),
              ),
              const SizedBox(width: 8),
            ],
          for (final t in [
            ...plugins.tabs(TabPlace.library),
            ...plugins.tabs(TabPlace.sidebar),
          ]) ...[
            pluginTabPill(
              t,
              selected: page?.key == t.key,
              onPressed: () => _select(Section(Place.pluginPage, t.key)),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  /// The page's own filter, or (`global`) the search across everything.
  Widget _searchField({bool global = false}) {
    final controller = global ? _global : _search;
    final query = global ? _globalQuery.value : _query.value;
    final onChanged = global ? _setGlobal : _setQuery;
    return TextField(
      controller: controller,
      focusNode: global ? _globalFocus : _searchFocus,
      onChanged: onChanged,
      onSubmitted: global ? (_) => _setGlobal(_global.text) : null,
      decoration: InputDecoration(
        hintText: global ? 'Search all' : 'Search this page',
        isDense: global,
        fillColor: Palette.surface,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Palette.r(16)),
          borderSide: BorderSide(color: Palette.outline),
        ),
        prefixIcon: const Icon(Icons.search_rounded, size: 18),
        suffixIcon: query.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: 'Clear',
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
      ),
    );
  }
}

/// Android, until allowed: why Halcyn needs the music folder, and a button to allow it.
class _MusicAccessBanner extends StatelessWidget {
  const _MusicAccessBanner();

  @override
  Widget build(BuildContext context) {
    final access = AppScope.of(context).access;
    return ListenableBuilder(
      listenable: access,
      builder: (context, _) => AnimatedSize(
        duration: Motion.medium,
        curve: Motion.curve,
        child: access.granted
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Material(
                  color: Palette.surfaceHigh,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Palette.r(16)),
                    side: BorderSide(color: Palette.outline),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Let Halcyn read your music',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Halcyn plays the songs in your Music folder, and the '
                          '.lrc lyrics beside them. Android asks for "All files '
                          'access" for that.',
                          style: TextStyle(color: Palette.textMuted),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: access.ask,
                          child: const Text('Allow access'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _Search extends Intent {
  const _Search();
}
