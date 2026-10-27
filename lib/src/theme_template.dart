import 'dart:ui';

/// One theme template, loaded from `assets/themes/<id>.json`. The fields are documented
/// in assets/themes/README.md.
class HalcynTheme {
  const HalcynTheme({
    required this.id,
    required this.name,
    required this.description,
    required this.dark,
    required this.background,
    required this.backgroundTop,
    required this.surface,
    required this.surfaceHigh,
    required this.outline,
    required this.text,
    required this.textMuted,
    required this.accent,
    required this.accentLight,
    required this.accentDeep,
    required this.onAccent,
    required this.warm,
    required this.glows,
    required this.veil,
    required this.veilTop,
    required this.veilBottom,
    required this.rim,
    required this.gloss,
    required this.blur,
    required this.dockTint,
    required this.radius,
    required this.coverBlur,
    required this.coverOpacity,
    required this.scrim,
    required this.sheen,
  });

  final String id;
  final String name;
  final String description;
  final bool dark;

  final Color background;
  final Color backgroundTop;
  final Color surface;
  final Color surfaceHigh;
  final Color outline;
  final Color text;
  final Color textMuted;
  final Color accent;
  final Color accentLight;
  final Color accentDeep;
  final Color onAccent;
  final Color warm;

  final List<ThemeGlow> glows;

  final Color veil;
  final double veilTop;
  final double veilBottom;
  final double rim;
  final double gloss;
  final double blur;
  final double dockTint;

  /// Multiplies every corner radius.
  final double radius;

  final double coverBlur;
  final double coverOpacity;

  /// Alphas of `background` over the blurred cover, top → middle → bottom.
  final List<double> scrim;

  final double sheen;

  factory HalcynTheme.fromJson(Map<String, dynamic> json) {
    final colors = json['colors'] as Map<String, dynamic>;
    final glass = json['glass'] as Map<String, dynamic>;
    final shape = json['shape'] as Map<String, dynamic>? ?? const {};
    final cover = json['cover'] as Map<String, dynamic>;
    Color c(String key) => parseColor(colors[key] as String);
    double d(Map<String, dynamic> map, String key) =>
        (map[key] as num).toDouble();

    return HalcynTheme(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      dark: json['brightness'] != 'light',
      background: c('background'),
      backgroundTop: c('backgroundTop'),
      surface: c('surface'),
      surfaceHigh: c('surfaceHigh'),
      outline: c('outline'),
      text: c('text'),
      textMuted: c('textMuted'),
      accent: c('accent'),
      accentLight: c('accentLight'),
      accentDeep: c('accentDeep'),
      onAccent: c('onAccent'),
      warm: c('warm'),
      glows: [
        for (final g in (json['glows'] as List? ?? const []))
          ThemeGlow.fromJson(g as Map<String, dynamic>),
      ],
      veil: parseColor(glass['veil'] as String),
      veilTop: d(glass, 'veilTop'),
      veilBottom: d(glass, 'veilBottom'),
      rim: d(glass, 'rim'),
      gloss: d(glass, 'gloss'),
      blur: d(glass, 'blur'),
      dockTint: d(glass, 'dockTint'),
      radius: (shape['radius'] as num? ?? 1).toDouble(),
      coverBlur: d(cover, 'blur'),
      coverOpacity: d(cover, 'opacity'),
      scrim: [for (final a in cover['scrim'] as List) (a as num).toDouble()],
      sheen: (json['sheen'] as num).toDouble(),
    );
  }

  /// Built in, so the app has a look before (or without) the theme assets.
  static const lapisVelvetEvening = HalcynTheme(
    id: 'lapis-velvet-evening',
    name: 'Lapis Velvet Evening',
    description:
        'Midnight blue, lapis and violet dusk with a fleck of pyrite gold.',
    dark: true,
    background: Color(0xFF080B1F),
    backgroundTop: Color(0xFF0C1336),
    surface: Color(0xFF10173A),
    surfaceHigh: Color(0xFF18224F),
    outline: Color(0xFF26326A),
    text: Color(0xFFEEF1FB),
    textMuted: Color(0xFF98A1C8),
    accent: Color(0xFF668FF5),
    accentLight: Color(0xFF9DBBFF),
    accentDeep: Color(0xFF3557C9),
    onAccent: Color(0xFFFFFFFF),
    warm: Color(0xFFE3BC5E),
    glows: [
      ThemeGlow(
        x: -0.8,
        y: -1.1,
        color: Color(0xFF1E3F94),
        alpha: 0.55,
        radius: 1.3,
      ),
      ThemeGlow(
        x: 1.1,
        y: 0.9,
        color: Color(0xFF3A2470),
        alpha: 0.6,
        radius: 1.2,
      ),
      ThemeGlow(
        x: -1.2,
        y: 1.3,
        color: Color(0xFFE3BC5E),
        alpha: 0.07,
        radius: 0.8,
      ),
    ],
    veil: Color(0xFFFFFFFF),
    veilTop: 0.11,
    veilBottom: 0.02,
    rim: 0.10,
    gloss: 0.18,
    blur: 24,
    dockTint: 0.5,
    radius: 1,
    coverBlur: 70,
    coverOpacity: 0.75,
    scrim: [0.25, 0.6, 0.88],
    sheen: 0.15,
  );
}

/// A radial glow over the sky gradient. x/y are Alignment coordinates; radius is a
/// fraction of the shortest side.
class ThemeGlow {
  const ThemeGlow({
    required this.x,
    required this.y,
    required this.color,
    required this.alpha,
    required this.radius,
  });

  final double x;
  final double y;
  final Color color;
  final double alpha;
  final double radius;

  factory ThemeGlow.fromJson(Map<String, dynamic> json) => ThemeGlow(
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    color: parseColor(json['color'] as String),
    alpha: (json['alpha'] as num).toDouble(),
    radius: (json['radius'] as num).toDouble(),
  );
}

/// "#RRGGBB" or "#AARRGGBB".
Color parseColor(String hex) {
  final digits = hex.replaceFirst('#', '');
  final value = int.parse(digits, radix: 16);
  return Color(digits.length == 6 ? 0xFF000000 | value : value);
}
