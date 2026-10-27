# Writing Halcyn plugins

A plugin is one JavaScript file. Halcyn runs it in its own sandbox (QuickJS), and
everything it does goes through the `halcyn` object below: it can add tabs, buttons,
settings, themes and shortcuts, hide or replace Halcyn's own pages, control playback,
edit playlists, change what plays, read and write files and use the internet, each
behind a permission the user grants when installing it.

Install one from **Manage plugins** (the sidebar on desktop, Settings on a phone) with
**Install from file** or **Install from link**. Before installing, Halcyn shows its name,
author, the platforms it's for and the permissions it asks for. Three examples live in
[`plugins/examples`](../plugins/examples).

## The info block

The file must start with this block. `id`, `name`, `version` and `platforms` are
required; the id is lowercase letters, digits, dots and dashes (a reversed domain works
well). Installing a file with an id that's already installed updates that plugin.

```js
/* halcyn-plugin
{
  "id": "dev.example.hello",
  "name": "Hello",
  "version": "1.0.0",
  "platforms": ["linux", "windows", "android"],
  "halcyn": "0.2.0",
  "author": "You",
  "description": "One line about what it does.",
  "permissions": ["library", "player"]
}
*/
```

- `platforms`: where it works, any of `linux`, `windows`, `android`. Halcyn won't
  install it anywhere else, and won't start it there if it's copied over.
- `halcyn`: the oldest Halcyn it works with. Older versions refuse it. The API below is
  Halcyn 0.2.0's.

## Permissions

| Permission  | Lets the plugin                                                          |
|-------------|--------------------------------------------------------------------------|
| `library`   | `halcyn.library.*`, `halcyn.playlists.*` and the `libraryChanged` event  |
| `player`    | `halcyn.player.*`, `halcyn.hooks.*` and the playback events               |
| `interface` | hide or replace Halcyn's own tabs, add themes and keyboard shortcuts      |
| `files`     | `halcyn.files.*`: any file Halcyn can reach                               |
| `network`   | `halcyn.http.*`: any website                                              |

Its own tabs, buttons, song-menu entries, Settings sections, dialogs, notices and saved
values need no permission. A call the plugin has no permission for rejects with a
message saying which one is missing.

## The API

Everything that asks the app something returns a promise. Tracks can be given as track
objects or their paths.

```js
await halcyn.app.info()                 // { version, platform }

// Library ("library")
await halcyn.library.tracks()           // every track
await halcyn.library.search('blur')     // title, artist or album match, up to 500
await halcyn.library.albums()           // [{ title, artist, year, art, paths }]
await halcyn.library.artists()          // [{ name, art, albums, paths }]
await halcyn.library.rescan()

// Playlists ("library")
await halcyn.playlists.list()           // [{ id, name, paths, file }]; file: the playlist file it's read from
await halcyn.playlists.create(name, tracks = [])   // its id
await halcyn.playlists.add(id, tracks)
await halcyn.playlists.removeAt(id, index)
await halcyn.playlists.rename(id, name)
await halcyn.playlists.delete(id)

// Player ("player")
await halcyn.player.current()           // the track, or null
await halcyn.player.play(tracks, start = 0)
await halcyn.player.playNext(tracks)
await halcyn.player.enqueue(tracks)
await halcyn.player.pause() / resume() / next() / previous()
await halcyn.player.queue()             // { tracks, index, shuffle, repeat, playing }
await halcyn.player.jumpTo(index) / removeAt(index) / move(from, to)
await halcyn.player.seek(seconds)
await halcyn.player.position()          // seconds
await halcyn.player.setShuffle(true)
await halcyn.player.setRepeat('off' | 'all' | 'one')
await halcyn.player.volume()            // 0 to 1
await halcyn.player.setVolume(0.5)

// Change what plays ("player")
halcyn.hooks.beforePlay(({ tracks, start }) => {
  // Runs when the user starts something (not for the plugin's own player.play).
  // Return nothing to leave it, { tracks, start } to play something else, or false
  // to play nothing. It has 3 seconds.
});

// Events
halcyn.on('trackChanged', (track) => { /* track or null */ })      // "player"
halcyn.on('playState', ({ playing }) => { })                       // "player"
halcyn.on('queueChanged', ({ tracks, index, shuffle, repeat }) => { })  // "player"
halcyn.on('position', ({ seconds }) => { })   // about once a second; "player"
halcyn.on('libraryChanged', () => { })        // "library"

// Interface
const id = await halcyn.ui.addTab({ title, icon, render, where })  // see Tabs
await halcyn.ui.addPlayerButton({ title, icon, run })  // the player bar and Now Playing
await halcyn.ui.addCommand({ title, icon, run })       // a button on its card
await halcyn.ui.addTrackAction({ title, icon, run })   // every song's menu; run(track)
await halcyn.ui.addSettings({ title, render })         // a section in Settings
await halcyn.ui.dialog({ title, render })              // resolves when it closes
await halcyn.ui.closeDialog()
await halcyn.ui.navigate('albums')     // a built-in place, 'nowPlaying', or a tab's id
await halcyn.ui.refresh()              // render its pages again
await halcyn.ui.notify('Done')         // a short message at the bottom

// Reshaping Halcyn ("interface")
await halcyn.ui.hide(['albums', 'smartPlaylists'])     // and ui.show(...)
await halcyn.ui.replace('songs', { title: 'Library', render })
await halcyn.ui.addTheme({ ...sameJsonAsAssetsThemes })    // in the theme picker
await halcyn.ui.addShortcut({ keys: 'ctrl+shift+k', run }) // desktop keyboards

// Saved values (JSON, up to 1 MB per plugin, kept until it's removed)
await halcyn.storage.get('key')
await halcyn.storage.set('key', { any: 'json' })

// Files ("files"): absolute paths
await halcyn.files.read(path)          // text, up to 20 MB
await halcyn.files.write(path, text)   // makes the folders it needs
await halcyn.files.list(dir)           // [{ name, path, directory, size }]
await halcyn.files.exists(path)
await halcyn.files.delete(path)        // a folder goes with everything in it

// Network ("network"): resolves to { status, body, contentType }
await halcyn.http.get(url, { headers })
await halcyn.http.post(url, body, { headers })  // body: a string, or JSON

// Also there: console.log / console.error (shown in the plugin's log),
// setTimeout / clearTimeout, Promise, JSON and the rest of standard JavaScript.
```

A track looks like this:

```js
{
  path /* a file's, or tidal:<id> / ytm:<id> for a streamed song */,
  title, artists: [...], artist /* joined */, album, albumArtist,
  year, trackNo, discNo, duration /* seconds */, sampleRate, bits, codec, plays,
  art /* cover key, for an image block's `art` */
}
```

## Tabs

`where` says where a tab goes:

| `where`               | Desktop                           | Phone                          |
|-----------------------|-----------------------------------|--------------------------------|
| `sidebar` (default)   | the sidebar's Plugins section     | the Library tab's row          |
| `library`             | under Songs, Albums, Artists, Queue | the Library tab's row        |
| `main`                | the top of the sidebar            | the bottom bar (2 at most)     |

`halcyn.ui.addPage({ title, render })` is the same as a `sidebar` tab.

Built-in tabs a plugin can hide or replace: `songs`, `albums`, `artists`, `queue`,
`smartPlaylists`, `playlists`, `search`. A replaced tab keeps its place and takes the
title you give. Settings and Manage plugins can't be hidden or replaced, so a plugin
can always be turned off. When a plugin stops, everything it changed goes back.

## Pages

`render` returns a list of blocks (it may be `async`). Callbacks (`onPress`,
`onChange`, …) are functions. After one runs, the page renders again, so a page can
keep its state in plain variables. Give a block an `id` to keep it the same between
renders (a text field keeps what's typed).

```js
halcyn.ui.addTab({
  title: 'Hello',
  icon: 'sparkle',
  render: async () => [
    { type: 'heading', text: 'Hello' },
    { type: 'text', text: 'Some words.', style: 'muted' },
    { type: 'button', title: 'Next', icon: 'next', onPress: () => halcyn.player.next() },
    { type: 'tracks', tracks: await halcyn.library.search('jvke') },
  ],
});
```

| Block        | Takes                                                                     |
|--------------|---------------------------------------------------------------------------|
| `heading`    | `text`, `size: 'large'`                                                   |
| `text`       | `text`, `style`: `muted`, `small`, `bold` or `mono`                       |
| `button`     | `title`, `icon`, `onPress`, `style`: `tonal` (default), `filled`, `outlined`, `text` |
| `iconButton` | `icon`, `title` (its tooltip), `selected`, `onPress`                      |
| `row`        | `children`, `gap`; a child with `flex: n` takes that share of the room   |
| `column`     | `children`, `gap`                                                         |
| `wrap`       | `children`, `gap`: wraps onto more lines                                  |
| `card`       | `children`, `gap`, `onPress`                                              |
| `image`      | `src` (a web address or a file's path) or `art` (a track's), `width`, `height`, `radius`, `fit: 'contain'` |
| `list`       | `items: [{ title, subtitle, trailing, icon, image or art, onPress }]`     |
| `tracks`     | `tracks` or `paths`: tapping one plays the list from there                |
| `input`      | `label`, `placeholder`, `value`, `secret`, `multiline`, `onChange(text)` (no re-render), `onSubmit(text)` |
| `switch`     | `label`, `detail`, `value`, `onChange(on)`                                |
| `slider`     | `label`, `min`, `max`, `step`, `value`, `onChange(value)` (when let go)   |
| `select`     | `label`, `value`, `options` (strings or `{ value, label }`), `onChange(value)` |
| `progress`   | `value` from 0 to 1, or none for a spinner-like bar                       |
| `divider`    |                                                                           |
| `spacer`     | `size`                                                                    |

Icons are names: `extension`, `music`, `album`, `artist`, `playlist`, `library`,
`play`, `pause`, `next`, `previous`, `shuffle`, `repeat`, `volume`, `lyrics`, `radio`,
`mic`, `headphones`, `speaker`, `equalizer`, `waves`, `heart`, `heartFilled`, `star`,
`starFilled`, `thumbUp`, `thumbDown`, `history`, `clock`, `timer`, `alarm`,
`calendar`, `chart`, `trending`, `explore`, `search`, `filter`, `sort`, `tag`, `edit`,
`add`, `remove`, `delete`, `close`, `check`, `refresh`, `download`, `upload`, `share`,
`link`, `cloud`, `folder`, `file`, `image`, `settings`, `tune`, `info`, `warning`,
`error`, `help`, `home`, `sparkle`, `bolt`, `moon`, `sun`, `palette`, `keyboard`,
`bell`, `chat`, `person`, `people`, `globe`, `lock`, `eye`, `more`, `menu`,
`arrowBack`, `arrowForward`, `open`.

## Shortcuts

`keys` is modifiers and a key joined with `+`: `ctrl`, `shift`, `alt`, `meta`, then a
letter, digit or symbol, `f1`–`f12`, `space`, `enter`, `escape`, `tab`, `backspace`,
`delete`, `home`, `end`, `pageup`, `pagedown`, `left`, `right`, `up`, `down`.

## What a plugin can't do

It runs JavaScript in a sandbox, not code inside Halcyn: it can't load native
libraries, run programs or draw its own widgets. Everything above is what it gets.

## Limits

- 64 MB of memory, and each turn of the plugin's code (its top level, a handler, a
  timer) may run for 3 seconds before it's stopped. Long work should wait on promises.
- Handlers have 20 seconds to return; `beforePlay` has 3.
- A response from `halcyn.http` can be up to 5 MB, a plugin file up to 1 MB.

Errors, including ones thrown inside promises, go to the plugin's log on its card in
Manage plugins. A plugin that throws at its top level is installed but doesn't start;
the reason shows on its card.
