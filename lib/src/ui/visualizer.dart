import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../rust/api/library.dart';
import '../rust/api/player.dart';
import '../theme.dart';
import 'widgets.dart';

/// The two colours the visualizer paints with, taken from the cover.
@immutable
class CoverPalette {
  const CoverPalette(this.primary, this.secondary);

  final Color primary;
  final Color secondary;

  /// The theme's accent, for covers with no colour of their own.
  static CoverPalette get fallback =>
      CoverPalette(Palette.accent, Palette.accentLight);

  static CoverPalette lerp(CoverPalette a, CoverPalette b, double t) =>
      CoverPalette(
        Color.lerp(a.primary, b.primary, t)!,
        Color.lerp(a.secondary, b.secondary, t)!,
      );

  static final _cache = <String, CoverPalette>{};

  /// Reads the cover's colours (cached), tuned to glow against the theme's background.
  static Future<CoverPalette> of(String artDir, String? art) async {
    if (art == null) return fallback;
    if (_cache[art] case final cached?) return cached;
    final colors = await libraryArtColors(artDir: artDir, art: art);
    final hsl = [for (final c in colors) HSLColor.fromColor(Color(c))];
    final CoverPalette palette;
    if (hsl.isEmpty || hsl.first.saturation < 0.15) {
      palette = fallback;
    } else {
      final primary = _tune(hsl.first);
      final secondary = hsl.length > 1
          ? _tune(hsl[1])
          : _tune(hsl.first.withHue((hsl.first.hue + 35) % 360));
      palette = CoverPalette(primary, secondary);
    }
    return _cache[art] = palette;
  }

  /// Vivid, and light on dark themes (dark on light ones), whatever the cover gave.
  static Color _tune(HSLColor c) {
    final dark = Palette.theme.dark;
    return c
        .withSaturation(c.saturation.clamp(0.55, 0.9))
        .withLightness(
          dark ? c.lightness.clamp(0.52, 0.66) : c.lightness.clamp(0.36, 0.46),
        )
        .toColor();
  }
}

/// The engine's band levels, shared: it runs one analyser, so every visualizer on screen
/// (Now Playing behind the mini player, say) listens to the same feed, which stops when
/// the last one goes.
final Stream<Float32List> _spectrumFeed = () {
  StreamSubscription<Float32List>? source;
  late final StreamController<Float32List> feed;
  feed = StreamController.broadcast(
    onListen: () => source = playerSpectrum().listen(feed.add),
    onCancel: () {
      source?.cancel();
      source = null;
      playerSpectrumStop();
    },
  );
  return feed.stream;
}();

/// A live spectrum behind `child`: bars rising from the bottom edge and a glow that
/// breathes with the bass, painted in the cover's colours. Only runs while shown, and
/// stops drawing when the music stops.
class VisualizerBackdrop extends StatefulWidget {
  const VisualizerBackdrop({super.key, required this.art, required this.child});

  final String? art;
  final Widget child;

  @override
  State<VisualizerBackdrop> createState() => _VisualizerBackdropState();
}

class _VisualizerBackdropState extends State<VisualizerBackdrop>
    with TickerProviderStateMixin {
  StreamSubscription<Float32List>? _spectrum;
  late final Ticker _ticker = createTicker(_tick);
  late final _colorShift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  final _frame = _Frame();
  Float32List _target = Float32List(0);
  Float32List _levels = Float32List(0);
  Duration _last = Duration.zero;
  DateTime _lastData = DateTime(0);

  CoverPalette _from = CoverPalette.fallback;
  CoverPalette _to = CoverPalette.fallback;

  @override
  void initState() {
    super.initState();
    _spectrum = _spectrumFeed.listen(_onSpectrum);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadColors();
  }

  @override
  void didUpdateWidget(VisualizerBackdrop old) {
    super.didUpdateWidget(old);
    if (old.art != widget.art) _loadColors();
  }

  Future<void> _loadColors() async {
    final art = widget.art;
    final palette = await CoverPalette.of(AppScope.of(context).artDir, art);
    if (!mounted || art != widget.art) return;
    _from = CoverPalette.lerp(_from, _to, _colorShift.value);
    _to = palette;
    _colorShift.forward(from: 0);
  }

  void _onSpectrum(Float32List bands) {
    if (_levels.length != bands.length) {
      _levels = Float32List(bands.length);
    }
    _target = bands;
    _lastData = DateTime.now();
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    // No data for a moment: the music stopped, so let the bars fall.
    final stale =
        DateTime.now().difference(_lastData) >
        const Duration(milliseconds: 150);
    final rise = 1 - exp(-dt * 30);
    final fall = 1 - exp(-dt * 7);
    var moving = false;
    for (var i = 0; i < _levels.length; i++) {
      final target = stale ? 0.0 : _target[i];
      final level = _levels[i];
      _levels[i] = level + (target - level) * (target > level ? rise : fall);
      if (_levels[i] > 0.002 || target > 0) moving = true;
    }
    _frame.levels = _levels;
    _frame.tick();
    if (!moving) _ticker.stop();
  }

  @override
  void dispose() {
    _spectrum?.cancel();
    _ticker.dispose();
    _colorShift.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: Palette.background),
        RepaintBoundary(
          child: CustomPaint(
            painter: _SpectrumPainter(
              frame: _frame,
              colors: _colorShift,
              palette: () => CoverPalette.lerp(
                _from,
                _to,
                Motion.curve.transform(_colorShift.value),
              ),
              background: Palette.background,
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

/// Holds the latest smoothed levels and tells the painter to repaint.
class _Frame extends ChangeNotifier {
  Float32List levels = Float32List(0);

  void tick() => notifyListeners();
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({
    required this.frame,
    required Animation<double> colors,
    required this.palette,
    required this.background,
  }) : super(repaint: Listenable.merge([frame, colors]));

  final _Frame frame;
  final CoverPalette Function() palette;
  final Color background;

  double _average(Float32List levels, int from, int to) {
    if (levels.length < to) return 0;
    var sum = 0.0;
    for (var i = from; i < to; i++) {
      sum += levels[i];
    }
    return sum / (to - from);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final levels = frame.levels;
    final colors = palette();
    final bass = _average(levels, 0, 8);
    final mids = _average(levels, 16, 40);
    final side = size.shortestSide;

    // The glows: the cover's main colour behind the art, breathing with the bass, and
    // its second colour low on the right, following the mids.
    void glow(Alignment at, Color color, double alpha, double radius) {
      final centre = at.alongSize(size);
      canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: alpha),
              color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: centre, radius: radius)),
      );
    }

    glow(
      const Alignment(-0.5, -0.15),
      colors.primary,
      0.16 + 0.26 * bass,
      side * (0.85 + 0.15 * bass),
    );
    glow(
      const Alignment(0.8, 0.85),
      colors.secondary,
      0.10 + 0.22 * mids,
      side * 0.8,
    );

    if (levels.isEmpty) return;

    // The bars, bass on the left, in a gradient from one colour to the other.
    const gap = 3.0;
    final count = levels.length;
    final width = (size.width - gap * (count - 1)) / count;
    final maxHeight = size.height * 0.38;
    final radius = Radius.circular(min(width / 2, 4));
    final bars = Path();
    for (var i = 0; i < count; i++) {
      final level = levels[i];
      if (level < 0.004) continue;
      final height = max(2.0, pow(level, 1.25) * maxHeight);
      final x = i * (width + gap);
      bars.addRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(x, size.height - height, width, height),
          topLeft: radius,
          topRight: radius,
        ),
      );
    }
    final area =
        Offset(0, size.height - maxHeight) & Size(size.width, maxHeight);
    canvas.drawPath(
      bars,
      Paint()
        ..shader = LinearGradient(
          colors: [
            colors.primary.withValues(alpha: 0.62),
            colors.secondary.withValues(alpha: 0.62),
          ],
        ).createShader(area),
    );
    // Fade the bars into the floor, so the controls above them stay easy to read.
    canvas.drawRect(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            background.withValues(alpha: 0),
            background.withValues(alpha: 0.7),
          ],
        ).createShader(area),
    );
  }

  @override
  bool shouldRepaint(_SpectrumPainter old) =>
      old.frame != frame || old.background != background;
}
