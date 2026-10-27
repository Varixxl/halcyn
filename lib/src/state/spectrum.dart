import 'dart:async';

import 'package:flutter/foundation.dart';

import '../rust/api/player.dart';

/// The engine's band levels, shared: it runs one analyser, so everything listening (every
/// visualizer on screen, a cast receiver) gets the same feed, which stops when the last
/// one goes.
final Stream<Float32List> localSpectrum = () {
  StreamSubscription<Float32List>? source;
  late final StreamController<Float32List> feed;
  feed = StreamController.broadcast(
    onListen: () => source = playerSpectrum().listen(feed.add),
    onCancel: () {
      source?.cancel();
      source = null;
      playerSpectrumStop();
    },
  );
  return feed.stream;
}();

/// Set while casting: the other device's band levels.
final remoteSpectrum = ValueNotifier<Stream<Float32List> Function()?>(null);

/// What the visualizer shows: whatever is playing, here or on the device cast to.
final Stream<Float32List> spectrum = () {
  StreamSubscription<Float32List>? source;
  late final StreamController<Float32List> feed;
  void listen() =>
      source = (remoteSpectrum.value?.call() ?? localSpectrum).listen(feed.add);
  void swap() {
    source?.cancel();
    listen();
  }

  feed = StreamController.broadcast(
    onListen: () {
      remoteSpectrum.addListener(swap);
      listen();
    },
    onCancel: () {
      remoteSpectrum.removeListener(swap);
      source?.cancel();
      source = null;
    },
  );
  return feed.stream;
}();
