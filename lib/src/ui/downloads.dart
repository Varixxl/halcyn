import 'package:flutter/material.dart';

import '../state/downloads.dart';
import '../theme.dart';
import 'widgets.dart';

/// "Downloading 4 of 20 · 37%", for the downloads under way.
String downloadsLabel(DownloadsController downloads) =>
    'Downloading ${downloads.done + downloads.failed + 1} of '
    '${downloads.total} · ${(downloads.progress * 100).floor()}%';

/// Above the player while songs download, on every page: how far along they are, the
/// songs downloading now, and Stop.
class DownloadsBar extends StatelessWidget {
  const DownloadsBar({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final downloads = AppScope.of(context).downloads;
    return ListenableBuilder(
      listenable: downloads,
      builder: (context, _) => AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.bottomCenter,
        child: !downloads.busy
            ? const SizedBox(width: double.infinity)
            : Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                decoration: BoxDecoration(
                  color: Palette.surface,
                  border: Border(top: BorderSide(color: Palette.outline)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.download_rounded,
                      size: 20,
                      color: Palette.accentLight,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            [
                              downloadsLabel(downloads),
                              ...downloads.downloading.map((t) => t.title),
                            ].join('  ·  '),
                            style: theme.textTheme.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          DownloadsProgressBar(value: downloads.progress),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    TextButton(
                      onPressed: downloads.cancel,
                      child: const Text('Stop'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// A rounded bar that glides to each new value rather than jumping.
class DownloadsProgressBar extends StatelessWidget {
  const DownloadsProgressBar({super.key, required this.value, this.height = 4});

  final double value;
  final double height;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: value),
    duration: const Duration(milliseconds: 260),
    builder: (context, v, _) => ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: LinearProgressIndicator(
        value: v,
        minHeight: height,
        color: Palette.accent,
        backgroundColor: Palette.outline,
      ),
    ),
  );
}
