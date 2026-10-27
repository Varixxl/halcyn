import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../rust/api/library.dart';
import '../rust/api/player.dart';
import '../state/library.dart';
import '../state/player.dart';
import '../state/spectrum.dart';
import 'protocol.dart';

/// A Halcyn that can be cast to.
class CastDevice {
  CastDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
  });

  /// Empty until it says hello, for a device added by its address.
  String id;
  String name;
  String host;
  int port;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
  };
}

enum CastStatus { idle, connecting, approving, connected }

/// Casting from this device: finding other Halcyns, connecting, and while connected,
/// standing in for the engine (see [RemotePlayer]). Songs the other device doesn't have
/// are sent to it as it asks for them.
class CastController extends ChangeNotifier implements RemotePlayer {
  CastController({
    required this.player,
    required this.artDir,
    required this.settings,
    required this.receiverId,
    this.persist = true,
  });

  final PlayerController player;
  final String artDir;
  final File settings;

  /// This device's own receiver, which mustn't answer its own search.
  final String Function() receiverId;
  final bool persist;

  /// How this device introduces itself.
  String id = randomHex(8);
  String name = Platform.localHostname;

  /// Approvals from devices cast to before, by their id.
  Map<String, String> _tokens = {};

  /// Devices connected to before, newest first.
  List<CastDevice> known = [];

  /// Devices that answered the last search.
  List<CastDevice> found = [];
  bool searching = false;

  CastDevice? device;
  CastStatus status = CastStatus.idle;
  String? error;

  /// The other device's volume, 0..1.
  double volume = 1;
  double _unmuted = 1;

  /// True while the other device waits for the first song of a new queue.
  bool waiting = false;

  /// The song being sent, and how far along.
  String? sending;
  double sendProgress = 0;

  bool get connected => status == CastStatus.connected;

  /// Every device to offer, found ones first.
  List<CastDevice> get devices => [
    ...found,
    ...known.where((k) => !found.any((f) => f.id == k.id)),
  ];

  WebSocket? _socket;
  bool _leaving = false;
  int _attempt = 0;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);

  /// Songs this device sent, by cast name, so the other device's queue shows them as
  /// this device's own (with their own covers and play counts).
  final _sent = <String, Track>{};
  List<Map>? _remoteQueue;

  final _uploads = <String>[];
  final _artUploads = <String>{};
  bool _uploading = false;

  final _artFetches = <String>{};
  final _artFailed = <String>{};
  bool _fetching = false;

  late final _bands = StreamController<Float32List>.broadcast(
    onListen: () => _send({'t': 'spectrum', 'on': true}),
    onCancel: () => _send({'t': 'spectrum', 'on': false}),
  );

  Future<void> load({String? deviceName}) async {
    if (deviceName != null && deviceName.isNotEmpty) name = deviceName;
    try {
      final saved = jsonDecode(await settings.readAsString()) as Map;
      id = saved['id'] as String? ?? id;
      _tokens = (saved['tokens'] as Map? ?? const {}).cast<String, String>();
      known = [
        for (final d in saved['known'] as List? ?? const [])
          CastDevice(
            id: d['id'] as String,
            name: d['name'] as String,
            host: d['host'] as String,
            port: d['port'] as int,
          ),
      ];
    } on Object {
      // Nothing saved yet.
    }
  }

  void _save() {
    if (!persist) return;
    settings
        .writeAsString(
          jsonEncode({
            'id': id,
            'tokens': _tokens,
            'known': [for (final d in known) d.toJson()],
          }),
        )
        .catchError((Object e) {
          debugPrint('saving cast settings: $e');
          return settings;
        });
  }

  /// Asks the network who's there, for a couple of seconds.
  Future<void> search() async {
    if (searching) return;
    searching = true;
    found = [];
    notifyListeners();
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)
        ..broadcastEnabled = true;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket?.receive();
        if (datagram == null) return;
        try {
          final m = jsonDecode(utf8.decode(datagram.data)) as Map;
          if (m['halcyn'] != 'here') return;
          final id = m['id'] as String;
          found.removeWhere((d) => d.id == id);
          found.add(
            CastDevice(
              id: id,
              name: m['name'] as String,
              host: datagram.address.address,
              port: m['port'] as int,
            ),
          );
          // A device that moved to another address.
          for (final k in known.where((k) => k.id == id)) {
            k.host = datagram.address.address;
            k.port = m['port'] as int;
          }
          notifyListeners();
        } on Object {
          // Not ours.
        }
      });
      final message = utf8.encode(
        jsonEncode({'halcyn': 'discover', 'id': receiverId()}),
      );
      final targets = {'255.255.255.255'};
      for (final interface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )) {
        for (final address in interface.addresses) {
          if (address.isLoopback) continue;
          // Most home networks are /24.
          final parts = address.address.split('.')..[3] = '255';
          targets.add(parts.join('.'));
        }
      }
      final port = castPort('HALCYN_CAST_DISCOVERY_PORT', discoveryPort);
      for (var i = 0; i < 3; i++) {
        for (final target in targets) {
          try {
            socket.send(message, InternetAddress(target), port);
          } on Object {
            // That network doesn't allow it; the others may.
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    } on Object catch (e) {
      debugPrint('cast search: $e');
    } finally {
      socket?.close();
      searching = false;
      notifyListeners();
    }
  }

  /// Connects to `host` or `host:port`, for networks where searching doesn't work.
  Future<void> connectTo(String address) async {
    final text = address.trim();
    final colon = text.lastIndexOf(':');
    final host = colon > 0 ? text.substring(0, colon) : text;
    final port = colon > 0
        ? int.tryParse(text.substring(colon + 1))
        : defaultPort;
    if (host.isEmpty || port == null) {
      error = 'That isn\'t an address, e.g. 192.168.1.20';
      return notifyListeners();
    }
    final remembered = known
        .where((k) => k.host == host && k.port == port)
        .firstOrNull;
    await connect(
      remembered ?? CastDevice(id: '', name: host, host: host, port: port),
    );
  }

  Future<void> connect(CastDevice target) async {
    if (device == target && status != CastStatus.idle) return;
    await _close();
    device = target;
    status = CastStatus.connecting;
    error = null;
    _attempt = 0;
    notifyListeners();
    await _open();
  }

  Future<void> _open() async {
    final target = device;
    if (target == null) return;
    final uri = Uri(
      scheme: 'ws',
      host: target.host,
      port: target.port,
      path: '/ws',
      queryParameters: {
        'device': id,
        'name': name,
        'token': ?_tokens[target.id],
      },
    );
    try {
      final socket = await WebSocket.connect(uri.toString())
          .timeout(const Duration(seconds: 5));
      if (device != target) return await socket.close();
      _socket = socket..pingInterval = const Duration(seconds: 5);
      socket.listen(
        _onMessage,
        onDone: () => _onClosed(socket),
        onError: (_) => _onClosed(socket),
      );
    } on Object {
      _onClosed(null);
    }
  }

  /// Stops casting; this device's own queue comes back, paused.
  Future<void> disconnect() async {
    await _close();
    device = null;
    status = CastStatus.idle;
    notifyListeners();
  }

  Future<void> _close() async {
    _leaving = true;
    await _socket?.close();
    _socket = null;
    _leaving = false;
    _stopCasting();
  }

  void _stopCasting() {
    if (!player.casting) return;
    player.stopCasting();
    remoteSpectrum.value = null;
    _remoteQueue = null;
    _uploads.clear();
    _artUploads.clear();
    waiting = false;
  }

  void _onClosed(WebSocket? socket) {
    if (_leaving || socket != _socket) return;
    _socket = null;
    final target = device;
    if (target == null) return;
    if (status == CastStatus.connected && _attempt < 3) {
      // A blip, e.g. Wi-Fi roaming: keep showing its state while trying again.
      final delay = Duration(seconds: 1 << _attempt++);
      Timer(delay, () {
        if (device == target && _socket == null) _open();
      });
      return;
    }
    _stopCasting();
    error = switch (status) {
      CastStatus.connected => 'Lost the connection to ${target.name}.',
      CastStatus.approving => '${target.name} didn\'t allow it.',
      _ =>
        'Couldn\'t reach ${target.name}. Is Halcyn open on it, with casting on in '
            'its Settings, and on the same network?',
    };
    status = CastStatus.idle;
    device = null;
    notifyListeners();
  }

  void _send(Map<String, Object?> message) {
    if (_socket case final socket? when status == CastStatus.connected) {
      socket.add(jsonEncode(message));
    }
  }

  void _onMessage(Object? data) {
    if (data is List<int>) {
      _bands.add(Float32List.fromList([for (final b in data) b / 255]));
      return;
    }
    if (data is! String) return;
    try {
      final m = jsonDecode(data) as Map;
      switch (m['t']) {
        case 'pairing':
          status = CastStatus.approving;
          notifyListeners();
        case 'paired':
          _pendingToken = m['token'] as String;
        case 'denied':
          status = CastStatus.approving; // _onClosed explains
        case 'hello':
          _hello(m);
        case 'state':
          _state(m);
        case 'pos':
          player.remotePosition((m['secs'] as num).toDouble());
        case 'need':
          _need(m);
      }
    } on Object catch (e) {
      debugPrint('cast message: $e');
    }
  }

  /// A token from approval, kept until hello says whose it is.
  String? _pendingToken;

  void _hello(Map m) {
    final target = device!;
    target
      ..id = m['id'] as String
      ..name = m['name'] as String;
    if (_pendingToken case final token?) _tokens[target.id] = token;
    _pendingToken = null;
    known
      ..removeWhere((k) => k.id == target.id)
      ..insert(0, target);
    _save();
    status = CastStatus.connected;
    error = null;
    _attempt = 0;
    player.startCasting(this);
    remoteSpectrum.value = () => _bands.stream;
    if (_bands.hasListener) _send({'t': 'spectrum', 'on': true});
    // The queue is sent in full to a new connection.
    _remoteQueue = null;
    notifyListeners();
    _pumpUploads();
  }

  void _state(Map m) {
    if (m['queue'] case final List queue) _remoteQueue = queue.cast<Map>();
    final volume = (m['volume'] as num).toDouble();
    final waiting = m['waiting'] == true;
    if (volume != this.volume || waiting != this.waiting) {
      this.volume = volume;
      this.waiting = waiting;
      notifyListeners();
    }
    player.applyRemote(
      queue: m.containsKey('queue') ? _mirrorQueue() : null,
      index: m['index'] as int,
      playing: m['playing'] as bool,
      shuffle: m['shuffle'] as bool,
      repeat: Repeat.values.byName(m['repeat'] as String),
      signalPath: switch (m['signal']) {
        final Map signal => signalPathFromJson(signal),
        _ => null,
      },
      error: m['error'] as String?,
    );
    player.remotePosition((m['position'] as num).toDouble());
    if (_artFetches.isNotEmpty) {
      // The cover on screen first.
      final now = player.current?.path;
      final first = _remoteQueue
          ?.where((json) => json['path'] == now)
          .firstOrNull?['art'];
      if (first is String && _artFetches.remove(first)) {
        final rest = [..._artFetches];
        _artFetches
          ..clear()
          ..add(first)
          ..addAll(rest);
      }
      _fetchArt();
    }
  }

  /// The other device's queue as tracks here: this device's own where it sent them,
  /// otherwise with covers once they've been fetched.
  List<Track> _mirrorQueue() {
    final queue = _remoteQueue ?? const [];
    return [
      for (final json in queue)
        if (_sent[json['cast']] case final own?) own else _mirror(json),
    ];
  }

  Track _mirror(Map json) {
    final path = json['path'] as String;
    final art = json['art'] as String?;
    final hasArt = art != null && _hasArt(art);
    if (art != null && !hasArt && !_artFailed.contains(art)) {
      _artFetches.add(art);
    }
    return trackFromJson(
      json,
      id: -1 - int.parse(fnv1a(path).substring(0, 12), radix: 16),
      art: hasArt ? art : null,
    );
  }

  bool _hasArt(String key) => const [
    '128',
    '512',
    'full',
  ].every((size) => File('$artDir/$key-$size.jpg').existsSync());

  @override
  void command(String op, [Map<String, Object?> args = const {}]) =>
      _send({'t': 'cmd', 'op': op, ...args});

  @override
  void play(List<Track> tracks, int start, String mode) {
    if (tracks.isEmpty) return;
    for (final t in tracks) {
      _sent[castName(t)] = t;
    }
    _send({
      't': 'play',
      'mode': mode,
      'start': start,
      'tracks': [
        for (final t in tracks) {...trackToJson(t), 'cast': castName(t)},
      ],
    });
  }

  void setVolume(double value) {
    volume = value.clamp(0, 1);
    if (volume > 0) _unmuted = volume;
    notifyListeners();
    command('volume', {'value': volume});
  }

  void toggleMute() => setVolume(volume == 0 ? _unmuted : 0);

  /// Lyrics for a song on the other device, which has the `.lrc` file.
  Future<String?> lyrics(String path) async {
    final target = device;
    final token = _tokens[target?.id];
    if (!connected || target == null || token == null) return null;
    try {
      final request = await _http.getUrl(
        Uri(
          scheme: 'http',
          host: target.host,
          port: target.port,
          path: '/lyrics',
          queryParameters: {'path': path},
        ),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      return await response.transform(utf8.decoder).join();
    } on Object {
      return null;
    }
  }

  void _need(Map m) {
    final files = (m['files'] as List? ?? const []).cast<String>();
    // Newest request first: it's what's about to play.
    _uploads
      ..removeWhere(files.contains)
      ..insertAll(0, files);
    _artUploads.addAll((m['art'] as List? ?? const []).cast<String>());
    _pumpUploads();
  }

  Uri _uri(String path) =>
      Uri(scheme: 'http', host: device!.host, port: device!.port, path: path);

  /// Sends what the other device asked for, covers first, one at a time.
  Future<void> _pumpUploads() async {
    if (_uploading) return;
    _uploading = true;
    try {
      while (connected) {
        if (_artUploads.isNotEmpty) {
          final key = _artUploads.first;
          _artUploads.remove(key);
          for (final size in ['128', '512', 'full']) {
            await _put('/art/$key-$size.jpg', File('$artDir/$key-$size.jpg'));
          }
          continue;
        }
        if (_uploads.isEmpty) break;
        final name = _uploads.removeAt(0);
        final track = _sent[name];
        if (track == null || !File(track.path).existsSync()) continue;
        sending = track.title;
        sendProgress = 0;
        notifyListeners();
        final lyrics = File(lyricsPath(track.path));
        if (lyrics.existsSync()) {
          await _put('/file/${name.split('.').first}.lrc', lyrics);
        }
        await _put('/file/$name', File(track.path), progress: true);
      }
    } finally {
      _uploading = false;
      sending = null;
      notifyListeners();
    }
  }

  Future<void> _put(String path, File file, {bool progress = false}) async {
    final token = _tokens[device?.id];
    if (token == null || !file.existsSync()) return;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final length = await file.length();
        final request = await _http.openUrl('PUT', _uri(path));
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        request.contentLength = length;
        var sent = 0;
        var shown = 0.0;
        await request.addStream(
          file.openRead().map((chunk) {
            sent += chunk.length;
            if (progress && sent / length - shown >= 0.02) {
              shown = sendProgress = sent / length;
              notifyListeners();
            }
            return chunk;
          }),
        );
        final response = await request.close();
        await response.drain<void>();
        if (response.statusCode == HttpStatus.ok) return;
        debugPrint('cast upload $path: ${response.statusCode}');
      } on Object catch (e) {
        debugPrint('cast upload $path: $e');
      }
      if (!connected) return;
    }
  }

  /// Fetches covers of the other device's songs into this device's art cache, then
  /// shows them.
  Future<void> _fetchArt() async {
    if (_fetching) return;
    _fetching = true;
    try {
      while (connected && _artFetches.isNotEmpty) {
        final key = _artFetches.first;
        _artFetches.remove(key);
        var ok = true;
        for (final size in ['128', '512', 'full']) {
          ok &= await _get(
            '/art/$key-$size.jpg',
            File('$artDir/$key-$size.jpg'),
          );
        }
        if (!ok) {
          _artFailed.add(key);
          continue;
        }
        player.updateTracks(
          (t) => t.art == null && _artOf(t) == key ? copyTrack(t, art: key) : t,
        );
      }
    } finally {
      _fetching = false;
    }
  }

  String? _artOf(Track t) =>
      _remoteQueue?.where((json) => json['path'] == t.path).firstOrNull?['art']
          as String?;

  Future<bool> _get(String path, File file) async {
    if (file.existsSync()) return true;
    final token = _tokens[device?.id];
    if (token == null) return false;
    try {
      final request = await _http.getUrl(_uri(path));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return false;
      }
      final part = File('${file.path}.${randomHex(4)}.part');
      await response.pipe(part.openWrite());
      await part.rename(file.path);
      return true;
    } on Object catch (e) {
      debugPrint('cast art $path: $e');
      return false;
    }
  }

  @override
  void dispose() {
    _close();
    _http.close(force: true);
    _bands.close();
    super.dispose();
  }
}
