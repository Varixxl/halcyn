import 'dart:io';

import 'package:flutter/foundation.dart';

/// Keeps errors in `<app support>/halcyn.log`, since a release build's output goes
/// nowhere. Overflow warnings are left out; the file is cut back once it passes 1 MB.
void logErrorsTo(File log) {
  void write(String what, Object error, StackTrace? stack) {
    try {
      if (log.existsSync() && log.lengthSync() > 1 << 20) {
        log.writeAsStringSync('');
      }
      log.writeAsStringSync(
        '[${DateTime.now().toIso8601String()}] $what: $error\n'
        '${stack ?? ''}\n',
        mode: FileMode.append,
      );
    } on Object {
      // Logging must never be what breaks.
    }
  }

  final framework = FlutterError.onError;
  FlutterError.onError = (details) {
    if (!details.exceptionAsString().contains('overflowed')) {
      write('Flutter (${details.library})', details.exception, details.stack);
    }
    framework?.call(details);
  };
  final platform = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    write('Uncaught', error, stack);
    return platform?.call(error, stack) ?? false;
  };
}
