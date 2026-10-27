import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'albums_page.dart';
import 'artists_page.dart';
import 'places.dart';
import 'player_bar.dart';
import 'playlists_page.dart';
import 'queue_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'sidebar.dart';
import 'slate.dart';
import 'songs_page.dart';
import 'track_list.dart';
import 'widgets.dart';

/// The phone layout's tabs.
const _tabs = [
  (
    icon: Icons.library_music_outlined,
    selected: Icons.library_music_rounded,
    label: 'Library',
  ),
  (icon: Icons.search_rounded, selected: Icons.search_rounded, label: 'Search'),
  (
    icon: Icons.queue_music_outlined,
    selected: Icons.queue_music_rounded,
    label: 'Playlists',
  ),
  (
    icon: Icons.settings_outlined,
    selected: Icons.settings_rounded,
    label: 'Settings',
  ),
];

/// The sidebar (or, on a phone, the tabs), the page area with its own navigator so
/// album and artist pages open inside it, and the docked player.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final _pages = GlobalKey<NavigatorState>();

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

  @override
  void dispose() {
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
    Place.queue || Place.settings || Place.playlists || Place.search => false,
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
    _ => 6,
  };

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;

    final pages = Navigator(
      key: _pages,
      observers: [HeroController()],
      onGenerateRoute: (_) => PageRouteBuilder(
        pageBuilder: (_, _, _) => ListenableBuilder(
          listenable: Listenable.merge([_section, _query, _globalQuery]),
          builder: (context, _) => FadeIndexedStack(
            index: _stackIndex(_section.value.place),
            children: [
              SongsPage(query: _query.value),
              AlbumsPage(query: _query.value),
              ArtistsPage(query: _query.value),
              const QueuePage(),
              const SettingsPage(),
              PlaylistsPage(onOpen: _select, onCreate: _createPlaylist),
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
              SearchPage(query: _globalQuery.value, onOpen: _select),
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
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyF, control: true): _Search(),
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
                                    search: _searchField(global: true),
                                  ),
                                  Expanded(
                                    child: NowPlayingCardInset(child: content),
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
                        PlayerBar(
                          onQueue: () => _select(const Section(Place.queue)),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        Expanded(child: content),
                        const MiniPlayer(),
                      ],
                    ),
            ),
            bottomNavigationBar: wide
                ? null
                : NavigationBar(
                    selectedIndex: _tab,
                    onDestinationSelected: _selectTab,
                    destinations: [
                      for (final t in _tabs)
                        NavigationDestination(
                          icon: Icon(t.icon),
                          selectedIcon: Icon(t.selected),
                          label: t.label,
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  int get _tab => switch (_section.value.place) {
    Place.settings => 3,
    Place.search => 1,
    Place.playlists || Place.playlist => 2,
    final p when p.smart => 2,
    _ => _searching ? 1 : 0,
  };

  void _selectTab(int tab) {
    switch (tab) {
      case 0:
        _select(const Section(Place.songs));
      case 1:
        _focusGlobal(phone: true);
      case 2:
        _select(const Section(Place.playlists));
      case 3:
        _select(const Section(Place.settings));
    }
  }

  /// Desktop: the page's name on the left, search on the right.
  Widget _topBar(BuildContext context) {
    final library = AppScope.of(context).library;
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) => _buildTopBar(context),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final library = AppScope.of(context).library;
    final place = _section.value.place;
    final (title, count) = switch (place) {
      Place.songs => ('Songs', library.tracks.length),
      Place.albums => ('Albums', library.albums.length),
      Place.artists => ('Artists', library.artists.length),
      Place.queue => ('Queue', null),
      Place.settings => ('Settings', null),
      Place.search => ('Search', null),
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
          if (_searchable) SizedBox(width: 280, child: _searchField()),
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
    if (place == Place.settings || place == Place.playlists) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        child: Text(
          place == Place.settings ? 'Settings' : 'Playlists',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 12),
      child: Row(
        children: [
          for (final (p, label) in [
            (Place.songs, 'Songs'),
            (Place.albums, 'Albums'),
            (Place.artists, 'Artists'),
            (Place.queue, 'Queue'),
          ]) ...[
            Pill(
              label: label,
              selected: place == p,
              onPressed: () => _select(Section(p)),
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
