import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/src/theme_template.dart';

/// WCAG contrast ratio between two opaque colours.
double contrast(Color a, Color b) {
  double luminance(Color c) {
    double channel(double v) =>
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(c.r) +
        0.7152 * channel(c.g) +
        0.0722 * channel(c.b);
  }

  final la = luminance(a), lb = luminance(b);
  return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
}

void main() {
  final files =
      Directory('assets/themes')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('there are theme templates', () => expect(files, isNotEmpty));

  final ids = <String>{};
  for (final file in files) {
    final name = file.uri.pathSegments.last;
    test(
      '$name parses, has a unique id matching its file, and is readable',
      () {
        final theme = HalcynTheme.fromJson(
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
        );
        expect('${theme.id}.json', name);
        expect(ids.add(theme.id), isTrue, reason: 'duplicate id ${theme.id}');
        expect(theme.glows.length, inInclusiveRange(0, 4));
        expect(theme.scrim, hasLength(3));
        expect(theme.radius, inInclusiveRange(0.2, 2));

        final rules = {
          'text / background': (theme.text, theme.background, 7.0),
          'text / backgroundTop': (theme.text, theme.backgroundTop, 7.0),
          'text / surfaceHigh': (theme.text, theme.surfaceHigh, 7.0),
          'textMuted / background': (theme.textMuted, theme.background, 4.5),
          'accent / background': (theme.accent, theme.background, 3.0),
          'warm / background': (theme.warm, theme.background, 3.0),
          'onAccent / accentDeep': (theme.onAccent, theme.accentDeep, 4.5),
          'onAccent / accent': (theme.onAccent, theme.accent, 3.0),
        };
        for (final MapEntry(key: rule, value: (fg, bg, minimum))
            in rules.entries) {
          expect(
            contrast(fg, bg),
            greaterThanOrEqualTo(minimum),
            reason: '${theme.id}: $rule',
          );
        }
      },
    );
  }
}
