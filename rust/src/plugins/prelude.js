// Runs before each plugin. It turns the one host function, __send(call, method, json),
// into the `halcyn` API, and gives the host __resolve, __emit and __invoke to call back.
// Everything that needs the app returns a promise; the app may refuse (the promise
// rejects) when the plugin lacks the permission. Documented in docs/plugins.md.
(() => {
  const send = globalThis.__send;
  delete globalThis.__send;

  const pending = new Map();
  const handlers = new Map();
  const listeners = new Map();
  let nextCall = 1;
  let nextHandler = 1;

  const encode = (value) => JSON.stringify(value === undefined ? null : value);
  const describe = (e) => (e && e.stack ? `${e}\n${e.stack}` : String(e));
  const fire = (method, value) => send(0, method, encode(value));

  function call(method, value) {
    const id = nextCall++;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      send(id, method, encode(value));
    });
  }

  // Runs plugin code, reporting what it throws (now or later) instead of losing it.
  function guard(fn) {
    try {
      const result = fn();
      if (result && typeof result.then === 'function') {
        result.then(undefined, (e) => fire('error', describe(e)));
      }
    } catch (e) {
      fire('error', describe(e));
    }
  }

  function handler(fn, what) {
    if (typeof fn !== 'function') throw new TypeError(`${what} must be a function`);
    const id = nextHandler++;
    handlers.set(id, fn);
    return id;
  }

  // Functions inside returned values (a page's buttons) become handler ids.
  function plain(value) {
    if (typeof value === 'function') return { handler: handler(value, 'a callback') };
    if (Array.isArray(value)) return value.map(plain);
    if (value && typeof value === 'object') {
      const out = {};
      for (const [k, v] of Object.entries(value)) out[k] = plain(v);
      return out;
    }
    return value === undefined ? null : value;
  }

  globalThis.__resolve = (id, ok, json) => {
    const p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    const value = JSON.parse(json);
    if (ok) p.resolve(value);
    else p.reject(new Error(String(value)));
  };

  globalThis.__emit = (event, json) => {
    const value = JSON.parse(json);
    for (const fn of listeners.get(event) || []) guard(() => fn(value));
  };

  globalThis.__invoke = (id, json, reply) => {
    const fn = handlers.get(id);
    Promise.resolve()
      .then(() => {
        if (!fn) throw new Error('that handler is gone');
        return fn(JSON.parse(json));
      })
      .then(
        (value) => fire('__return', { reply, ok: true, value: plain(value) }),
        (e) => {
          fire('error', describe(e));
          fire('__return', { reply, ok: false, value: String(e) });
        },
      );
  };

  globalThis.setTimeout = (fn, ms = 0, ...args) => {
    const id = nextCall++;
    pending.set(id, { resolve: () => guard(() => fn(...args)), reject() {} });
    send(id, '__timer', String(Math.max(0, Number(ms) | 0)));
    return id;
  };
  globalThis.clearTimeout = (id) => void pending.delete(id);

  const log = (level) => (...parts) =>
    fire(level, parts.map((p) => (typeof p === 'string' ? p : encode(p))).join(' '));
  globalThis.console = { log: log('log'), info: log('log'), warn: log('log'), error: log('error') };

  const paths = (tracks) =>
    (Array.isArray(tracks) ? tracks : [tracks]).map((t) => (typeof t === 'string' ? t : t.path));
  const fn = (f, what) => handler(f, what);

  globalThis.halcyn = Object.freeze({
    /** { version, platform }: platform is "linux", "windows" or "android". */
    app: Object.freeze({
      info: () => call('app.info'),
    }),

    /** Needs "library". */
    library: Object.freeze({
      tracks: () => call('library.tracks'),
      search: (query) => call('library.search', { query: String(query) }),
      albums: () => call('library.albums'),
      artists: () => call('library.artists'),
      rescan: () => call('library.rescan'),
    }),

    /** Needs "library". */
    playlists: Object.freeze({
      list: () => call('playlists.list'),
      create: (name, tracks = []) =>
        call('playlists.create', { name: String(name), paths: paths(tracks) }),
      add: (id, tracks) => call('playlists.add', { id, paths: paths(tracks) }),
      removeAt: (id, index) => call('playlists.removeAt', { id, index }),
      rename: (id, name) => call('playlists.rename', { id, name: String(name) }),
      delete: (id) => call('playlists.delete', { id }),
    }),

    /** Needs "player". Tracks can be given as track objects or their paths. */
    player: Object.freeze({
      current: () => call('player.current'),
      play: (tracks, start = 0) => call('player.play', { paths: paths(tracks), start }),
      playNext: (tracks) => call('player.playNext', { paths: paths(tracks) }),
      enqueue: (tracks) => call('player.enqueue', { paths: paths(tracks) }),
      pause: () => call('player.pause'),
      resume: () => call('player.resume'),
      next: () => call('player.next'),
      previous: () => call('player.previous'),
      /** { tracks, index, shuffle, repeat, playing } */
      queue: () => call('player.queue'),
      jumpTo: (index) => call('player.jumpTo', { index }),
      removeAt: (index) => call('player.removeAt', { index }),
      move: (from, to) => call('player.move', { from, to }),
      seek: (seconds) => call('player.seek', { seconds: Number(seconds) }),
      position: () => call('player.position'),
      setShuffle: (on) => call('player.setShuffle', { on: !!on }),
      /** "off", "all" or "one". */
      setRepeat: (mode) => call('player.setRepeat', { mode: String(mode) }),
      /** 0 to 1. */
      volume: () => call('player.volume'),
      setVolume: (value) => call('player.setVolume', { value: Number(value) }),
    }),

    /** Change what happens. Needs "player". */
    hooks: Object.freeze({
      /**
       * Runs before anything starts playing from the app (not from plugins). Gets
       * { tracks, start }; return nothing to leave it, { tracks, start } to play
       * something else, or false to play nothing.
       */
      beforePlay: (f) => call('hooks.beforePlay', { handler: fn(f, 'the hook') }),
    }),

    ui: Object.freeze({
      /**
       * A tab. where: "sidebar" (the default: the sidebar's Plugins section, and the
       * Library row on a phone), "library" (beside Songs, Albums, …) or "main" (the
       * top of the sidebar, and the phone's bottom bar).
       */
      addTab: ({ title, icon, render, where = 'sidebar' }) =>
        call('ui.addTab', { title: String(title), icon, handler: fn(render, 'render'), where }),
      addPage: ({ title, icon, render }) =>
        call('ui.addTab', { title: String(title), icon, handler: fn(render, 'render'), where: 'sidebar' }),
      /** Needs "interface". Shows your page instead of a built-in one (see the docs). */
      replace: (target, { render, title } = {}) =>
        call('ui.replace', { target: String(target), title, handler: fn(render, 'render') }),
      /** Needs "interface". Hides built-in tabs, e.g. ["albums", "smartPlaylists"]. */
      hide: (targets) => call('ui.hide', { targets: [].concat(targets).map(String) }),
      show: (targets) => call('ui.show', { targets: [].concat(targets).map(String) }),
      /** A button in the player bar and Now Playing. */
      addPlayerButton: ({ title, icon, run }) =>
        call('ui.addPlayerButton', { title: String(title), icon, handler: fn(run, 'run') }),
      /** A button on the plugin's card in Manage plugins. */
      addCommand: ({ title, icon, run }) =>
        call('ui.addCommand', { title: String(title), icon, handler: fn(run, 'run') }),
      /** An entry in every song's menu; `run` gets the track. */
      addTrackAction: ({ title, icon, run }) =>
        call('ui.addTrackAction', { title: String(title), icon, handler: fn(run, 'run') }),
      /** A section in Settings, rendered like a page. */
      addSettings: ({ title, render }) =>
        call('ui.addSettings', { title, handler: fn(render, 'render') }),
      /** Needs "interface". A theme in the theme picker (the same JSON as Halcyn's). */
      addTheme: (theme) => call('ui.addTheme', { theme }),
      /** Needs "interface". e.g. "ctrl+shift+k" (desktop). */
      addShortcut: ({ keys, run }) =>
        call('ui.addShortcut', { keys: String(keys), handler: fn(run, 'run') }),
      /** Opens a built-in place ("songs", "albums", "artists", "queue", "playlists",
       *  "settings", "plugins") or a tab by the id addTab resolved to. */
      navigate: (target) => call('ui.navigate', { target: String(target) }),
      /** A dialog rendered like a page; resolves when it closes. */
      dialog: ({ title, render }) =>
        call('ui.dialog', { title: title === undefined ? null : String(title), handler: fn(render, 'render') }),
      closeDialog: () => call('ui.closeDialog'),
      /** Renders the plugin's pages again. */
      refresh: () => call('ui.refresh'),
      notify: (text) => call('ui.notify', { text: String(text) }),
    }),

    /** The plugin's own saved values (JSON), kept between runs. */
    storage: Object.freeze({
      get: (key) => call('storage.get', { key: String(key) }),
      set: (key, value) => call('storage.set', { key: String(key), value: value === undefined ? null : value }),
    }),

    /** Needs "files". Paths are absolute. */
    files: Object.freeze({
      read: (path) => call('files.read', { path: String(path) }),
      write: (path, text) => call('files.write', { path: String(path), text: String(text) }),
      list: (path) => call('files.list', { path: String(path) }),
      exists: (path) => call('files.exists', { path: String(path) }),
      delete: (path) => call('files.delete', { path: String(path) }),
    }),

    /** Needs "network". Resolves to { status, body, contentType }. */
    http: Object.freeze({
      get: (url, options = {}) =>
        call('http.get', { url: String(url), headers: options.headers || {} }),
      post: (url, body, options = {}) =>
        call('http.post', {
          url: String(url),
          body: typeof body === 'string' ? body : encode(body),
          headers: options.headers || {},
        }),
    }),

    /**
     * Events (need "player", except libraryChanged which needs "library"):
     * trackChanged (the track or null), playState ({ playing }), queueChanged
     * ({ tracks, index }), position ({ seconds }, about once a second while playing),
     * libraryChanged.
     */
    on(event, f) {
      fn(f, 'the listener');
      if (!listeners.has(event)) listeners.set(event, []);
      listeners.get(event).push(f);
      fire('on', { event: String(event) });
    },
  });
})();
