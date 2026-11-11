import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/application/app_updates.dart';
import 'package:superxd/device/app_package_files.dart';
import 'package:superxd/device/relay_release_feed.dart';
import 'package:superxd/device/signed_content.dart';
import 'package:superxd/domain/app_update.dart';
import 'package:superxd/local/app_update_memory.dart';
import '../tool/content_signing.dart';
import 'app_update_fakes.dart';
import 'content_signing_support.dart';

void main() {
  group('规则', () {
    test('有更新的版本才算要更新，已装低于最低可用版本才是必须更新', () {
      expect(appUpdateUrgency(4, fakeRelease(versionCode: 5)), AppUpdateUrgency.optional);
      expect(appUpdateUrgency(4, fakeRelease(versionCode: 5, minSupported: 5)), AppUpdateUrgency.forced);
      expect(appUpdateUrgency(5, fakeRelease(versionCode: 5)), AppUpdateUrgency.none);
      // 清单把最低可用版本调高了，却没有更新的版本可装：不逼用户。
      expect(appUpdateUrgency(5, fakeRelease(versionCode: 5, minSupported: 9)), AppUpdateUrgency.none);
    });

    test('自动检查按校园日一天一次，跨过校园零点就能再查；有待办的必须更新时每次都查', () {
      // 09:00 与 23:00（北京时间）同一校园日。
      expect(appUpdateCheckDue(DateTime.utc(2026, 10, 15, 1), DateTime.utc(2026, 10, 15, 15), forcedPending: false), isFalse);
      // 23:59 与次日 00:01 只差两分钟，但跨了校园日界。
      expect(appUpdateCheckDue(DateTime.utc(2026, 10, 15, 15, 59), DateTime.utc(2026, 10, 15, 16, 1), forcedPending: false), isTrue);
      expect(appUpdateCheckDue(null, DateTime.utc(2026, 10, 15), forcedPending: false), isTrue);
      expect(appUpdateCheckDue(DateTime.utc(2026, 10, 15, 1), DateTime.utc(2026, 10, 15, 2), forcedPending: true), isTrue);
    });

    test('跳过的版本不再自动弹，更新的版本照弹，必须更新不认跳过', () {
      expect(appUpdatePromptDue(AppUpdateUrgency.optional, fakeRelease(versionCode: 5), 5), isFalse);
      expect(appUpdatePromptDue(AppUpdateUrgency.optional, fakeRelease(versionCode: 6), 5), isTrue);
      expect(appUpdatePromptDue(AppUpdateUrgency.forced, fakeRelease(versionCode: 5), 5), isTrue);
      expect(appUpdatePromptDue(AppUpdateUrgency.none, fakeRelease(versionCode: 5), null), isFalse);
    });
  });

  group('编排', () {
    test('自动检查一个校园日只联网一次，查到新版留给界面弹一次', () async {
      final fixture = UpdateFixture()..feed.next = fakeRelease();
      final updates = fixture.updates;
      await updates.autoCheck();
      expect(fixture.feed.calls, 1);
      expect(updates.phase, AppUpdatePhase.available);
      expect(updates.takePrompt()?.versionCode, 5);
      expect(updates.takePrompt(), isNull);
      await updates.autoCheck();
      expect(fixture.feed.calls, 1);
      fixture.now = DateTime.utc(2026, 10, 15, 17);
      await updates.autoCheck();
      expect(fixture.feed.calls, 2);
    });

    test('跳过这个版本后自动检查不弹，手动检查照样看得到', () async {
      final fixture = UpdateFixture()..feed.next = fakeRelease();
      final updates = fixture.updates;
      await updates.check();
      await updates.skip();
      expect(fixture.memory.skippedVersionCode, 5);
      fixture.now = DateTime.utc(2026, 10, 16, 2);
      await updates.autoCheck();
      expect(updates.takePrompt(), isNull);
      await updates.check();
      expect(updates.phase, AppUpdatePhase.available);
    });

    test('必须更新：跳过无效，杀掉重开同一天也照查照弹', () async {
      final fixture = UpdateFixture()..feed.next = fakeRelease(minSupported: 5);
      final updates = fixture.updates;
      await updates.autoCheck();
      expect(updates.urgency, AppUpdateUrgency.forced);
      expect(updates.takePrompt(), isNotNull);
      await updates.skip();
      expect(fixture.memory.skippedVersionCode, isNull);
      expect(fixture.memory.forcedPending, isTrue);
      await updates.autoCheck();
      expect(fixture.feed.calls, 2);
      expect(updates.takePrompt(), isNotNull);
    });

    test('自动检查失败不打扰、不记成查过；手动检查失败给原因', () async {
      final fixture = UpdateFixture()..feed.error = const AppUpdateException('连不上更新服务器，请稍后再试');
      final updates = fixture.updates;
      await updates.autoCheck();
      expect(updates.phase, AppUpdatePhase.idle);
      expect(updates.takePrompt(), isNull);
      expect(fixture.memory.lastCheckedAt, isNull);
      await updates.check();
      expect(updates.phase, AppUpdatePhase.failed);
      expect(updates.error, '连不上更新服务器，请稍后再试');
    });

    test('渠道还没有发布版本或已是最新：已是最新版本', () async {
      final fixture = UpdateFixture();
      await fixture.updates.check();
      expect(fixture.updates.phase, AppUpdatePhase.upToDate);
      fixture.feed.next = fakeRelease(versionCode: 4);
      await fixture.updates.check();
      expect(fixture.updates.phase, AppUpdatePhase.upToDate);
    });

    test('点更新：下载、核对后交给系统安装，进度原地变化', () async {
      final fixture = UpdateFixture()..feed.next = fakeRelease();
      final updates = fixture.updates;
      await updates.check();
      fixture.files.gate = Completer<void>();
      final running = updates.update();
      await Future<void>.delayed(Duration.zero);
      expect(updates.phase, AppUpdatePhase.downloading);
      expect(updates.progress, .5);
      fixture.files.gate!.complete();
      await running;
      expect(updates.phase, AppUpdatePhase.readyToInstall);
      expect(fixture.installer.installs, ['/cache/app_update/SuperXD-5.apk']);
      // 已经下好并核对过的不再下载，直接再拉起安装。
      await updates.update();
      expect(fixture.files.downloads, 1);
      expect(fixture.installer.installs, hasLength(2));
    });

    test('下坏了或不是本应用的包：删掉并报原因，不交给安装器', () async {
      final fixture = UpdateFixture()..feed.next = fakeRelease();
      final updates = fixture.updates;
      await updates.check();
      fixture.files.downloadedSha = 'b' * 64;
      await updates.update();
      expect(updates.phase, AppUpdatePhase.failed);
      expect(updates.error, '安装包没下完整，请重试');
      expect(fixture.files.stored, isEmpty);
      fixture.files.downloadedSha = fakeSha;
      fixture.installer.identity = const AppPackageIdentity(samePackage: true, versionCode: 5, sameSigner: false);
      await updates.update();
      expect(updates.error, '安装包与本应用对不上，已删除，请到发布页下载');
      expect(fixture.files.stored, isEmpty);
      fixture.installer.identity = const AppPackageIdentity(samePackage: true, versionCode: 4, sameSigner: true);
      await updates.update();
      expect(updates.phase, AppUpdatePhase.failed);
      expect(fixture.installer.installs, isEmpty);
    });

    test('取消下载回到可更新', () async {
      final fixture = UpdateFixture()..feed.next = fakeRelease();
      final updates = fixture.updates;
      await updates.check();
      fixture.files.gate = Completer<void>();
      final running = updates.update();
      await Future<void>.delayed(Duration.zero);
      await updates.cancel();
      await running;
      expect(updates.phase, AppUpdatePhase.available);
      expect(fixture.installer.installs, isEmpty);
    });

    test('没有安装授权先去开启，回到前台只接着装一次', () async {
      final fixture = UpdateFixture()..feed.next = fakeRelease();
      final updates = fixture.updates;
      fixture.installer.allowed = false;
      await updates.check();
      await updates.update();
      expect(updates.phase, AppUpdatePhase.needsPermission);
      await updates.openInstallSettings();
      expect(fixture.installer.settingsOpened, 1);
      fixture.installer.allowed = true;
      await updates.resume();
      expect(fixture.installer.installs, hasLength(1));
      // 用户关掉系统安装界面回来，不再被拉起。
      await updates.resume();
      expect(fixture.installer.installs, hasLength(1));
    });

    test('下载在后台完成时等回前台再拉起安装', () async {
      final fixture = UpdateFixture()..feed.next = fakeRelease();
      final updates = fixture.updates;
      await updates.check();
      fixture.foreground = false;
      await updates.update();
      expect(updates.phase, AppUpdatePhase.readyToInstall);
      expect(fixture.installer.installs, isEmpty);
      fixture.foreground = true;
      await updates.resume();
      expect(fixture.installer.installs, hasLength(1));
    });

    test('没有这个架构的安装包时不下载', () async {
      final fixture = UpdateFixture()..feed.next = fakeRelease(withApk: false);
      await fixture.updates.check();
      await fixture.updates.update();
      expect(fixture.files.downloads, 0);
      expect(fixture.updates.phase, AppUpdatePhase.available);
    });
  });

  group('版本清单', () {
    late TestSigning signing;
    setUpAll(() async => signing = await TestSigning.create());

    // 发版工具给每个架构各签一份的载荷（tool/release_manifest.dart 的 releasePayload）。
    final payload = <String, Object?>{
      'channel': 'alpha',
      'abi': 'arm64-v8a',
      'versionCode': 5,
      'versionName': '1.0.0-alpha.4',
      'publishedAt': '2026-10-16T08:00:00Z',
      'minSupportedVersionCode': 0,
      'notes': '修了一些问题',
      'releasePage': 'https://github.com/huverse/SuperXD/releases/tag/v1.0.0-alpha.4',
      'apk': {'file': 'SuperXD-1.0.0-alpha.4-arm64-v8a.apk', 'size': 1024, 'sha256': fakeSha},
    };
    // 中转的返回：明文字段给旧客户端（这里故意写成别的值，新客户端一律不用），envelope 是这个架构签好的信封。
    Future<Map<String, Object?>> signedResponse(Map<String, Object?> payload, {List<SigningKey>? signers, SignedContent content = SignedContent.release}) async => {
      'versionCode': 99,
      'versionName': '9.9.9',
      'publishedAt': '2026-10-16T08:00:00Z',
      'minSupportedVersionCode': 99,
      'notes': '明文',
      'releasePage': 'https://evil.test/',
      'apk': {'url': '/v1/app/files/evil.apk', 'size': 1, 'sha256': fakeSha},
      'envelope': await signing.seal(payload, content, signers ?? [signing.release]),
    };
    // 正文按 UTF-8 编码（http.Response 默认 latin1，中文会直接抛错）。
    http.Response reply(Object? body, int status) =>
        http.Response.bytes(utf8.encode(body is String ? body : jsonEncode(body)), status, headers: {'content-type': 'application/json; charset=utf-8'});
    RelayReleaseFeed feed(MockClient client, {Duration timeout = const Duration(seconds: 15), bool packages = true}) =>
        RelayReleaseFeed('http://relay.test:8080', channel: 'alpha', abi: 'arm64-v8a', packages: packages, keys: signing.keys, client: client, timeout: timeout);
    Matcher failsWith(String message) => throwsA(isA<AppUpdateException>().having((error) => error.message, 'message', message));

    test('按渠道与架构请求，只认验过签的载荷，安装包地址拼在中转地址后面', () async {
      late Uri requested;
      final body = await signedResponse(payload);
      final release = await feed(MockClient((request) async {
        requested = request.url;
        return reply(body, 200);
      })).latest();
      expect(requested.toString(), 'http://relay.test:8080/v1/app/releases/alpha?abi=arm64-v8a');
      expect([release!.versionCode, release.minSupportedVersionCode, release.notes], [5, 0, '修了一些问题']);
      expect(release.publishedAt, DateTime.utc(2026, 10, 16, 8));
      expect(release.releasePage.toString(), 'https://github.com/huverse/SuperXD/releases/tag/v1.0.0-alpha.4');
      expect(release.apk!.url.toString(), 'http://relay.test:8080/v1/app/files/SuperXD-1.0.0-alpha.4-arm64-v8a.apk');
    });

    test('渠道没有发布版本返回空，限流与服务端错误给原因', () async {
      expect(await feed(MockClient((_) async => reply('{"code":"RELEASE_NOT_FOUND","message":"x"}', 404))).latest(), isNull);
      await expectLater(feed(MockClient((_) async => reply('{"code":"RATE_LIMITED","retryAfter":30}', 429))).latest(), failsWith('检查更新的人太多，请稍后再试'));
      await expectLater(feed(MockClient((_) async => reply('{"code":"INTERNAL"}', 500))).latest(), throwsA(isA<AppUpdateException>()));
      await expectLater(feed(MockClient((_) async => reply('<html>', 502))).latest(), throwsA(isA<AppUpdateException>()));
    });

    // 中间人能改明文 HTTP 上的任何字节：没有信封（旧中转或旧清单）、改过的载荷、坏签名、拿开发者的话的钥签、冒名的钥、
    // 签成开发者的话的内容类型，都不认、不提示更新。
    test('没有签名或验不过：按失败处理，不用明文字段', () async {
      final signed = await signedResponse(payload);
      final envelope = signed['envelope']! as Map<String, Object?>;
      String encoded(Map<String, Object?> payload) => base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
      for (final body in [
        {...signed}..remove('envelope'),
        {...signed, 'envelope': null},
        {...signed, 'envelope': {...envelope, 'signed': encoded({...payload, 'minSupportedVersionCode': 99})}},
        {...signed, 'envelope': {...envelope, 'signatures': [{'keyId': 'release-test', 'sig': 'A' * 86}]}},
        {...signed, 'envelope': {...envelope, 'signatures': <Object>[]}},
        {...signed, 'envelope': {...envelope, 'signed': '不是base64'}},
        {...signed, 'envelope': {...envelope, 'signatures': [{'keyId': 'release-test', 'sig': 'short'}]}},
        await signedResponse(payload, signers: [signing.notes]),
        await signedResponse(payload, signers: [signing.stranger]),
        await signedResponse(payload, content: SignedContent.notes),
      ]) {
        await expectLater(feed(MockClient((_) async => reply(body, 200))).latest(), failsWith('更新信息没通过校验，请稍后再试'), reason: '$body');
      }
    });

    test('离线备用钥签的照样认，换钥时多签一份也认', () async {
      for (final signers in [
        [signing.offline],
        [signing.stranger, signing.release],
      ]) {
        final body = await signedResponse(payload, signers: signers);
        expect((await feed(MockClient((_) async => reply(body, 200))).latest())!.versionCode, 5);
      }
    });

    test('别的渠道、别的架构的签名载荷不认（防重放）', () async {
      for (final replayed in [
        {...payload, 'channel': 'beta'},
        {...payload, 'abi': 'x86_64'},
      ]) {
        final body = await signedResponse(replayed);
        await expectLater(feed(MockClient((_) async => reply(body, 200))).latest(), failsWith('更新信息格式不对，请稍后再试'), reason: '$replayed');
      }
    });

    test('签过名的载荷仍是外部输入：别处的安装包、非 https 发布页、坏哈希、超长响应都不认', () async {
      for (final broken in [
        {...payload, 'apk': {'file': '../x.apk', 'size': 1, 'sha256': fakeSha}},
        {...payload, 'apk': {'file': 'http://evil.test/a.apk', 'size': 1, 'sha256': fakeSha}},
        {...payload, 'apk': {'file': 'a.apk', 'size': 1, 'sha256': 'XYZ'}},
        {...payload, 'releasePage': 'http://github.com/x'},
        {...payload, 'versionCode': 0},
        {...payload, 'versionName': ''},
      ]) {
        final body = await signedResponse(broken);
        await expectLater(feed(MockClient((_) async => reply(body, 200))).latest(), throwsA(isA<AppUpdateException>()), reason: '$broken');
      }
      final huge = jsonEncode({'notes': 'x' * (appReleaseResponseMaxBytes + 1)});
      await expectLater(feed(MockClient((_) async => reply(huge, 200))).latest(), throwsA(isA<AppUpdateException>()));
      // 没有这个架构的包：apk 为空，照样是有效清单。
      final noApk = await signedResponse({...payload, 'apk': null});
      expect((await feed(MockClient((_) async => reply(noApk, 200))).latest())!.apk, isNull);
    });

    // iOS 不能在应用里安装（[人工决策] 见 main.dart 的 appUpdates）：取 arm64 那份，只看版本与更新说明，弹窗给「去发布页下载」。
    test('不要安装包时清单照样有效，只是没有安装包', () async {
      final body = await signedResponse(payload);
      final release = await feed(MockClient((_) async => reply(body, 200)), packages: false).latest();
      expect([release!.versionCode, release.apk, release.releasePage.toString()], [5, isNull, 'https://github.com/huverse/SuperXD/releases/tag/v1.0.0-alpha.4']);
    });

    test('自动检查遇到验不过的清单：不弹、不记成查过，手动检查给原因', () async {
      final body = await signedResponse({...payload, 'minSupportedVersionCode': 5}, signers: [signing.stranger]);
      final fixture = UpdateFixture();
      final updates = AppUpdates(
        feed: feed(MockClient((_) async => reply(body, 200))),
        files: fixture.files,
        installer: fixture.installer,
        memory: fixture.memory,
        installedVersionCode: 4,
        foreground: () => true,
        clock: () => fixture.now,
      );
      await updates.autoCheck();
      expect([updates.phase, updates.urgency, updates.takePrompt(), fixture.memory.lastCheckedAt], [AppUpdatePhase.idle, AppUpdateUrgency.none, isNull, isNull]);
      await updates.check();
      expect([updates.phase, updates.error], [AppUpdatePhase.failed, '更新信息没通过校验，请稍后再试']);
    });

    test('连不上或超时给原因，不自动重试', () async {
      var calls = 0;
      final body = await signedResponse(payload);
      await expectLater(
        feed(MockClient((_) async {
          calls++;
          throw http.ClientException('refused');
        })).latest(),
        throwsA(isA<AppUpdateException>()),
      );
      await expectLater(
        feed(MockClient((_) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return reply(body, 200);
        }), timeout: const Duration(milliseconds: 20)).latest(),
        failsWith('连不上更新服务器，请稍后再试'),
      );
      expect(calls, 2);
    });

    test('按正在运行的架构取包', () {
      expect(appAbiName(Abi.androidArm64), 'arm64-v8a');
      expect(appAbiName(Abi.androidArm), 'armeabi-v7a');
      expect(appAbiName(Abi.androidX64), 'x86_64');
      expect(appAbiName(Abi.linuxX64), isNull);
    });
  });

  group('本机文件', () {
    late Directory temp;
    setUp(() async => temp = await Directory.systemTemp.createTemp('superxd_update_test'));
    tearDown(() async => temp.delete(recursive: true));

    test('检查记录写下再读回，坏文件当没有记录', () async {
      final file = File(path.join(temp.path, 'app_update.json'));
      final memory = await FileAppUpdateMemory.open(file);
      expect(memory.lastCheckedAt, isNull);
      await memory.save(lastCheckedAt: DateTime.utc(2026, 10, 15, 2), skippedVersionCode: 5, forcedPending: true);
      final reopened = await FileAppUpdateMemory.open(file);
      expect(reopened.lastCheckedAt, DateTime.utc(2026, 10, 15, 2));
      expect(reopened.skippedVersionCode, 5);
      expect(reopened.forcedPending, isTrue);
      await file.writeAsString('{坏了');
      final broken = await FileAppUpdateMemory.open(file);
      expect(broken.lastCheckedAt, isNull);
      expect(broken.forcedPending, isFalse);
    });

    test('装好新版后清掉旧安装包与残留，比已装新的留着；SHA-256 按文件内容算', () async {
      final files = CacheAppPackageFiles(root: () async => temp);
      for (final name in ['SuperXD-4.apk', 'SuperXD-5.apk', 'SuperXD-6.apk', 'partial.tmp']) {
        await File(path.join(temp.path, name)).writeAsString(name);
      }
      await files.prune(5);
      expect(temp.listSync().map((entity) => path.basename(entity.path)), ['SuperXD-6.apk']);
      final apk = await files.pathFor(fakeRelease(versionCode: 6));
      expect(apk, path.join(temp.path, 'SuperXD-6.apk'));
      expect(await files.sha256Of(apk), sha256.convert(utf8.encode('SuperXD-6.apk')).toString());
      await files.delete(apk);
      expect(await files.exists(apk), isFalse);
    });
  });
}
