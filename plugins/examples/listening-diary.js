/* halcyn-plugin
{
  "id": "io.github.varixxl.listening-diary",
  "name": "Listening diary",
  "version": "1.0.0",
  "platforms": ["linux", "windows", "android"],
  "halcyn": "0.2.0",
  "author": "Halcyn",
  "description": "Keeps a list of the last 50 songs you started, with the time, on a page of its own.",
  "permissions": ["player"]
}
*/

const KEY = 'entries';

halcyn.on('trackChanged', async (track) => {
  if (!track) return;
  const entries = (await halcyn.storage.get(KEY)) || [];
  entries.unshift({ at: new Date().toISOString(), title: track.title, artist: track.artist, path: track.path });
  await halcyn.storage.set(KEY, entries.slice(0, 50));
  halcyn.ui.refresh();
});

halcyn.ui.addPage({
  title: 'Listening diary',
  render: async () => {
    const entries = (await halcyn.storage.get(KEY)) || [];
    if (!entries.length) return [{ type: 'text', text: 'Play something and it shows up here.' }];
    return [
      { type: 'heading', text: `Last ${entries.length} songs` },
      ...entries.map((e) => ({
        type: 'text',
        text: `${new Date(e.at).toLocaleTimeString()}  ${e.title} · ${e.artist}`,
      })),
      { type: 'button', title: 'Clear', onPress: async () => { await halcyn.storage.set(KEY, []); halcyn.ui.refresh(); } },
    ];
  },
});
