/* halcyn-plugin
{
  "id": "io.github.varixxl.play-counts",
  "name": "Play Counts",
  "version": "1.0.0",
  "platforms": ["linux", "windows", "android"],
  "halcyn": "0.2.0",
  "author": "Varixxl",
  "description": "Adds track play counts next to every track on the UI where applicable, with sorting and stats.",
  "permissions": ["interface", "library"]
}
*/

let showing = true;

(async () => {
  const saved = await halcyn.storage.get('showPlays');
  if (saved !== null && saved !== undefined) {
    showing = Boolean(saved);
  }
  await halcyn.ui.showTrackPlays(showing);
})();

halcyn.ui.addTrackAction({
  title: 'Show play count',
  icon: 'chart',
  run: async (track) => {
    const plays = track.plays || 0;
    const last = track.lastPlayed
      ? new Date(track.lastPlayed * 1000).toLocaleString()
      : 'Never';
    halcyn.ui.notify(
      `"${track.title}" has ${plays} ${plays === 1 ? 'play' : 'plays'}. Last played: ${last}`
    );
  },
});

halcyn.ui.addSettings({
  title: 'Play Counts',
  render: async () => {
    const tracks = await halcyn.library.tracks();
    const totalPlays = tracks.reduce((sum, t) => sum + (t.plays || 0), 0);
    const played = tracks.filter((t) => (t.plays || 0) > 0);
    const unplayed = tracks.length - played.length;
    const top = [...tracks]
      .sort((a, b) => (b.plays || 0) - (a.plays || 0))
      .slice(0, 5);

    return [
      { type: 'heading', text: 'Play Counts' },
      {
        type: 'switch',
        label: 'Show play counts in track lists',
        detail: 'Display play counts next to tracks across songs, albums, artists, and playlists.',
        value: showing,
        onChange: async (on) => {
          showing = on;
          await halcyn.storage.set('showPlays', showing);
          await halcyn.ui.showTrackPlays(showing);
        },
      },
      {
        type: 'text',
        text: `${totalPlays} total plays across ${tracks.length} tracks (${played.length} played, ${unplayed} unplayed).`,
        style: 'muted',
      },
      { type: 'heading', text: 'Top 5 Most Played' },
      top.length
        ? { type: 'tracks', tracks: top }
        : { type: 'text', text: 'No plays recorded yet.' },
    ];
  },
});
