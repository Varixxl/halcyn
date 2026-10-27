import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/src/state/updater.dart';

void main() {
  test('versions compare by number, not text', () {
    expect(compareVersions('0.2.0', '0.1.0'), greaterThan(0));
    expect(compareVersions('0.10.0', '0.9.9'), greaterThan(0));
    expect(compareVersions('1.0', '1.0.0'), 0);
    expect(compareVersions('1.0.0+5', '1.0.0+1'), 0);
    expect(compareVersions('1.0.0-beta', '1.0.1'), lessThan(0));
  });

  test('a copy built from source doesn\'t replace itself', () {
    Updater at(String dir, String platform) => Updater(
      settings: File('/nonexistent/u.json'),
      cacheDir: Directory.systemTemp,
      current: '0.1.0',
      bundleDir: dir,
      platform: platform,
      persist: false,
    );
    expect(
      at('/home/u/halcyn/build/linux/x64/release/bundle', 'linux').unsupported,
      isNotNull,
    );
    expect(
      at(
        r'C:\src\halcyn\build\windows\x64\runner\Release',
        'windows',
      ).unsupported,
      isNotNull,
    );
    expect(at('/home/u/Apps/halcyn', 'linux').unsupported, isNull);
    expect(at('/data/app', 'android').unsupported, isNull);
  });

  group('Linux', () {
    late Directory temp;
    late HttpServer server;
    late List<int> tarball;
    var digest = '';

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('halcyn-update-');
      // The installed copy, and a release with a new one.
      await Directory('${temp.path}/Apps/halcyn').create(recursive: true);
      await File('${temp.path}/Apps/halcyn/halcyn').writeAsString('old');
      final release = Directory('${temp.path}/release/halcyn')
        ..createSync(recursive: true);
      File('${release.path}/halcyn').writeAsStringSync('new');
      File('${release.path}/install.sh').writeAsStringSync('#!/bin/sh');
      await Process.run('tar', [
        '-czf',
        '${temp.path}/halcyn-linux-x64.tar.gz',
        '-C',
        '${temp.path}/release',
        'halcyn',
      ]);
      tarball = await File('${temp.path}/halcyn-linux-x64.tar.gz')
          .readAsBytes();
      digest = sha256.convert(tarball).toString();

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final base = 'http://127.0.0.1:${server.port}';
        if (request.uri.path == '/latest') {
          request.response.write(
            jsonEncode({
              'tag_name': 'v0.2.0',
              'body': 'Notes',
              'html_url': '$base/page',
              'assets': [
                {
                  'name': 'halcyn-linux-x64.tar.gz',
                  'browser_download_url': '$base/asset',
                  'size': tarball.length,
                  'digest': 'sha256:$digest',
                },
              ],
            }),
          );
        } else if (request.uri.path == '/asset') {
          request.response.add(tarball);
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      await temp.delete(recursive: true);
    });

    Updater updater() => Updater(
      settings: File('${temp.path}/update.json'),
      cacheDir: Directory('${temp.path}/cache'),
      current: '0.1.0',
      bundleDir: '${temp.path}/Apps/halcyn',
      api: Uri.parse('http://127.0.0.1:${server.port}/latest'),
      platform: 'linux',
      persist: false,
    );

    test('finds, downloads, checks and swaps in the new version', () async {
      final u = updater();
      await u.check();
      expect(u.stage, UpdateStage.available);
      expect(u.available?.version, '0.2.0');
      await u.install();
      expect(u.error, isNull);
      expect(u.stage, UpdateStage.ready);
      expect(File('${temp.path}/Apps/halcyn/halcyn').readAsStringSync(), 'new');
      expect(File('${temp.path}/Apps/halcyn/install.sh').existsSync(), isTrue);
      // The old copy waits beside it until the new one starts and cleans up.
      expect(
        File('${temp.path}/Apps/.halcyn-old/halcyn').readAsStringSync(),
        'old',
      );
      expect(
        Directory('${temp.path}/Apps/.halcyn-update').existsSync(),
        isFalse,
      );
      await updater().load();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(Directory('${temp.path}/Apps/.halcyn-old').existsSync(), isFalse);
    });

    test('a damaged download is refused and nothing changes', () async {
      digest = '0' * 64;
      final u = updater();
      await u.check();
      await u.install();
      expect(u.stage, UpdateStage.failed);
      expect(u.error, contains('checksum'));
      expect(File('${temp.path}/Apps/halcyn/halcyn').readAsStringSync(), 'old');
    });

    test('the same version is up to date', () async {
      final u = Updater(
        settings: File('${temp.path}/update.json'),
        cacheDir: Directory('${temp.path}/cache'),
        current: '0.2.0',
        bundleDir: '${temp.path}/Apps/halcyn',
        api: Uri.parse('http://127.0.0.1:${server.port}/latest'),
        platform: 'linux',
        persist: false,
      );
      await u.check();
      expect(u.stage, UpdateStage.upToDate);
      expect(u.available, isNull);
    });

    test('no connection is said plainly', () async {
      final u = Updater(
        settings: File('${temp.path}/update.json'),
        cacheDir: Directory('${temp.path}/cache'),
        current: '0.1.0',
        api: Uri.parse('http://127.0.0.1:1/latest'),
        platform: 'linux',
        persist: false,
      );
      await u.check();
      expect(u.stage, UpdateStage.failed);
      expect(u.error, contains('no connection'));
    });
  });
}
