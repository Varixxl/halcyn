import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../rust/api/account.dart';
import '../rust/api/library.dart';
import '../rust/api/streaming.dart';
import 'library.dart';
import 'playlists.dart';
import 'streaming.dart';

/// The Halcyn account's server. The publishable key is public by design: row-level
/// security keeps every account to its own rows (supabase/migrations).
const supabaseUrl = 'https://mygklmsbbwprxxsebwes.supabase.co';
const supabaseKey = 'sb_publishable_m4RavGWdh269IPMoJuNvrg_eC70zO2R';

const minPasswordLength = 10;

/// The Halcyn account: signing in, and keeping the linked streaming services (in an
/// end-to-end encrypted vault, see rust/src/account.rs) and the playlists the same on
/// every device signed in to it.
class AccountController extends ChangeNotifier {
  AccountController({
    required this.library,
    required this.playlists,
    required this.streaming,
    required this.state,
    this.online = true,
    String keyPrefix = 'halcyn',
  }) : _keystore = _Keystore(keyPrefix);

  final LibraryController library;
  final PlaylistsController playlists;
  final StreamingController streaming;

  /// `account.json`: what was last synced, to tell which side changed since.
  final File state;

  /// False under test: no server.
  final bool online;

  /// Where the session and the vault key are kept (tests use their own).
  final _Keystore _keystore;

  SupabaseClient? _client;
  String? _vaultKey;

  /// Shown once after signing up, to write down.
  String? recoveryKey;

  /// Signed in, but this device doesn't have the vault key (it changed elsewhere):
  /// the password opens it again.
  bool locked = false;

  bool syncing = false;
  DateTime? lastSync;
  String? syncError;

  /// service → hash of the sign-in last synced. Playlist id → its sync record.
  Map<String, String> _services = {};
  Map<int, _Synced> _synced = {};
  Timer? _soon;
  Timer? _every;
  bool _again = false;

  User? get user => _client?.auth.currentUser;
  String? get email => user?.email;
  bool get signedIn => user != null;

  Future<void> load() async {
    if (!online) return;
    try {
      final json = jsonDecode(await state.readAsString()) as Map;
      _services = ((json['services'] as Map?) ?? {}).cast<String, String>();
      _synced = {
        for (final MapEntry(:key, :value)
            in ((json['playlists'] as Map?) ?? {}).entries)
          int.parse(key as String): _Synced.fromJson(value as Map),
      };
    } on Object {
      // Never synced here.
    }
    try {
      _client = Supabase.instance.client;
    } on Object {
      await Supabase.initialize(
        url: supabaseUrl,
        publishableKey: supabaseKey,
        authOptions: FlutterAuthClientOptions(
          localStorage: _SessionStorage(_keystore),
          pkceAsyncStorage: _PkceStorage(_keystore),
        ),
        debug: false,
      );
      _client = Supabase.instance.client;
    }
    final uid = user?.id;
    if (uid != null) {
      _vaultKey = await _keystore.read('vault_key.$uid');
      locked = _vaultKey == null;
      _start();
    }
    notifyListeners();
  }

  void _start() {
    playlists.addListener(_later);
    streaming.addListener(_later);
    _every ??= Timer.periodic(const Duration(minutes: 10), (_) => sync());
    unawaited(sync());
  }

  void _stop() {
    playlists.removeListener(_later);
    streaming.removeListener(_later);
    _every?.cancel();
    _every = null;
    _soon?.cancel();
  }

  /// Something changed here: sync a few seconds later, once edits settle.
  void _later() {
    // When each synced playlist was edited here, for "the newest wins".
    final now = DateTime.now().toUtc();
    for (final p in playlists.playlists) {
      final record = _synced[p.id];
      if (record != null &&
          record.changed == null &&
          _hashOf(p) != record.hash) {
        record.changed = now;
      }
    }
    _soon?.cancel();
    _soon = Timer(const Duration(seconds: 4), sync);
  }

  // ---- signing in ----

  static String? passwordProblem(String password) {
    if (password.length < minPasswordLength) {
      return 'Use at least $minPasswordLength characters. A few random words '
          'works well.';
    }
    if (password.split('').toSet().length < 5) {
      return 'That password is too easy to guess.';
    }
    return null;
  }

  Future<void> signUp(String email, String password) async {
    if (passwordProblem(password) case final problem?) {
      throw AccountException(problem);
    }
    final keys = await accountDerive(email: email, password: password);
    final res = await _auth.signUp(
      email: _normal(email),
      password: keys.loginSecret,
    );
    if (res.session == null) {
      throw const AccountException(
        'Check your email to confirm the account, then sign in.',
      );
    }
    await _newVault(keys.passwordKey);
    _signedIn();
  }

  Future<void> signIn(String email, String password) async {
    final keys = await accountDerive(email: email, password: password);
    await _auth.signInWithPassword(
      email: _normal(email),
      password: keys.loginSecret,
    );
    await _unlock(keys.passwordKey);
    _signedIn();
  }

  /// Opens the vault on a device that lost its key (the password changed elsewhere).
  Future<void> unlock(String password) async {
    final keys = await accountDerive(email: email!, password: password);
    await _unlock(keys.passwordKey);
    locked = false;
    notifyListeners();
    unawaited(sync());
  }

  Future<void> _unlock(String passwordKey) async {
    final vault = await _vault();
    if (vault == null) return _newVault(passwordKey);
    try {
      await _keepVaultKey(
        await accountUnwrap(
          passwordKey: passwordKey,
          wrapped: vault['key_by_password'] as String,
          userId: user!.id,
        ),
      );
    } on Object {
      throw const AccountException('Wrong password.');
    }
  }

  Future<void> _newVault(String passwordKey) async {
    final vault = await accountNewVault(
      passwordKey: passwordKey,
      userId: user!.id,
    );
    await _db.from('vaults').insert({
      'user_id': user!.id,
      'kdf': {'alg': 'argon2id', 'm': 65536, 't': 3, 'salt': 'email'},
      'key_by_password': vault.keyByPassword,
      'key_by_recovery': vault.keyByRecovery,
      'key_id': vault.keyId,
    });
    recoveryKey = vault.recoveryKey;
    await _keepVaultKey(vault.vaultKey);
  }

  Future<void> _keepVaultKey(String key) async {
    _vaultKey = key;
    await _keystore.write('vault_key.${user!.id}', key);
  }

  void _signedIn() {
    locked = false;
    // Another account's sync records mean nothing for this one.
    _services = {};
    _synced = {};
    notifyListeners();
    _start();
  }

  void forgetRecoveryKey() {
    recoveryKey = null;
    notifyListeners();
  }

  Future<void> changePassword(String current, String next) async {
    if (passwordProblem(next) case final problem?) {
      throw AccountException(problem);
    }
    final old = await accountDerive(email: email!, password: current);
    try {
      await _auth.signInWithPassword(email: email!, password: old.loginSecret);
    } on AuthException {
      throw const AccountException('Your current password is wrong.');
    }
    final keys = await accountDerive(email: email!, password: next);
    final vault = await _vault();
    final oldWrapped = vault!['key_by_password'];
    await _db
        .from('vaults')
        .update({
          'key_by_password': await accountWrap(
            passwordKey: keys.passwordKey,
            vaultKey: _vaultKey!,
            userId: user!.id,
          ),
        })
        .eq('user_id', user!.id);
    try {
      await _auth.updateUser(UserAttributes(password: keys.loginSecret));
    } on Object {
      // The old password still opens everything.
      await _db
          .from('vaults')
          .update({'key_by_password': oldWrapped})
          .eq('user_id', user!.id);
      rethrow;
    }
  }

  /// Signs out of the Halcyn account. The services stay linked on this device.
  Future<void> signOut() async {
    final uid = user?.id;
    _stop();
    if (uid != null) await _keystore.delete('vault_key.$uid');
    await _auth.signOut(scope: SignOutScope.local);
    _forget();
  }

  /// Deletes the account and everything saved in it (not what's on this device).
  Future<void> deleteAccount() async {
    final uid = user!.id;
    _stop();
    await _client!.rpc<void>('delete_account');
    await _keystore.delete('vault_key.$uid');
    try {
      await _auth.signOut(scope: SignOutScope.local);
    } on AuthException {
      // The session went with the account.
    }
    _forget();
  }

  void _forget() {
    _vaultKey = null;
    recoveryKey = null;
    locked = false;
    lastSync = null;
    syncError = null;
    _services = {};
    _synced = {};
    unawaited(_save());
    notifyListeners();
  }

  // ---- syncing ----

  /// Makes this device and the account agree: services, then playlists.
  Future<void> sync() async {
    if (!signedIn || locked || _vaultKey == null) return;
    if (syncing) {
      _again = true;
      return;
    }
    syncing = true;
    notifyListeners();
    try {
      do {
        _again = false;
        await _syncServices();
        await _syncPlaylists();
      } while (_again);
      lastSync = DateTime.now();
      syncError = null;
    } on Object catch (e) {
      syncError = describeAccountError(e);
      debugPrint('account sync: $e');
    } finally {
      syncing = false;
      await _save();
      notifyListeners();
    }
  }

  Future<void> _syncServices() async {
    final uid = user!.id;
    final rows = await _db
        .from('vault_items')
        .select('service, ciphertext')
        .eq('user_id', uid);
    final remote = {
      for (final r in rows)
        r['service'] as String: accountOpen(
          vaultKey: _vaultKey!,
          userId: uid,
          service: r['service'] as String,
          sealed: r['ciphertext'] as String,
        ),
    };
    var imported = false;
    for (final service in serviceNames.keys) {
      final here = await streamingExport(serviceName: service);
      final there = remote[service];
      final last = _services[service];
      final changedHere = _hash(here) != last;
      final changedThere = _hash(there) != last;
      if (changedHere && here != null) {
        await _db.from('vault_items').upsert({
          'user_id': uid,
          'service': service,
          'ciphertext': accountSeal(
            vaultKey: _vaultKey!,
            userId: uid,
            service: service,
            plain: here,
          ),
        });
        _services[service] = _hash(here)!;
      } else if (changedHere && last != null) {
        // Signed out here since: out of the account too.
        await _db
            .from('vault_items')
            .delete()
            .eq('user_id', uid)
            .eq('service', service);
        _services.remove(service);
      } else if (changedThere && there != null) {
        await streamingImport(serviceName: service, saved: there);
        _services[service] = _hash(there)!;
        imported = true;
      } else if (changedThere && here != null) {
        // Signed out on another device.
        await (service == 'tidal'
            ? streamingTidalSignOut()
            : streamingYoutubeSignOut());
        _services.remove(service);
        imported = true;
      }
    }
    if (imported) await streaming.refreshAccounts();
  }

  Future<void> _syncPlaylists() async {
    final uid = user!.id;
    final rows = await _db
        .from('playlists')
        .select('id, name, entries, deleted, updated_at')
        .eq('user_id', uid);
    final remote = {for (final r in rows) r['id'] as String: r};
    Map<int, Playlist> ownPlaylists() => {
      for (final p in playlists.playlists)
        // A playlist file in the music folders belongs to its device.
        if (p.source == null) p.id: p,
    };
    var local = ownPlaylists();

    // The account's playlists first: new ones, and changes from elsewhere.
    final byRemote = {for (final e in _synced.entries) e.value.id: e.key};
    for (final row in remote.values) {
      final id = row['id'] as String;
      final updated = row['updated_at'] as String;
      final localId = byRemote[id];
      final here = localId == null ? null : local[localId];
      final record = localId == null ? null : _synced[localId];
      if (row['deleted'] == true) {
        if (here != null) playlists.delete(here);
        if (localId != null) _synced.remove(localId);
        continue;
      }
      if (record != null && record.updated == updated) continue;
      if (here != null && _hashOf(here) != record!.hash) {
        // Changed on both sides: the newest wins.
        final remoteTime = DateTime.parse(updated);
        if (record.changed != null && record.changed!.isAfter(remoteTime)) {
          continue;
        }
      }
      final paths = await _resolve((row['entries'] as List).cast<Map>());
      final name = row['name'] as String;
      final Playlist playlist;
      if (here == null) {
        if (localId != null) {
          // Deleted here since it was last synced: the deletion goes up below.
          continue;
        }
        playlist = await playlists.create(name, paths);
      } else {
        playlist = playlists.replace(here, name: name, paths: paths);
      }
      _synced[playlist.id] = _Synced(id, _hashOf(playlist), updated);
    }

    // Then this device's: new ones, edits and deletions (including the ones just made).
    local = ownPlaylists();
    for (final p in local.values) {
      final record = _synced[p.id];
      final hash = _hashOf(p);
      if (record != null && record.hash == hash) continue;
      final id = record?.id ?? _uuid();
      final saved = await _db
          .from('playlists')
          .upsert({
            'user_id': uid,
            'id': id,
            'name': p.name,
            'entries': await _entries(p.paths),
            'deleted': false,
          })
          .select('updated_at')
          .single();
      _synced[p.id] = _Synced(id, hash, saved['updated_at'] as String);
    }
    for (final localId in [..._synced.keys]) {
      if (local.containsKey(localId)) continue;
      await _db
          .from('playlists')
          .update({'deleted': true, 'entries': <Object>[]})
          .eq('user_id', uid)
          .eq('id', _synced[localId]!.id);
      _synced.remove(localId);
    }
  }

  /// A playlist's songs with their tags, so another device can find its own copies.
  Future<List<Map<String, Object?>>> _entries(List<String> paths) async {
    final streams = paths.where(isStream).toList();
    final urls = streams.isEmpty
        ? const <String?>[]
        : await streamingArtUrls(paths: streams);
    final art = {for (final (i, p) in streams.indexed) p: urls[i]};
    return [
      for (final path in paths)
        switch (library.byPath(path)) {
          final t? => {
            'p': path,
            't': t.title,
            'a': t.artists,
            'al': t.album,
            'd': t.durationSecs,
            if (isStream(path)) 'q': t.codec,
            'u': ?art[path],
          },
          null => {'p': path},
        },
    ];
  }

  /// This device's paths for a synced playlist's entries: the same file, a streamed song
  /// (remembered so it shows), or the library's copy of the same song. An entry not
  /// found keeps its path, so the playlist loses nothing when it syncs back.
  Future<List<String>> _resolve(List<Map> entries) async {
    final remember = <RemoteTrack>[
      for (final e in entries)
        if (e['p'] case final String p
            when isStream(p) && library.byPath(p) == null && e['t'] != null)
          RemoteTrack(
            path: p,
            title: e['t'] as String,
            artists: ((e['a'] as List?) ?? const []).cast<String>(),
            album: e['al'] as String?,
            durationSecs: (e['d'] as num?)?.toDouble() ?? 0,
            artUrl: e['u'] as String?,
            quality: e['q'] as String?,
            isrc: null,
          ),
    ];
    if (remember.isNotEmpty) {
      library.addStreams(await streamingRemember(tracks: remember));
    }
    final byKey = <String, String>{};
    for (final t in library.tracks) {
      byKey.putIfAbsent(matchKey(t.title, t.artists), () => t.path);
    }
    return [
      for (final e in entries)
        if (e['p'] case final String p)
          library.byPath(p) != null || isStream(p) || e['t'] == null
              ? p
              : byKey[matchKey(
                      e['t'] as String,
                      ((e['a'] as List?) ?? const []).cast<String>(),
                    )] ??
                    p,
    ];
  }

  // ---- helpers ----

  GoTrueClient get _auth => _client!.auth;
  SupabaseClient get _db => _client!;

  Future<Map<String, dynamic>?> _vault() =>
      _db.from('vaults').select().eq('user_id', user!.id).maybeSingle();

  static String _normal(String email) => email.trim().toLowerCase();

  static String? _hash(String? text) =>
      text == null ? null : sha256.convert(utf8.encode(text)).toString();

  static String _hashOf(Playlist p) => _hash(jsonEncode([p.name, p.paths]))!;

  static String _uuid() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static final _random = Random.secure();

  Future<void> _save() async {
    if (!online) return;
    try {
      await state.writeAsString(
        jsonEncode({
          'services': _services,
          'playlists': {
            for (final e in _synced.entries) '${e.key}': e.value.toJson(),
          },
        }),
      );
    } on Object catch (e) {
      debugPrint('saving account state: $e');
    }
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }
}

/// A playlist as last synced: its id in the account, a hash of its name and songs,
/// the account's `updated_at`, and when it was last edited here.
class _Synced {
  _Synced(this.id, this.hash, this.updated, [this.changed]);

  factory _Synced.fromJson(Map json) => _Synced(
    json['id'] as String,
    json['hash'] as String,
    json['updated'] as String,
    switch (json['changed']) {
      final String s => DateTime.tryParse(s),
      _ => null,
    },
  );

  final String id;
  final String hash;
  final String updated;
  DateTime? changed;

  Map<String, Object?> toJson() => {
    'id': id,
    'hash': hash,
    'updated': updated,
    'changed': ?changed?.toIso8601String(),
  };
}

class AccountException implements Exception {
  const AccountException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Any error from the account code, as a sentence for the user.
String describeAccountError(Object error) => switch (error) {
  AuthRetryableFetchException() || SocketException() || TimeoutException() =>
    'Can\'t reach the Halcyn server. Check your connection.',
  AuthException(:final code, :final message) => switch (code) {
    'invalid_credentials' => 'Wrong email or password.',
    'over_request_rate_limit' || 'over_email_send_rate_limit' =>
      'Too many tries. Wait a minute, then try again.',
    'user_already_exists' || 'email_exists' =>
      'There\'s already an account with that email. Sign in instead.',
    'email_address_invalid' => 'That email address doesn\'t look right.',
    'weak_password' => 'That password is too weak.',
    _ => message,
  },
  PostgrestException(:final message) => 'The server refused that: $message',
  _ => error.toString(),
};

/// The system's keystore: Android Keystore, Windows Credential Manager, the Secret
/// Service keyring on Linux. On Linux every value is one keyring item that each write
/// rewrites whole, so two writes at once lose one: calls take turns.
class _Keystore {
  _Keystore(this.prefix);

  final String prefix;
  static const _storage = FlutterSecureStorage();
  static Future<void> _turn = Future.value();

  static Future<T> _inTurn<T>(Future<T> Function() f) {
    final result = _turn.then((_) => f());
    _turn = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String?> read(String key) =>
      _inTurn(() => _storage.read(key: '$prefix.$key'));

  Future<void> write(String key, String value) =>
      _inTurn(() => _storage.write(key: '$prefix.$key', value: value));

  Future<void> delete(String key) =>
      _inTurn(() => _storage.delete(key: '$prefix.$key'));
}

/// The account's session in the keystore, not in a plain file.
class _SessionStorage extends LocalStorage {
  const _SessionStorage(this.keystore);

  final _Keystore keystore;
  static const _key = 'supabase.session';

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() async => await keystore.read(_key) != null;

  @override
  Future<String?> accessToken() => keystore.read(_key);

  @override
  Future<void> persistSession(String persistSessionString) =>
      keystore.write(_key, persistSessionString);

  @override
  Future<void> removePersistedSession() => keystore.delete(_key);
}

class _PkceStorage extends GotrueAsyncStorage {
  const _PkceStorage(this.keystore);

  final _Keystore keystore;

  @override
  Future<String?> getItem({required String key}) => keystore.read('pkce.$key');

  @override
  Future<void> setItem({required String key, required String value}) =>
      keystore.write('pkce.$key', value);

  @override
  Future<void> removeItem({required String key}) =>
      keystore.delete('pkce.$key');
}
