import 'dart:math';

import 'package:flutter/material.dart';

import '../state/sound.dart';
import '../theme.dart';
import 'slate.dart';
import 'widgets.dart';

/// Opens the Sound panel: volume, the equalizer, and headphone corrections.
Future<void> openSound(BuildContext context, {int tab = 0}) {
  final size = MediaQuery.sizeOf(context);
  final panel = _SoundPanel(initialTab: tab);
  return showDialog(
    context: context,
    builder: (context) => size.width < 720 || size.height < 560
        ? Dialog.fullscreen(backgroundColor: Palette.surface, child: panel)
        : Dialog(
            backgroundColor: Palette.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Palette.r(24)),
              side: BorderSide(color: Palette.outline),
            ),
            child: SizedBox(
              width: 760,
              height: min(680, size.height - 80),
              child: panel,
            ),
          ),
  );
}

/// Opens the Sound panel; lit while the EQ is on.
class EqButton extends StatelessWidget {
  const EqButton({super.key});

  @override
  Widget build(BuildContext context) {
    final sound = AppScope.of(context).sound;
    return ListenableBuilder(
      listenable: sound,
      builder: (context, _) => IconButton(
        onPressed: () => openSound(context),
        isSelected: sound.eq,
        icon: const Icon(Icons.tune_rounded),
        selectedIcon: Icon(Icons.tune_rounded, color: Palette.accentLight),
        iconSize: 20,
        color: Palette.textMuted,
        tooltip: sound.eq ? 'Equalizer is on' : 'Equalizer',
      ),
    );
  }
}

/// The speaker (click to mute) and a volume slider.
class VolumeSlider extends StatelessWidget {
  const VolumeSlider({super.key, this.width = 120});

  final double width;

  @override
  Widget build(BuildContext context) {
    final sound = AppScope.of(context).sound;
    final cast = AppScope.of(context).cast;
    return ListenableBuilder(
      listenable: Listenable.merge([sound, cast]),
      builder: (context, _) {
        // While casting, the volume of the device cast to.
        final remote = cast.connected;
        final v = remote ? cast.volume : sound.volume;
        final muted = v == 0;
        final icon = v == 0
            ? Icons.volume_off_rounded
            : v < 0.5
            ? Icons.volume_down_rounded
            : Icons.volume_up_rounded;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: remote ? cast.toggleMute : sound.toggleMute,
              icon: Icon(icon),
              iconSize: 20,
              color: Palette.textMuted,
              tooltip: muted ? 'Unmute' : 'Mute',
            ),
            SizedBox(
              width: width,
              child: SliderTheme(
                data: SliderTheme.of(context)
                    .copyWith(padding: EdgeInsets.zero, trackHeight: 3),
                child: Slider(
                  value: v,
                  onChanged: remote ? cast.setVolume : sound.setVolume,
                  label: '${(v * 100).round()}%',
                  semanticFormatterCallback: (v) =>
                      'Volume ${(v * 100).round()}%',
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SoundPanel extends StatelessWidget {
  const _SoundPanel({required this.initialTab});

  final int initialTab;

  @override
  Widget build(BuildContext context) {
    final sound = AppScope.of(context).sound;
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 3,
      initialIndex: initialTab,
      child: ListenableBuilder(
        listenable: sound,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 12, 0),
              // A phone: a shorter slider, and the switch without its label.
              child: LayoutBuilder(
                builder: (context, box) {
                  final narrow = box.maxWidth < 520;
                  return Row(
                    children: [
                      Text('Sound', style: theme.textTheme.titleLarge),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: VolumeSlider(width: narrow ? 90 : 160),
                        ),
                      ),
                      if (!narrow) ...[
                        Text(
                          'Equalizer',
                          style: TextStyle(
                            color: Palette.textMuted,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Tooltip(
                        message: 'Equalizer',
                        child: Switch(value: sound.eq, onChanged: sound.setEq),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                        tooltip: 'Close',
                      ),
                    ],
                  );
                },
              ),
            ),
            TabBar(
              tabAlignment: TabAlignment.start,
              isScrollable: true,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              dividerColor: Palette.outline,
              tabs: [
                const Tab(text: 'Equalizer'),
                Tab(
                  text: sound.correction == null
                      ? 'Headphones'
                      : 'Headphones · ${sound.correction!.name}',
                ),
                Tab(
                  text: sound.tempoChanged
                      ? 'Pitch & speed · ${_tempo(sound)}'
                      : 'Pitch & speed',
                ),
              ],
            ),
            const Expanded(
              child: TabBarView(
                children: [_EqualizerTab(), _HeadphonesTab(), _TempoTab()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EqualizerTab extends StatelessWidget {
  const _EqualizerTab();

  @override
  Widget build(BuildContext context) {
    final sound = AppScope.of(context).sound;
    return ListenableBuilder(
      listenable: sound,
      builder: (context, _) => _build(context, sound),
    );
  }

  Widget _build(BuildContext context, SoundController sound) {
    final muted = TextStyle(color: Palette.textMuted, fontSize: 12);
    return AnimatedOpacity(
      opacity: sound.eq ? 1 : 0.55,
      duration: Motion.medium,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
        children: [
          SizedBox(
            height: 130,
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _CurvePainter(
                  freqs: sound.curveFreqs,
                  curve: sound.curve,
                  line: sound.eq ? Palette.accentLight : Palette.textMuted,
                  grid: Palette.outline,
                  label: Palette.textMuted,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            [
              if (sound.correction case final h?) 'Corrected for ${h.name}',
              if (sound.preampDb < 0)
                'Pre-gain ${sound.preampDb.toStringAsFixed(1)} dB keeps the boosts from clipping',
            ].join(' · '),
            style: muted,
          ),
          const SizedBox(height: 16),
          _Tone(
            label: 'Bass',
            hint: 'Below 100 Hz',
            value: sound.bass,
            onChanged: sound.setBass,
          ),
          _Tone(
            label: 'Treble',
            hint: 'Above 8 kHz',
            value: sound.treble,
            onChanged: sound.setTreble,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final MapEntry(:key, :value) in eqPresets.entries)
                      Pill(
                        label: value.$1,
                        selected: sound.preset == key,
                        onPressed: () => sound.setPreset(key),
                      ),
                    if (sound.preset == 'custom')
                      Pill(label: 'Custom', selected: true, onPressed: () {}),
                  ],
                ),
              ),
              TextButton(onPressed: sound.reset, child: const Text('Reset')),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 210,
            child: Row(
              children: [
                for (final (i, hz) in eqBands.indexed)
                  Expanded(
                    child: Column(
                      children: [
                        Text(_db(sound.bands[i]), style: muted),
                        Expanded(
                          child: RotatedBox(
                            quarterTurns: 3,
                            child: Slider(
                              value: sound.bands[i],
                              min: -eqRange,
                              max: eqRange,
                              onChanged: (v) => sound.setBand(i, v),
                            ),
                          ),
                        ),
                        Text(
                          hz < 1000 ? '$hz' : '${hz ~/ 1000}k',
                          style: muted,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _db(double db) => db == 0
    ? '0'
    : '${db > 0 ? '+' : '−'}${db.abs().toStringAsFixed(db == db.roundToDouble() ? 0 : 1)}';

String _semitones(double n) =>
    '${n > 0
        ? '+'
        : n < 0
        ? '−'
        : ''}'
    '${n.abs().toStringAsFixed(n == n.roundToDouble() ? 0 : 1)}';

String _times(double x) =>
    '${x.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '')}×';

/// "+2 · 1.25×": what's changed, for the tab.
String _tempo(SoundController sound) => [
  if (sound.pitch != 0) _semitones(sound.pitch),
  if (sound.speed != 1) _times(sound.speed),
].join(' · ');

/// Pitch and speed, each on its own: the pitch moves without the song speeding up, and
/// the speed changes without the pitch moving. Whatever plays, until they're reset.
class _TempoTab extends StatelessWidget {
  const _TempoTab();

  @override
  Widget build(BuildContext context) {
    final sound = AppScope.of(context).sound;
    return ListenableBuilder(
      listenable: sound,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
        children: [
          _TempoCard(
            title: 'Pitch',
            hint: 'Higher or lower, at the same speed',
            value: sound.pitch,
            shown: sound.pitch == 0
                ? 'Original'
                : '${_semitones(sound.pitch)} '
                      '${sound.pitch.abs() == 1 ? 'semitone' : 'semitones'}',
            min: -SoundController.maxPitch,
            max: SoundController.maxPitch,
            divisions: 48,
            step: 1,
            normal: 0,
            onChanged: (v, {live = true}) => sound.setPitch(v, live: live),
            picks: const [-2, -1, 0, 1, 2],
            pick: (v) => v == 0 ? '0' : _semitones(v),
          ),
          const SizedBox(height: 16),
          _TempoCard(
            title: 'Speed',
            hint: 'Faster or slower, at the same pitch',
            value: sound.speed,
            shown: sound.speed == 1 ? 'Normal' : _times(sound.speed),
            min: SoundController.minSpeed,
            max: SoundController.maxSpeed,
            divisions: 30,
            step: 0.05,
            normal: 1,
            onChanged: (v, {live = true}) => sound.setSpeed(v, live: live),
            picks: const [0.75, 0.9, 1, 1.1, 1.25, 1.5],
            pick: _times,
          ),
          const SizedBox(height: 12),
          Text(
            'Applies to every song until you set it back. Changing either one '
            'takes the song through Halcyn\'s own processing, so it\'s no longer '
            'bit-exact.',
            style: TextStyle(color: Palette.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _TempoCard extends StatelessWidget {
  const _TempoCard({
    required this.title,
    required this.hint,
    required this.value,
    required this.shown,
    required this.min,
    required this.max,
    required this.divisions,
    required this.step,
    required this.normal,
    required this.onChanged,
    required this.picks,
    required this.pick,
  });

  final String title;
  final String hint;
  final double value;
  final String shown;
  final double min;
  final double max;
  final int divisions;

  /// What the − and + buttons move it by.
  final double step;
  final double normal;
  final void Function(double value, {bool live}) onChanged;
  final List<double> picks;
  final String Function(double) pick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final changed = value != normal;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
      decoration: BoxDecoration(
        color: Palette.surfaceHigh,
        borderRadius: BorderRadius.circular(Palette.r(14)),
        border: Border.all(
          color: changed
              ? Palette.accent.withValues(alpha: 0.5)
              : Palette.outline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      hint,
                      style: TextStyle(color: Palette.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              AnimatedSwitcher(
                duration: Motion.fast,
                child: Text(
                  shown,
                  key: ValueKey(shown),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: changed ? Palette.accentLight : Palette.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: changed ? () => onChanged(normal) : null,
                child: const Text('Reset'),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                onPressed: value > min ? () => onChanged(value - step) : null,
                icon: const Icon(Icons.remove_rounded),
                tooltip: 'Lower',
              ),
              Expanded(
                child: Slider(
                  value: value.clamp(min, max),
                  min: min,
                  max: max,
                  divisions: divisions,
                  onChanged: (v) => onChanged(v, live: false),
                  onChangeEnd: onChanged,
                ),
              ),
              IconButton(
                onPressed: value < max ? () => onChanged(value + step) : null,
                icon: const Icon(Icons.add_rounded),
                tooltip: 'Higher',
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in picks)
                Pill(
                  label: pick(p),
                  selected: value == p,
                  onPressed: () => onChanged(p),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A labelled bass or treble slider.
class _Tone extends StatelessWidget {
  const _Tone({
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String hint;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 110,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                hint,
                style: TextStyle(color: Palette.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: -eqRange,
            max: eqRange,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 64,
          child: Text(
            '${_db(value)} dB',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontFeatures: const [FontFeature.tabularFigures()],
              color: Palette.text,
            ),
          ),
        ),
      ],
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter({
    required this.freqs,
    required this.curve,
    required this.line,
    required this.grid,
    required this.label,
  });

  final List<double> freqs;
  final List<double> curve;
  final Color line;
  final Color grid;
  final Color label;

  static const _range = 15.0;

  @override
  void paint(Canvas canvas, Size size) {
    double x(double hz) => log(hz / 20) / log(1000) * size.width;
    double y(double db) => size.height / 2 - db / _range * size.height / 2;
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final db in const <double>[-12, -6, 0, 6, 12]) {
      canvas.drawLine(
        Offset(0, y(db)),
        Offset(size.width, y(db)),
        gridPaint..color = grid.withValues(alpha: db == 0 ? 1 : 0.45),
      );
    }
    for (final (hz, text) in [
      (100.0, '100'),
      (1000.0, '1k'),
      (10000.0, '10k'),
    ]) {
      canvas.drawLine(
        Offset(x(hz), 0),
        Offset(x(hz), size.height),
        gridPaint..color = grid.withValues(alpha: 0.45),
      );
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: label, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x(hz) + 4, size.height - tp.height));
    }
    if (curve.length != freqs.length || curve.isEmpty) return;
    final path = Path()..moveTo(x(freqs.first), y(curve.first));
    for (var i = 1; i < curve.length; i++) {
      path.lineTo(x(freqs[i]), y(curve[i].clamp(-_range, _range)));
    }
    final fill = Path.from(path)
      ..lineTo(size.width, y(0))
      ..lineTo(0, y(0))
      ..close();
    canvas.drawPath(fill, Paint()..color = line.withValues(alpha: 0.12));
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CurvePainter old) =>
      old.curve != curve || old.line != line || old.grid != grid;
}

class _HeadphonesTab extends StatefulWidget {
  const _HeadphonesTab();

  @override
  State<_HeadphonesTab> createState() => _HeadphonesTabState();
}

class _HeadphonesTabState extends State<_HeadphonesTab> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final sound = AppScope.of(context).sound;
    return ListenableBuilder(
      listenable: sound,
      builder: (context, _) => _build(context, sound),
    );
  }

  Widget _build(BuildContext context, SoundController sound) {
    final q = _query.toLowerCase();
    final found = [
      for (final h in sound.headphones)
        if (h.name.toLowerCase().contains(q)) h,
    ];
    final groups = [
      (
        'Over-ear and on-ear',
        [
          for (final h in found)
            if (!h.earbuds) h,
        ],
      ),
      (
        'Earbuds and in-ear',
        [
          for (final h in found)
            if (h.earbuds) h,
        ],
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: TextField(
            onChanged: (v) => setState(() => _query = v.trim()),
            decoration: const InputDecoration(
              hintText: 'Find your headphones',
              prefixIcon: Icon(Icons.search_rounded, size: 18),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: [
              if (q.isEmpty)
                _tile(
                  context,
                  title: 'None',
                  subtitle: 'No correction',
                  selected: sound.headphone == null,
                  onTap: () => sound.setHeadphone(null),
                ),
              for (final (name, list) in groups)
                if (list.isNotEmpty) ...[
                  SectionLabel(name),
                  for (final h in list)
                    _tile(
                      context,
                      title: h.name,
                      subtitle: 'Measured by ${h.source}',
                      selected: sound.headphone == h.id,
                      onTap: () => sound.setHeadphone(h.id),
                    ),
                ],
              if (found.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'No preset for "$_query" yet.',
                    style: TextStyle(color: Palette.textMuted),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
                child: Text(
                  'Each correction brings that model to the Harman target, the tuning '
                  'most listeners prefer. Measurements via AutoEq.',
                  style: TextStyle(color: Palette.textMuted, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ListTile(
      dense: true,
      title: Text(
        title,
        style: TextStyle(
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? Palette.accentLight : Palette.text,
        ),
      ),
      subtitle: Text(subtitle, style: TextStyle(color: Palette.textMuted)),
      trailing: selected
          ? Icon(Icons.check_rounded, color: Palette.accentLight)
          : null,
      selected: selected,
      selectedTileColor: Palette.accent.withValues(alpha: 0.1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Palette.r(16)),
      ),
      onTap: onTap,
    );
  }
}
