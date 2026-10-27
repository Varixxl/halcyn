/* halcyn-plugin
{
  "id": "io.github.varixxl.discover",
  "name": "Discover",
  "version": "1.0.0",
  "platforms": ["linux", "windows", "android"],
  "halcyn": "0.2.0",
  "author": "Halcyn",
  "description": "A page of songs you haven't played yet, a random album button, and Play this artist in every song's menu.",
  "permissions": ["library", "player"]
}
*/

const pick = (list, n) => {
  const copy = [...list];
  for (let i = copy.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [copy[i], copy[j]] = [copy[j], copy[i]];
  }
  return copy.slice(0, n);
};

halcyn.ui.addPage({
  title: 'Discover',
  render: async () => {
    const tracks = await halcyn.library.tracks();
    const fresh = pick(tracks.filter((t) => t.plays === 0), 12);
    return [
      { type: 'heading', text: 'Not played yet' },
      { type: 'button', title: 'Play them all', onPress: () => halcyn.player.play(fresh) },
      { type: 'button', title: 'Shuffle these', onPress: () => halcyn.ui.refresh() },
      fresh.length
        ? { type: 'tracks', tracks: fresh }
        : { type: 'text', text: 'You have played everything. Impressive.' },
    ];
  },
});

halcyn.ui.addCommand({
  title: 'Play a random album',
  run: async () => {
    const tracks = await halcyn.library.tracks();
    const albums = [...new Set(tracks.map((t) => t.album).filter(Boolean))];
    if (!albums.length) return halcyn.ui.notify('No albums in the library');
    const [album] = pick(albums, 1);
    const songs = tracks
      .filter((t) => t.album === album)
      .sort((a, b) => (a.discNo || 0) - (b.discNo || 0) || (a.trackNo || 0) - (b.trackNo || 0));
    await halcyn.player.play(songs);
    halcyn.ui.notify(`Playing ${album}`);
  },
});

halcyn.ui.addTrackAction({
  title: 'Play this artist',
  run: async (track) => {
    const songs = await halcyn.library.search(track.artists[0] || track.artist);
    const theirs = songs.filter((t) => t.artists.includes(track.artists[0]));
    await halcyn.player.play(pick(theirs, theirs.length));
  },
});
