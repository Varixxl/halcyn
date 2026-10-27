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

  ThemeController(this._settings);

  final File _settings;
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
      saved =
          (jsonDecode(await _settings.readAsString()) as Map)['theme']
              as String?;
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
    try {
      await _settings.writeAsString(jsonEncode({'theme': theme.id}));
    } on Object catch (e) {
      debugPrint('saving theme: $e');
    }
  }
}
