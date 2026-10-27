import 'package:flutter/material.dart';

import '../theme.dart';
import 'widgets.dart';

/// Every theme template as a small live preview: its sky, a glass dock with a cover,
/// two lines of text and the play orb. Click one to switch.
class ThemePicker extends StatelessWidget {
  const ThemePicker({super.key});

  @override
  Widget build(BuildContext context) {
    final themes = AppScope.of(context).themes;
    return ListenableBuilder(
      listenable: themes,
      builder: (context, _) => Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          for (final theme in themes.themes)
            _ThemeCard(
              theme: theme,
              selected: theme.id == themes.current.id,
              onTap: () => themes.select(theme),
            ),
        ],
      ),
    );
  }
}

class _ThemeCard extends StatefulWidget {
  const _ThemeCard({
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  final HalcynTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ThemeCard> createState() => _ThemeCardState();
}

class _ThemeCardState extends State<_ThemeCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final radius = BorderRadius.circular(Palette.r(14));
    return Tooltip(
      message: t.description,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: SizedBox(
            width: 184,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedScale(
                  scale: _hover ? 1.03 : 1,
                  duration: Motion.medium,
                  curve: Motion.curve,
                  child: AnimatedContainer(
                    duration: Motion.medium,
                    curve: Motion.curve,
                    height: 112,
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      border: Border.all(
                        color: widget.selected
                            ? Palette.accent
                            : Palette.glassRim,
                        width: widget.selected ? 2 : 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color:
                              (widget.selected ? Palette.accent : Colors.black)
                                  .withValues(
                                    alpha: _hover || widget.selected
                                        ? 0.3
                                        : 0.15,
                                  ),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: radius,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          VelvetBackground(theme: t),
                          Positioned(
                            left: 10,
                            right: 10,
                            bottom: 10,
                            child: _MiniDock(theme: t),
                          ),
                          Positioned(
                            left: 12,
                            top: 12,
                            child: Text(
                              'Aa',
                              style: TextStyle(
                                color: t.text,
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.5,
                              ),
                            ),
                          ),
                          Positioned(
                            right: 12,
                            top: 14,
                            child: Row(
                              children: [
                                for (final c in [t.accent, t.warm])
                                  Container(
                                    width: 12,
                                    height: 12,
                                    margin: const EdgeInsets.only(left: 5),
                                    decoration: BoxDecoration(
                                      color: c,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (widget.selected)
                            Positioned(
                              left: 46,
                              top: 15,
                              child: Icon(
                                Icons.check_circle_rounded,
                                size: 18,
                                color: t.accent,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  t.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: widget.selected ? Palette.accent : Palette.text,
                  ),
                ),
                Text(
                  t.dark ? 'Dark' : 'Light',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: Palette.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The player dock in miniature, drawn from the previewed theme's own values.
class _MiniDock extends StatelessWidget {
  const _MiniDock({required this.theme});

  final HalcynTheme theme;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final radius = BorderRadius.circular(10 * t.radius);
    // The dock's tint, then its veil and rim, both under the contents.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        color: t.background.withValues(alpha: t.dockTint),
      ),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: t.veil.withValues(alpha: t.rim)),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              t.veil.withValues(alpha: t.veilTop),
              t.veil.withValues(alpha: t.veilBottom),
            ],
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4 * t.radius),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [t.warm, t.accentDeep],
                ),
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Line(color: t.text, width: 52),
                  const SizedBox(height: 4),
                  _Line(color: t.textMuted, width: 34),
                ],
              ),
            ),
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [t.accentLight, t.accent, t.accentDeep],
                ),
                boxShadow: [
                  BoxShadow(
                    color: t.accent.withValues(alpha: 0.4),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: Icon(
                Icons.play_arrow_rounded,
                size: 16,
                color: t.onAccent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.color, required this.width});

  final Color color;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 5,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}
