import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../rust/api/library.dart';
import '../rust/api/player.dart';
import '../state/library.dart';
import '../state/player.dart';
import '../state/sound.dart';
import '../state/spectrum.dart';
import 'protocol.dart';

/// A device allowed to cast here, and the token it proves that with.
class PairedDevice {
  PairedDevice(this.id, this.name, this.token);

  final String id;
  String name;
  final String token;
}

/// A device asking to cast here for the first time. The UI shows it and calls [answer].
class PairingRequest {
  PairingRequest(this.name);

  final String name;
  final _answer = Completer<bool>();

  void answer(bool allow) {
    if (!_answer.isCompleted) _answer.complete(allow);
  }
}

/// Lets other Halcyns on the network play through this one (see protocol.dart). It
/// answers discovery, approves devices, applies their commands to [player], sends them
/// its state, and keeps the songs they send in `<cache>/cast`.
class CastReceiver extends ChangeNotifier {
  CastReceiver({
    required this.player,
    required this.library,
    required this.sound,
    required this.settings,
    required Directory cacheDir,
    required this.artDir,
    this.persist = true,
  }) : castDir = Directory('${cacheDir.path}/cast');

  final PlayerController player;
  final LibraryController library;
  final SoundController sound;
  final File settings;
  final Directory castDir;
  final String artDir;

  /// False while testing: settings and approved devices aren't saved.
  final bool persist;

  /// Phones are usually the ones casting, so only desktops listen by default.
  bool enabled = !Platform.isAndroid;

  /// How senders tell this device apart from others with the same name.
  String id = randomHex(8);
  String name = Platform.localHostname;
  List<PairedDevice> devices = [];

  /// Devices waiting to be approved, oldest first.
  final requests = <PairingRequest>[];
  int? port;
  String? error;

  final _clients = <_Client>{};
  HttpServer? _server;
  RawDatagramSocket? _discovery;
  Timer? _stateTimer;
  final _positionClock = Stopwatch();
  double _sentPosition = 0;
  StreamSubscription<Float32List>? _spectrum;

  /// A replaced queue waiting for its first song to arrive: the song's path, and the
  /// call that plays it.
  (String, void Function())? _deferred;

  /// The sender's names for songs it sent that this device had its own copy of, by
  /// that copy's path, so the sender can show them as its own.
  final _sentAs = <String, String>{};

  /// Cast songs whose art hasn't arrived yet, by path.
  final _artFor = <String, String>{};

  /// The song last asked for urgently, so it's asked for once.
  String? _urged;

  /// Names of the devices casting here now.
  List<String> get connected => [
    for (final c in _clients)
      if (c.device case final device?) device.name,
  ];

  Future<void> load() async {
    try {
      final saved = jsonDecode(await settings.readAsString()) as Map;
      enabled = saved['enabled'] as bool? ?? enabled;
      id = saved['id'] as String? ?? id;
      devices = [
        for (final d in saved['devices'] as List? ?? const [])
          PairedDevice(
            d['id'] as String,
            d['name'] as String,
            d['token'] as String,
          ),
      ];
    } on Object {
      // Nothing saved yet.
    }
    if (enabled) await _start();
  }

  Future<void> setEnabled(bool on) async {
    if (on == enabled) return;
    enabled = on;
    _save();
    on ? await _start() : await _stop();
    notifyListeners();
  }

  /// Takes back a device's approval and disconnects it.
  void forget(String deviceId) {
    devices.removeWhere((d) => d.id == deviceId);
    for (final c in [..._clients]) {
      if (c.device?.id == deviceId) c.socket.close();
    }
    _save();
    notifyListeners();
  }

  Future<void> _start() async {
    error = null;
    try {
      final preferred = castPort('HALCYN_CAST_PORT', defaultPort);
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, preferred);
      } on SocketException {
        // Taken, e.g. by another Halcyn; discovery tells senders the port.
        _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      }
      port = _server!.port;
      _server!.listen(_handle);
      try {
        _discovery = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          castPort('HALCYN_CAST_DISCOVERY_PORT', discoveryPort),
        );
        _discovery!.listen(_onDatagram);
      } on SocketException catch (e) {
        debugPrint('cast discovery: $e');
      }
      player.addListener(_schedule);
      player.position.addListener(_onPosition);
      sound.addListener(_schedule);
      unawaited(_cleanCache());
    } on Object catch (e) {
      error = "Couldn't listen for devices: $e";
    }
    notifyListeners();
  }

  Future<void> _stop() async {
    player.removeListener(_schedule);
    player.position.removeListener(_onPosition);
    sound.removeListener(_schedule);
    for (final r in requests) {
      r.answer(false);
    }
    for (final c in [..._clients]) {
      await c.socket.close();
    }
    _discovery?.close();
    _discovery = null;
    await _server?.close(force: true);
    _server = null;
    port = null;
  }

  void _save() {
    if (!persist) return;
    settings
        .writeAsString(
          jsonEncode({
            'enabled': enabled,
            'id': id,
            'devices': [
              for (final d in devices)
                {'id': d.id, 'name': d.name, 'token': d.token},
            ],
          }),
        )
        .catchError((Object e) {
          debugPrint('saving cast settings: $e');
          return settings;
        });
  }

  void _onDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _discovery?.receive();
    if (datagram == null || port == null) return;
    try {
      final message = jsonDecode(utf8.decode(datagram.data));
      if (message is! Map || message['halcyn'] != 'discover') return;
      if (message['id'] == id) return; // this device's own sender
      _discovery?.send(
        utf8.encode(
          jsonEncode({'halcyn': 'here', 'id': id, 'name': name, 'port': port}),
        ),
        datagram.address,
        datagram.port,
      );
    } on Object {
      // Not ours.
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments case ['ws']) return await _accept(request);
      if (_authorized(request) == null) {
        return _reply(request, HttpStatus.unauthorized);
      }
      switch ((request.method, segments)) {
        case ('PUT', ['file', final name]) when castFileName.hasMatch(name):
          await _receive(request, File('${castDir.path}/$name'), 1 << 30);
          _arrived('${castDir.path}/$name');
        case ('PUT', ['art', final name]) when artFileName.hasMatch(name):
          await _receive(request, File('$artDir/$name'), 32 << 20);
          _artArrived(name.substring(0, 16));
        case ('GET', ['art', final name]) when artFileName.hasMatch(name):
          await _send(request, File('$artDir/$name'));
        case ('GET', ['lyrics']):
          // Only for what's queued, so it can't be used to read other files.
          final path = request.uri.queryParameters['path'];
          if (path == null || !player.queue.any((t) => t.path == path)) {
            return _reply(request, HttpStatus.notFound);
          }
          await _send(request, File(lyricsPath(path)));
        default:
          _reply(request, HttpStatus.notFound);
      }
    } on Object catch (e) {
      debugPrint('cast request ${request.uri.path}: $e');
      try {
        _reply(request, HttpStatus.internalServerError);
      } on Object {
        // Already answered.
      }
    }
  }

  PairedDevice? _authorized(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || !header.startsWith('Bearer ')) return null;
    final token = header.substring(7);
    return devices.where((d) => d.token == token).firstOrNull;
  }

  void _reply(HttpRequest request, int status) {
    request.response.statusCode = status;
    request.response.close();
  }

  Future<void> _send(HttpRequest request, File file) async {
    if (!await file.exists()) return _reply(request, HttpStatus.notFound);
    request.response.headers.contentLength = await file.length();
    await request.response.addStream(file.openRead());
    await request.response.close();
  }

  /// Stores the request's body as `file`, unless it's already there. Written beside it
  /// first, so a half-sent file never looks finished.
  Future<void> _receive(HttpRequest request, File file, int limit) async {
    if (await file.exists()) {
      await request.drain<void>();
      return _reply(request, HttpStatus.ok);
    }
    if (request.contentLength < 0 || request.contentLength > limit) {
      return _reply(request, HttpStatus.requestEntityTooLarge);
    }
    await file.parent.create(recursive: true);
    final part = File('${file.path}.${randomHex(4)}.part');
    final sink = part.openWrite();
    var received = 0;
    try {
      await for (final chunk in request) {
        received += chunk.length;
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    if (received != request.contentLength) {
      await part.delete();
      return _reply(request, HttpStatus.badRequest);
    }
    await part.rename(file.path);
    _reply(request, HttpStatus.ok);
  }

  Future<void> _accept(HttpRequest request) async {
    final query = request.uri.queryParameters;
    final deviceId = query['device'] ?? '';
    final deviceName = (query['name'] ?? '').trim();
    if (!RegExp(r'^[0-9a-f]{16,64}$').hasMatch(deviceId)) {
      return _reply(request, HttpStatus.badRequest);
    }
    final socket = await WebSocketTransformer.upgrade(request);
    socket.pingInterval = const Duration(seconds: 5);
    final client = _Client(socket);
    socket.listen(
      (data) => _onMessage(client, data),
      onDone: () => _drop(client),
      onError: (_) => _drop(client),
    );

    var device = devices
        .where((d) => d.id == deviceId && d.token == query['token'])
        .firstOrNull;
    if (device == null) {
      if (requests.length >= 3) {
        client.send({'t': 'denied'});
        return socket.close();
      }
      client.send({'t': 'pairing', 'name': name});
      final request = PairingRequest(
        deviceName.isEmpty ? 'A device' : deviceName,
      );
      requests.add(request);
      notifyListeners();
      final allowed = await Future.any([
        request._answer.future,
        socket.done.then((_) => false),
      ]);
      request.answer(false);
      requests.remove(request);
      notifyListeners();
      if (!allowed || socket.closeCode != null) {
        client.send({'t': 'denied'});
        return socket.close();
      }
      devices.removeWhere((d) => d.id == deviceId);
      device = PairedDevice(deviceId, request.name, randomHex(24));
      devices.add(device);
      _save();
      client.send({'t': 'paired', 'token': device.token});
    } else if (deviceName.isNotEmpty && device.name != deviceName) {
      device.name = deviceName;
      _save();
    }
    client.device = device;
    _clients.add(client);
    notifyListeners();
    client.send({'t': 'hello', 'id': id, 'name': name});
    _sendState(client);
  }

  void _drop(_Client client) {
    if (!_clients.remove(client)) return;
    _updateSpectrum();
    notifyListeners();
  }

  void _onMessage(_Client client, Object? data) {
    if (client.device == null || data is! String) return;
    try {
      final message = jsonDecode(data) as Map;
      switch (message['t']) {
        case 'cmd':
          _command(message['op'] as String, message);
        case 'play':
          _play(client, message);
        case 'spectrum':
          client.spectrum = message['on'] == true;
          _updateSpectrum();
      }
    } on Object catch (e) {
      debugPrint('cast message: $e');
    }
  }

  void _command(String op, Map args) {
    int arg(String key) => (args[key] as num).toInt();
    final length = player.queue.length;
    switch (op) {
      case 'toggle':
        player.toggle();
      case 'play':
        player.play();
      case 'pause':
        player.pause();
      case 'next':
        player.next();
      case 'previous':
        player.previous();
      case 'seek':
        player.seek((args['secs'] as num).toDouble());
      case 'jump':
        player.jumpTo(arg('index'));
      case 'remove':
        player.removeAt(arg('index'));
      case 'move':
        final from = arg('from'), to = arg('to');
        if (from >= 0 && from < length && to >= 0 && to < length) {
          player.move(from, to);
        }
      case 'clearUpNext':
        if (player.current != null) player.clearUpNext();
      case 'shuffle':
        player.toggleShuffle();
      case 'repeat':
        player.setRepeat(Repeat.values.byName(args['mode'] as String));
      case 'volume':
        sound.setVolume((args['value'] as num).toDouble().clamp(0, 1));
      case 'mute':
        sound.toggleMute();
    }
  }

  /// Songs from the sender: this device's own copy where it has one at least as good,
  /// otherwise the sender's file, which it's asked to send.
  void _play(_Client client, Map message) {
    final items = (message['tracks'] as List).cast<Map>();
    if (items.isEmpty) return;
    final matcher = TrackMatcher(library.tracks);
    final tracks = <Track>[];
    final missing = <int>[];
    final art = <String>{};
    for (final json in items) {
      final sent = trackFromJson(json, id: -1, art: json['art'] as String?);
      final name = json['cast'] as String;
      if (!castFileName.hasMatch(name)) return;
      if (matcher.match(sent) case final own?) {
        tracks.add(own);
        _sentAs[own.path] = name;
        continue;
      }
      final path = '${castDir.path}/$name';
      final key = sent.art;
      final hasArt = key != null && _hasArt(key);
      if (key != null && !hasArt) {
        art.add(key);
        _artFor[path] = key;
      }
      tracks.add(
        trackFromJson(
          json,
          id: -1 - int.parse(name.substring(0, 12), radix: 16),
          path: path,
          art: hasArt ? key : null,
        ),
      );
      final file = File(path);
      if (file.existsSync()) {
        // Recently used: kept when the cache is trimmed.
        file.setLastModifiedSync(DateTime.now());
      } else {
        missing.add(tracks.length - 1);
      }
    }

    final mode = message['mode'] as String? ?? 'replace';
    final replace = mode == 'replace' || player.current == null;
    final start = replace
        ? (message['start'] as num? ?? 0).toInt().clamp(0, tracks.length - 1)
        : 0;
    // What plays first is sent first.
    missing.sort(
      (a, b) => (a < start ? a + tracks.length : a).compareTo(
        b < start ? b + tracks.length : b,
      ),
    );
    if (missing.isNotEmpty || art.isNotEmpty) {
      client.send({
        't': 'need',
        'files': [for (final i in missing) tracks[i].path.split('/').last],
        'art': art.toList(),
      });
    }

    void go() => switch (mode) {
      _ when replace => player.playTracks(tracks, start),
      'next' => player.playNext(tracks),
      _ => player.addToQueue(tracks),
    };
    final first = tracks[start].path;
    if (replace && !File(first).existsSync()) {
      _deferred = (first, go);
      _schedule();
    } else {
      _deferred = null;
      go();
    }
  }

  /// A sent song finished arriving: play it if it was being waited for.
  void _arrived(String path) {
    if (_deferred case (final waiting, final go) when waiting == path) {
      _deferred = null;
      go();
    } else if (player.current?.path == path && player.error != null) {
      // The queue reached it before it got here.
      player.jumpTo(player.index);
    }
    _schedule();
  }

  bool _hasArt(String key) => const [
    '128',
    '512',
    'full',
  ].every((size) => File('$artDir/$key-$size.jpg').existsSync());

  void _artArrived(String key) {
    if (!_hasArt(key)) return;
    final paths = {
      for (final MapEntry(key: path, value: k) in _artFor.entries)
        if (k == key) path,
    };
    if (paths.isEmpty) return;
    _artFor.removeWhere((path, _) => paths.contains(path));
    player.updateTracks(
      (t) => paths.contains(t.path) ? copyTrack(t, art: key) : t,
    );
  }

  void _schedule() {
    final current = player.current;
    // The queue reached a song that hasn't arrived: ask for it first.
    if (player.error != null &&
        current != null &&
        current.path.startsWith(castDir.path) &&
        current.path != _urged &&
        !File(current.path).existsSync()) {
      _urged = current.path;
      for (final c in _clients) {
        c.send({
          't': 'need',
          'files': [current.path.split('/').last],
          'urgent': true,
        });
      }
    }
    _stateTimer ??= Timer(const Duration(milliseconds: 30), () {
      _stateTimer = null;
      for (final c in _clients) {
        _sendState(c);
      }
    });
  }

  void _sendState(_Client client) {
    final queueChanged = !identical(client.sentQueue, player.queue);
    client.sentQueue = player.queue;
    final waiting = _deferred != null;
    client.send({
      't': 'state',
      if (queueChanged)
        'queue': [
          for (final t in player.queue)
            {
              ...trackToJson(t),
              'cast': t.path.startsWith('${castDir.path}/')
                  ? t.path.split('/').last
                  : _sentAs[t.path],
            },
        ],
      'index': player.index,
      'playing': player.playing,
      'shuffle': player.shuffle,
      'repeat': player.repeat.name,
      'signal': switch (player.signalPath) {
        final p? => signalPathToJson(p),
        null => null,
      },
      // While the first song is on its way, the engine's error is about the old queue.
      'error': waiting ? null : player.error,
      'waiting': waiting,
      'volume': sound.volume,
      'position': player.position.value,
    });
    _sentPosition = player.position.value;
    _positionClock
      ..reset()
      ..start();
  }

  void _onPosition() {
    if (_clients.isEmpty) return;
    final secs = player.position.value;
    if (_positionClock.elapsedMilliseconds < 250 &&
        (secs - _sentPosition).abs() < 1) {
      return;
    }
    _sentPosition = secs;
    _positionClock
      ..reset()
      ..start();
    for (final c in _clients) {
      c.send({'t': 'pos', 'secs': secs});
    }
  }

  /// Band levels for the senders showing a visualizer, as one byte each.
  void _updateSpectrum() {
    final wanted = _clients.any((c) => c.spectrum);
    if (wanted && _spectrum == null) {
      _spectrum = localSpectrum.listen((bands) {
        final bytes = Uint8List(bands.length);
        for (var i = 0; i < bands.length; i++) {
          bytes[i] = (bands[i].clamp(0, 1) * 255).round();
        }
        for (final c in _clients) {
          if (c.spectrum) c.socket.add(bytes);
        }
      });
    } else if (!wanted) {
      _spectrum?.cancel();
      _spectrum = null;
    }
  }

  /// Drops unfinished files, songs unused for 30 days, and the oldest songs beyond 4 GB.
  Future<void> _cleanCache() async {
    if (!await castDir.exists()) return;
    final files = <(File, FileStat)>[];
    await for (final entry in castDir.list()) {
      if (entry is! File) continue;
      if (entry.path.endsWith('.part')) {
        await entry.delete();
      } else {
        files.add((entry, await entry.stat()));
      }
    }
    files.sort((a, b) => b.$2.modified.compareTo(a.$2.modified));
    final queued = {for (final t in player.queue) t.path};
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    var total = 0;
    for (final (file, stat) in files) {
      total += stat.size;
      if (queued.contains(file.path)) continue;
      if (stat.modified.isBefore(cutoff) || total > 4 << 30) {
        await file.delete();
      }
    }
  }

  @override
  void dispose() {
    _stop();
    _stateTimer?.cancel();
    super.dispose();
  }
}

class _Client {
  _Client(this.socket);

  final WebSocket socket;
  PairedDevice? device;
  List<Track>? sentQueue;
  bool spectrum = false;

  void send(Map<String, Object?> message) {
    if (socket.closeCode == null) socket.add(jsonEncode(message));
  }
}
