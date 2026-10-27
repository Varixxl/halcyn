/* halcyn-plugin
{
  "id": "io.github.varixxl.sleep-timer",
  "name": "Sleep timer",
  "version": "1.0.0",
  "platforms": ["linux", "windows", "android"],
  "halcyn": "0.2.0",
  "author": "Halcyn",
  "description": "A moon button by the player that fades the music out and pauses after a while. Set how long in Settings; Ctrl+Shift+S starts it on a desktop.",
  "permissions": ["player", "interface"]
}
*/

let minutes = 30;
let fade = true;
let endsAt = null;
let timer = null;

halcyn.storage.get('settings').then((saved) => {
  if (saved) ({ minutes, fade } = saved);
});

const save = () => halcyn.storage.set('settings', { minutes, fade });

const left = () => Math.max(0, Math.round((endsAt - Date.now()) / 60000));

async function stop(quietly) {
  if (timer) clearTimeout(timer);
  timer = null;
  endsAt = null;
  if (!quietly) await halcyn.ui.notify('Sleep timer off');
}

async function finish() {
  timer = null;
  endsAt = null;
  if (fade) {
    const start = await halcyn.player.volume();
    for (let i = 1; i <= 10; i++) {
      await new Promise((done) => setTimeout(done, 1000));
      await halcyn.player.setVolume(start * (1 - i / 10));
    }
    await halcyn.player.pause();
    await halcyn.player.setVolume(start);
  } else {
    await halcyn.player.pause();
  }
  await halcyn.ui.notify('Good night');
}

async function start(mins = minutes) {
  await stop(true);
  endsAt = Date.now() + mins * 60000;
  timer = setTimeout(finish, mins * 60000);
  await halcyn.ui.notify(`Pausing in ${mins} min`);
}

halcyn.ui.addPlayerButton({
  title: 'Sleep timer',
  icon: 'moon',
  run: () =>
    halcyn.ui.dialog({
      title: 'Sleep timer',
      render: () => [
        endsAt
          ? { type: 'text', text: `Pausing in ${left()} min.` }
          : { type: 'text', text: 'Pause the music after:', style: 'muted' },
        {
          type: 'wrap',
          children: [15, 30, 45, 60, 90].map((m) => ({
            type: 'button',
            title: `${m} min`,
            style: m === minutes ? 'filled' : 'outlined',
            onPress: async () => {
              await start(m);
              await halcyn.ui.closeDialog();
            },
          })),
        },
        endsAt && {
          type: 'button',
          title: 'Turn it off',
          style: 'text',
          icon: 'close',
          onPress: async () => {
            await stop();
            await halcyn.ui.closeDialog();
          },
        },
      ].filter(Boolean),
    }),
});

halcyn.ui.addSettings({
  title: 'Sleep timer',
  render: () => [
    {
      type: 'slider',
      label: `${minutes} minutes`,
      min: 5,
      max: 120,
      step: 5,
      value: minutes,
      onChange: (v) => {
        minutes = Math.round(v);
        return save();
      },
    },
    {
      type: 'switch',
      label: 'Fade out',
      detail: 'Lower the volume over the last ten seconds',
      value: fade,
      onChange: (on) => {
        fade = on;
        return save();
      },
    },
  ],
});

halcyn.ui.addShortcut({
  keys: 'ctrl+shift+s',
  run: () => (endsAt ? stop() : start()),
});
