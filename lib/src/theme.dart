import 'dart:ui';

import 'package:flutter/material.dart';

import 'theme_template.dart';

export 'theme_template.dart';

/// The active theme's colours. Every widget reads them while building, so switching
/// themes (ThemeController) rebuilds the whole tree.
abstract final class Palette {
  static HalcynTheme theme = HalcynTheme.lapisVelvetEvening;

  static Color get background => theme.background;
  static Color get surface => theme.surface;
  static Color get surfaceHigh => theme.surfaceHigh;
  static Color get outline => theme.outline;
  static Color get text => theme.text;
  static Color get textMuted => theme.textMuted;
  static Color get accent => theme.accent;
  static Color get accentLight => theme.accentLight;
  static Color get accentDeep => theme.accentDeep;
  static Color get onAccent => theme.onAccent;
  static Color get warm => theme.warm;

  /// Glass: the veil (also hover and input fills), its rim, and the gloss streak.
  static Color get glass =>
      theme.veil.withValues(alpha: (theme.veilTop + theme.veilBottom) / 2);
  static Color get glassRim => theme.veil.withValues(alpha: theme.rim);
  static Color get gloss =>
      const Color(0xFFFFFFFF).withValues(alpha: theme.gloss);

  /// A corner radius scaled by the theme's shape.
  static double r(double radius) => radius * theme.radius;
}

/// Motion is short and eased out, so it reads as responsive rather than decorative.
abstract final class Motion {
  static const fast = Duration(milliseconds: 150);
  static const medium = Duration(milliseconds: 240);
  static const slow = Duration(milliseconds: 400);
  static const curve = Curves.easeOutCubic;
}

ThemeData buildTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: Palette.accent,
        brightness: Palette.theme.dark ? Brightness.dark : Brightness.light,
      ).copyWith(
        primary: Palette.accent,
        onPrimary: Palette.onAccent,
        tertiary: Palette.warm,
        surface: Palette.background,
        surfaceContainerLowest: Palette.background,
        surfaceContainerLow: Palette.surface,
        surfaceContainer: Palette.surface,
        surfaceContainerHigh: Palette.surfaceHigh,
        surfaceContainerHighest: Palette.surfaceHigh,
        onSurface: Palette.text,
        onSurfaceVariant: Palette.textMuted,
        outlineVariant: Palette.outline,
      );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Inter',
    // Pages are see-through: VelvetBackground sits behind everything.
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: Palette.surface,
    splashFactory: InkSparkle.splashFactory,
  );
  final text = base.textTheme;

  return base.copyWith(
    textTheme: text.copyWith(
      displaySmall: text.displaySmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -1,
      ),
      headlineMedium: text.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
      ),
      headlineSmall: text.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
      ),
      titleLarge: text.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    ),
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values)
          platform: const _FadeRiseTransitionsBuilder(),
      },
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      inactiveTrackColor: Palette.outline,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: Palette.accent.withValues(alpha: 0.22),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Palette.background.withValues(alpha: 0.55),
      indicatorColor: Palette.accent.withValues(alpha: 0.22),
      height: 64,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Palette.glass,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Palette.r(14)),
        borderSide: BorderSide(color: Palette.glassRim),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Palette.r(14)),
        borderSide: BorderSide(color: Palette.glassRim),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Palette.r(14)),
        borderSide: BorderSide(color: Palette.accent.withValues(alpha: 0.6)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Palette.accentDeep,
        foregroundColor: Palette.onAccent,
        shadowColor: Palette.accent,
        elevation: 6,
      ),
    ),
    hoverColor: Palette.glass,
    highlightColor: Palette.glass,
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 600),
      decoration: BoxDecoration(
        color: Palette.surfaceHigh.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(Palette.r(8)),
        border: Border.all(color: Palette.glassRim),
      ),
      textStyle: TextStyle(color: Palette.text, fontSize: 12),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Palette.surfaceHigh,
      contentTextStyle: TextStyle(color: Palette.text, fontSize: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Palette.r(16)),
        side: BorderSide(color: Palette.outline),
      ),
    ),
    scrollbarTheme: const ScrollbarThemeData(
      thickness: WidgetStatePropertyAll(6),
      radius: Radius.circular(3),
    ),
  );
}

/// Pages fade in while rising a few pixels.
class _FadeRiseTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeRiseTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Motion.curve);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.02),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

/// The sky behind the whole app: the theme's gradient with its glows over it.
/// Painted once per theme.
class VelvetBackground extends StatelessWidget {
  const VelvetBackground({super.key, this.theme});

  /// Defaults to the active theme; the theme picker passes others for its previews.
  final HalcynTheme? theme;

  @override
  Widget build(BuildContext context) {
    final theme = this.theme ?? Palette.theme;
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [theme.backgroundTop, theme.background],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            for (final glow in theme.glows)
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(glow.x, glow.y),
                    radius: glow.radius,
                    colors: [
                      glow.color.withValues(alpha: glow.alpha),
                      glow.color.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A frosted, glossy panel: blurs what's behind it, adds the theme's veil fading
/// downward, a thin rim, and a bright streak along the top edge.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 18,
    this.blur,
    this.tint,
  });

  final Widget child;

  /// Before the theme's shape scaling.
  final double radius;

  /// Defaults to the theme's blur; 0 skips it, for panels with nothing interesting
  /// behind them.
  final double? blur;

  /// Laid under the veil, e.g. a darker colour so text stays readable over art.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final theme = Palette.theme;
    final radius = Palette.r(this.radius);
    final blur = this.blur ?? theme.blur;
    final shape = BorderRadius.circular(radius);
    Widget panel = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            theme.veil.withValues(alpha: theme.veilTop),
            theme.veil.withValues(
              alpha: (theme.veilTop + 2 * theme.veilBottom) / 3,
            ),
            theme.veil.withValues(alpha: theme.veilBottom),
          ],
          stops: const [0, 0.45, 1],
        ),
        border: Border.all(color: Palette.glassRim),
      ),
      child: Stack(
        children: [
          child,
          // The gloss: a highlight along the top edge, brightest in the middle.
          if (theme.gloss > 0)
            Positioned(
              top: 0,
              left: radius,
              right: radius,
              height: 1,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        const Color(0x00FFFFFF),
                        Palette.gloss,
                        const Color(0x00FFFFFF),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (tint != null) {
      panel = DecoratedBox(
        decoration: BoxDecoration(color: tint, borderRadius: shape),
        child: panel,
      );
    }
    return ClipRRect(
      borderRadius: shape,
      child: blur > 0
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: panel,
            )
          : panel,
    );
  }
}
