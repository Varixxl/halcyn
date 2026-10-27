import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/src/state/plugins.dart';
import 'package:halcyn/src/ui/widgets.dart';

void main() {
  test('formatPlays formats numbers cleanly', () {
    expect(formatPlays(0), '0');
    expect(formatPlays(7), '7');
    expect(formatPlays(999), '999');
    expect(formatPlays(1200), '1.2k');
    expect(formatPlays(15400), '15k');
    expect(formatPlays(1200000), '1.2M');
    expect(formatPlays(15000000), '15M');
  });

  test('play-counts plugin manifest is valid', () {
    final source =
        File('plugins/examples/play-counts.js').readAsStringSync();
    final manifest = PluginManifest.parse(source);
    expect(manifest.id, 'io.github.varixxl.play-counts');
    expect(manifest.name, 'Play Counts');
    expect(manifest.permissions, {
      PluginPermission.interface,
      PluginPermission.library,
    });
    expect(manifest.platforms, {'linux', 'windows', 'android'});
  });
}
