import 'package:flutter/material.dart';

import 'rust/api/player.dart';
import 'theme.dart';

/// Shows what happens to the audio on its way out: file → Halcyn → output.
class SignalPathView extends StatelessWidget {
  const SignalPathView({super.key, required this.path});

  final SignalPath path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = path.bitExact ? Palette.accent : Palette.warm;

    return Glass(
      radius: 16,
      blur: 0,
      tint: Palette.background.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Signal path', style: theme.textTheme.titleSmall),
                const Spacer(),
                SignalBadge(path: path),
              ],
            ),
            const SizedBox(height: 12),
            _Stage(icon: Icons.audio_file_outlined, text: path.source),
            _Stage(
              icon: Icons.tune_rounded,
              text: path.processing,
              color: accent,
            ),
            _Stage(icon: Icons.speaker_outlined, text: path.output),
            if (path.warning case final warning?) ...[
              const SizedBox(height: 8),
              Text(
                warning,
                style: theme.textTheme.bodySmall?.copyWith(color: Palette.warm),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One word for what happens to the audio: Bit-exact, Resampled, EQ or Volume.
String signalLabel(SignalPath path) => path.bitExact
    ? 'Bit-exact'
    : path.processing.startsWith('Resampled')
    ? 'Resampled'
    : path.processing.startsWith('EQ')
    ? 'EQ'
    : 'Volume';

/// "Bit-exact" or "Resampled", as a small pill.
class SignalBadge extends StatelessWidget {
  const SignalBadge({super.key, required this.path});

  final SignalPath? path;

  @override
  Widget build(BuildContext context) {
    final path = this.path;
    return AnimatedSwitcher(
      duration: Motion.medium,
      child: path == null
          ? const SizedBox.shrink()
          : Tooltip(
              key: ValueKey(path.bitExact),
              message: '${path.source}\n${path.processing}\n${path.output}',
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: (path.bitExact ? Palette.accent : Palette.warm)
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(Palette.r(12)),
                ),
                child: Text(
                  signalLabel(path),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: path.bitExact ? Palette.accent : Palette.warm,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
    );
  }
}

class _Stage extends StatelessWidget {
  const _Stage({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color ?? Palette.textMuted),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
