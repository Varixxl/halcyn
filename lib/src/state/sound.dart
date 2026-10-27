import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../rust/api/sound.dart';

/// A headphone correction from AutoEq (assets/eq/headphones.json).
class Headphone {
  const Headphone(this.id, this.name, this.kind, this.source, this.filters);

  final String id;
  final String name;

  /// over-ear, on-ear, in-ear or earbud.
  final String kind;

  /// Who measured it.
  final String source;
  final List<EqFilter> filters;

  bool get earbuds => kind == 'in-ear' || kind == 'earbud';
}

/// The 10 bands' centres, an octave apart.
const eqBands = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

/// How far a band, bass or treble goes either way, in dB.
const eqRange = 12.0;

/// Band presets: gains for the 10 bands.
const Map<String, (String, List<double>)> eqPresets = {
  'flat': ('Flat', [0.0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  'bass': ('Bass boost', [5.0, 4.5, 3.5, 1.5, 0, 0, 0, 0, 0, 0]),
  'warm': ('Warm', [2.0, 2, 1.5, 1, 0, 0, -0.5, -1, -1.5, -2]),
  'vocal': ('Vocal', [-2.0, -2, -1, 0, 1.5, 2.5, 2.5, 1.5, 0, -1]),
  'bright': ('Bright', [0.0, 0, 0, 0, 0, 0, 1, 2.5, 3.5, 4]),
  'v': ('V-shape', [4.0, 3.5, 2, 0, -1, -1, 0, 1.5, 3, 3.5]),
};

/// Volume and the equalizer: a correction for your headphones, 10 bands, and bass and
/// treble shelves. Changes are heard at once and saved in `<app support>/sound.json`.
class SoundController extends ChangeNotifier {
  SoundController(this._file, {this.persist = true});

  final File _file;

  /// False while testing, so the real settings are read but never overwritten.
  final bool persist;
  Timer? _saveTimer;

  List<Headphone> headphones = const [];
  final List<double> curveFreqs = soundCurveFreqs();

  /// The slider position, 0..1; the gain is its cube, so it sounds even all the way down.
  double volume = 1;

  /// Where the volume was before muting.
  double _unmuted = 1;
  bool eq = false;
  String? headphone;
  String preset = 'flat';
  List<double> bands = List.filled(10, 0);
  double bass = 0;
  double treble = 0;

  /// Semitones up or down, without changing the speed.
  double pitch = 0;

  /// Times as fast, without changing the pitch.
  double speed = 1;

  /// What's heard: a slider being dragged moves [pitch] and [speed] only, since each
  /// change starts the song again from where it is.
  double _heardPitch = 0;
  double _heardSpeed = 1;

  static const maxPitch = 12.0;
  static const minSpeed = 0.5;
  static const maxSpeed = 2.0;

  /// What the EQ does, from the engine.
  double preampDb = 0;
  List<double> curve = const [];

  Headphone? get correction =>
      headphones.where((h) => h.id == headphone).firstOrNull;

  bool get muted => volume == 0;

  Future<void> load() async {
    try {
      final json = jsonDecode(
        await rootBundle.loadString('assets/eq/headphones.json'),
      ) as Map<String, dynamic>;
      headphones = [
        for (final h in json['headphones'] as List)
          Headphone(
            h['id'] as String,
            h['name'] as String,
            h['kind'] as String,
            h['source'] as String,
            [
              for (final f in h['filters'] as List)
                EqFilter(
                  kind: switch (f[0]) {
                    'ls' => EqFilterKind.lowShelf,
                    'hs' => EqFilterKind.highShelf,
                    _ => EqFilterKind.peak,
                  },
                  hz: (f[1] as num).toDouble(),
                  gainDb: (f[2] as num).toDouble(),
                  q: (f[3] as num).toDouble(),
                ),
            ],
          ),
      ];
    } on Object catch (e) {
      debugPrint('headphone presets: $e');
    }
    try {
      final saved = jsonDecode(await _file.readAsString()) as Map;
      volume = (saved['volume'] as num? ?? 1).toDouble().clamp(0, 1);
      _unmuted = (saved['unmuted'] as num? ?? 1).toDouble();
      eq = saved['eq'] == true;
      headphone = saved['headphone'] as String?;
      preset = saved['preset'] as String? ?? 'flat';
      bands = [
        for (final g in (saved['bands'] as List? ?? const []))
          (g as num).toDouble(),
      ];
      if (bands.length != 10) bands = List.filled(10, 0);
      bass = (saved['bass'] as num? ?? 0).toDouble();
      treble = (saved['treble'] as num? ?? 0).toDouble();
      pitch = _heardPitch = _pitchStep(
        (saved['pitch'] as num? ?? 0).toDouble(),
      );
      speed = _heardSpeed = _speedStep(
        (saved['speed'] as num? ?? 1).toDouble(),
      );
    } on Object {
      // First run: full volume, EQ off.
    }
    _apply(save: false);
  }

  void setVolume(double value) {
    volume = value.clamp(0, 1);
    if (volume > 0) _unmuted = volume;
    _apply();
  }

  void toggleMute() => setVolume(muted ? (_unmuted > 0 ? _unmuted : 1) : 0);

  void setEq(bool on) {
    eq = on;
    _apply();
  }

  /// A headphone correction, or null for none. Turns the EQ on.
  void setHeadphone(String? id) {
    headphone = id;
    eq = true;
    _apply();
  }

  void setBass(double db) {
    bass = _step(db);
    eq = true;
    _apply();
  }

  void setTreble(double db) {
    treble = _step(db);
    eq = true;
    _apply();
  }

  void setBand(int i, double db) {
    bands = [...bands]..[i] = _step(db);
    preset = 'custom';
    eq = true;
    _apply();
  }

  void setPreset(String key) {
    final gains = eqPresets[key]?.$2;
    if (gains == null) return;
    preset = key;
    bands = [...gains];
    eq = true;
    _apply();
  }

  /// [live] false while a slider is dragged: shown, and heard once it's let go.
  void setPitch(double semitones, {bool live = true}) {
    pitch = _pitchStep(semitones);
    live ? _hear() : notifyListeners();
  }

  /// [live] as for [setPitch].
  void setSpeed(double times, {bool live = true}) {
    speed = _speedStep(times);
    live ? _hear() : notifyListeners();
  }

  /// Both as shown, so a button pressed mid-drag can't leave one behind.
  void _hear() {
    _heardPitch = pitch;
    _heardSpeed = speed;
    _apply();
  }

  bool get tempoChanged => pitch != 0 || speed != 1;

  /// Pitch and speed back to normal.
  void resetTempo() {
    pitch = _heardPitch = 0;
    speed = _heardSpeed = 1;
    _apply();
  }

  static double _pitchStep(double semitones) =>
      (semitones.clamp(-maxPitch, maxPitch) * 2).round() / 2;

  static double _speedStep(double times) =>
      (times.clamp(minSpeed, maxSpeed) * 20).round() / 20;

  /// Bands, bass and treble back to flat; the headphone correction stays.
  void reset() {
    preset = 'flat';
    bands = List.filled(10, 0);
    bass = 0;
    treble = 0;
    _apply();
  }

  static double _step(double db) =>
      (db.clamp(-eqRange, eqRange) * 2).round() / 2;

  List<EqFilter> get _filters => [
    ...?correction?.filters,
    for (final (i, hz) in eqBands.indexed)
      EqFilter(
        kind: EqFilterKind.peak,
        hz: hz.toDouble(),
        gainDb: bands[i],
        q: 1.41,
      ),
    EqFilter(kind: EqFilterKind.lowShelf, hz: 100, gainDb: bass, q: 0.71),
    EqFilter(kind: EqFilterKind.highShelf, hz: 8000, gainDb: treble, q: 0.71),
  ];

  void _apply({bool save = true}) {
    final info = soundSet(
      settings: SoundSettings(
        volume: volume * volume * volume,
        eq: eq,
        filters: _filters,
        pitch: _heardPitch,
        speed: _heardSpeed,
      ),
    );
    preampDb = info.preampDb;
    curve = info.curve;
    notifyListeners();
    if (save && persist) _save();
  }

  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () async {
      try {
        await _file.writeAsString(
          jsonEncode({
            'volume': volume,
            'unmuted': _unmuted,
            'eq': eq,
            'headphone': headphone,
            'preset': preset,
            'bands': bands,
            'bass': bass,
            'treble': treble,
            'pitch': _heardPitch,
            'speed': _heardSpeed,
          }),
        );
      } on Object catch (e) {
        debugPrint('saving sound settings: $e');
      }
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}
