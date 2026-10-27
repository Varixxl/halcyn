import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// The theme templates in assets/themes/, and which one is active. The choice is kept
/// in `<app support>/ui.json`.
class ThemeController extends ChangeNotifier {
  /// Used until the user picks another.
  static const defaultId = 'adaptive-slate';

  ThemeController(this._settings, {this.persist = true}) {
    nowPlayingCard.addListener(_save);
  }

  final File _settings;

  /// False while testing, so the real choices are read but never overwritten.
  final bool persist;

  /// Whether the cover card floats at the bottom right of the desktop window. Apart from
  /// the theme, so hiding it doesn't rebuild the whole app.
  final nowPlayingCard = ValueNotifier(true);
  List<HalcynTheme> themes = const [HalcynTheme.lapisVelvetEvening];

  HalcynTheme get current => Palette.theme;

  /// Loads the templates and applies the saved choice. A template that fails to parse
  /// is skipped (and reported), so one bad file can't take the app's look down.
  Future<void> load() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final loaded = <HalcynTheme>[];
    for (final path in manifest.listAssets()) {
      if (!path.startsWith('assets/themes/') || !path.endsWith('.json')) {
        continue;
      }
      try {
        final json = jsonDecode(await rootBundle.loadString(path));
        loaded.add(HalcynTheme.fromJson(json as Map<String, dynamic>));
      } on Object catch (e) {
        debugPrint('theme $path: $e');
      }
    }
    if (!loaded.any((t) => t.id == HalcynTheme.lapisVelvetEvening.id)) {
      loaded.insert(0, HalcynTheme.lapisVelvetEvening);
    }
    // The default first, then the rest: dark before light, by name.
    loaded.sort((a, b) {
      if (a.id == defaultId) return -1;
      if (b.id == defaultId) return 1;
      if (a.dark != b.dark) return a.dark ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    themes = List.unmodifiable(loaded);

    String? saved;
    try {
      final settings = jsonDecode(await _settings.readAsString()) as Map;
      saved = settings['theme'] as String?;
      nowPlayingCard.value = settings['nowPlayingCard'] != false;
    } on Object {
      // No settings yet.
    }
    Palette.theme = themes.firstWhere(
      (t) => t.id == (saved ?? defaultId),
      orElse: () => themes.first,
    );
  }

  Future<void> select(HalcynTheme theme) async {
    if (theme.id == current.id) return;
    Palette.theme = theme;
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    if (!persist) return;
    try {
      await _settings.writeAsString(
        jsonEncode({
          'theme': current.id,
          'nowPlayingCard': nowPlayingCard.value,
        }),
      );
    } on Object catch (e) {
      debugPrint('saving ui settings: $e');
    }
  }
}
