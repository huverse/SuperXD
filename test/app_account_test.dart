import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/application/account_diagnostics.dart';
import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/diagnostic_upload.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/edu/login_rules.dart';
import 'package:superxd/gateway/account_access.dart';
import 'package:superxd/page/account_page.dart';
import 'package:superxd/social/relay_app_account.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/social_crypto.dart';
import 'package:superxd/theme/campus_theme.dart';

// 应用账号（人工决策见 domain/app_account.dart 与 application/app_accounts.dart）：中转客户端、编排与账号页。合成数据。
const _identity = AccountIdentity(source: 'http://school.example', loginId: '20260000001');
const _other = AccountIdentity(source: 'http://school.example', loginId: '20260000002');
const _accountId = 'AAAAAAAAAAAAAAAAAAAAAA';
// 编排测试里替身给的把手（slot 只是替身里的一个名字）。
const _account = AppAccountRef(accountId: _accountId, slot: 'fake-slot');
// 1×1 的 PNG：账号页的验证码弹窗要真的解得出图。
const _captchaImage = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

void main() {
  group('中转客户端', () {
    late _Relay relay;
    late MemoryAppAccountVault vault;
    late RelayAppAccountClient client;
    late List<int> sealSeed;
    setUp(() async {
      relay = _Relay();
      vault = MemoryAppAccountVault();
      sealSeed = List<int>.generate(32, (index) => index + 1);
      final sealPublic = (await (await X25519().newKeyPairFromSeed(sealSeed)).extractPublicKey()).bytes;
      client = RelayAppAccountClient(vault: vault, transport: relay, sealKey: sealPublic);
    });

    test('登录：签名、口令摘要只认这台设备打得开，要验证码时沿用同一把密钥与挑战号，成功才存本机', () async {
      final proof = kingoSignInProof(_identity.loginId, 'secret-value');
      relay.reply = (request) => const RelayResponse(200, {'status': 'captcha', 'account': null, 'captcha': {'challengeId': 'BBBBBBBBBBBBBBBBBBBBBB', 'image': _captchaImage, 'contentType': 'image/jpeg', 'hint': '请输入图中的验证码'}});
      final step = await client.signInWithKingo(_identity, proof);
      expect(step, isA<AppAccountCaptcha>().having((step) => step.captcha.imageBase64, 'image', _captchaImage));
      expect(await client.accountOf(_identity), isNull);
      final first = relay.requests.single;
      expect(first.path, '/v1/account/sign-in/kingo');
      expect(first.headers['x-sxd-device'], first.deviceIdOfBody);
      // 封装的是口令摘要，不是明文；只有中转私钥、而且只按这台设备号打得开。
      final opened = await _open(sealSeed, decodeBase64UrlNoPad(first.body['sealed'] as String), first.deviceIdOfBody);
      expect(jsonDecode(utf8.decode(opened)), proof.toJson());
      expect(utf8.decode(opened), isNot(contains('secret-value')));
      relay.reply = (request) => const RelayResponse(200, {'status': 'signedIn', 'account': {'accountId': _accountId, 'created': true, 'serverTime': 1}, 'captcha': null});
      final signed = await client.signInWithKingo(_identity, proof, captcha: 'AB12');
      expect(signed, isA<AppAccountSignedIn>().having((step) => step.account, 'account', AppAccountRef(accountId: _accountId, slot: appAccountSlot(_identity))));
      final second = relay.requests.last;
      expect(second.headers['x-sxd-device'], first.headers['x-sxd-device']);
      expect(second.body['challengeId'], 'BBBBBBBBBBBBBBBBBBBBBB');
      expect(second.body['captcha'], 'AB12');
      expect(await client.accountOf(_identity), AppAccountRef(accountId: _accountId, slot: appAccountSlot(_identity)));
      expect((await vault.read(appAccountSlot(_identity)))!.identity.deviceId, second.headers['x-sxd-device']);
      expect(await client.accountOf(_other), isNull);
      // 存储键里不出现学号。
      expect(appAccountSlot(_identity), isNot(contains(_identity.loginId)));
    });

    test('答验证码时没有留着的挑战、放弃后再答，都要重新登录', () async {
      await expectLater(client.signInWithKingo(_identity, kingoSignInProof(_identity.loginId, 'x'), captcha: 'AB12'), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', AppAccountFailure.captchaExpired)));
      relay.reply = (request) => const RelayResponse(200, {'status': 'captcha', 'account': null, 'captcha': {'challengeId': 'BBBBBBBBBBBBBBBBBBBBBB', 'image': _captchaImage, 'contentType': 'image/jpeg', 'hint': ''}});
      await client.signInWithKingo(_identity, kingoSignInProof(_identity.loginId, 'x'));
      client.abandon(_identity);
      await expectLater(client.signInWithKingo(_identity, kingoSignInProof(_identity.loginId, 'x'), captcha: 'AB12'), throwsA(isA<AppAccountException>()));
    });

    test('中转的错误码换成给用户看的原因', () async {
      final cases = <(Map<String, Object?>, int, AppAccountFailure, String)>[
        ({'code': 'ACCOUNT_REJECTED', 'reason': 'passwordWrong', 'message': '账号或密码有误!'}, 422, AppAccountFailure.rejected, '账号或密码有误!'),
        ({'code': 'UPSTREAM_UNAVAILABLE', 'reason': 'rateLimited'}, 429, AppAccountFailure.upstream, '教务提示请求太过频繁，请约 1 分钟后再试'),
        ({'code': 'UPSTREAM_UNAVAILABLE', 'reason': 'network'}, 502, AppAccountFailure.upstream, '暂时连不上学校教务，请稍后再试'),
        ({'code': 'RATE_LIMITED', 'retryAfter': 60}, 429, AppAccountFailure.rateLimited, '尝试太频繁，请稍后再试'),
        ({'code': 'CAPTCHA_EXPIRED'}, 410, AppAccountFailure.captchaExpired, '验证码已过期，请重新登录'),
      ];
      for (final (body, status, failure, message) in cases) {
        relay.reply = (request) => RelayResponse(status, body);
        await expectLater(client.signInWithKingo(_identity, kingoSignInProof(_identity.loginId, 'x')), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', failure).having((error) => error.message, 'message', message)));
      }
      relay.reply = (request) => throw const RelayException(RelayCode.network);
      await expectLater(client.signInWithKingo(_identity, kingoSignInProof(_identity.loginId, 'x')), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', AppAccountFailure.network)));
      relay.reply = (request) => const RelayResponse(200, {'status': 'signedIn', 'account': {'accountId': 'bad id', 'created': true}});
      await expectLater(client.signInWithKingo(_identity, kingoSignInProof(_identity.loginId, 'x')), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', AppAccountFailure.failed)));
      expect(await client.accountOf(_identity), isNull);
    });

    test('查看账号：别处注销了就删本机记录；退出连不上也删本机；注销要服务端删成才算', () async {
      await vault.write(appAccountSlot(_identity), AppAccountKey(identity: await SocialIdentity.generate(), accountId: _accountId));
      relay.reply = (request) => const RelayResponse(200, {'accountId': _accountId, 'providers': ['kingo'], 'deviceCount': 2, 'createdAt': 1763000000000});
      final summary = await client.summary(_identity);
      expect(summary.deviceCount, 2);
      relay.reply = (request) => const RelayResponse(404, {'code': 'ACCOUNT_NOT_FOUND'});
      await expectLater(client.summary(_identity), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', AppAccountFailure.notSignedIn)));
      expect(await client.accountOf(_identity), isNull);

      await vault.write(appAccountSlot(_identity), AppAccountKey(identity: await SocialIdentity.generate(), accountId: _accountId));
      relay.reply = (request) => throw const RelayException(RelayCode.network);
      await client.signOut(_identity);
      expect(relay.requests.last.method, 'DELETE');
      expect(relay.requests.last.path, '/v1/devices');
      expect(await client.accountOf(_identity), isNull);

      await vault.write(appAccountSlot(_identity), AppAccountKey(identity: await SocialIdentity.generate(), accountId: _accountId));
      await expectLater(client.delete(_identity), throwsA(isA<AppAccountException>()));
      expect(await client.accountOf(_identity), AppAccountRef(accountId: _accountId, slot: appAccountSlot(_identity)));
      relay.reply = (request) => request.path == '/v1/account' ? const RelayResponse(204, {}) : const RelayResponse(204, {});
      await client.delete(_identity);
      expect(relay.requests.map((request) => '${request.method} ${request.path}').toList().reversed.take(2).toList(), ['DELETE /v1/devices', 'DELETE /v1/account']);
      expect(await client.accountOf(_identity), isNull);
    });
  });

  group('编排', () {
    late _Accounts accounts;
    late _Client client;
    late AppAccounts appAccounts;
    late DateTime now;
    setUp(() async {
      accounts = _Accounts()..identity = _identity;
      client = _Client();
      now = DateTime.utc(2026, 11, 13, 12);
      appAccounts = AppAccounts(accounts: accounts, client: client, now: () => now);
      await appAccounts.load();
    });
    tearDown(() => appAccounts.dispose());

    test('没记住账号要输密码，要验证码就答，成功后用同一个密码重登教务', () async {
      expect(await appAccounts.signIn(), isA<AppAccountPasswordNeeded>());
      expect(client.signIns, isEmpty);
      client.steps.add(const AppAccountCaptcha(CaptchaView(prompt: '', hint: '请输入图中的验证码', contentType: 'image/jpeg', imageBase64: _captchaImage)));
      expect(await appAccounts.signIn(password: 'typed-secret'), isA<AppAccountNeedsCaptcha>());
      expect(client.signIns.single, (captcha: null, digest: kingoSignInProof(_identity.loginId, 'typed-secret').passwordDigest));
      client.steps.add(const AppAccountSignedIn(account: _account, created: true));
      final done = await appAccounts.answerCaptcha('AB12');
      expect(done, isA<AppAccountDone>().having((result) => result.notice, 'notice', '已登录应用账号'));
      expect(client.signIns.last.captcha, 'AB12');
      expect(accounts.refreshed, ['typed-secret']);
      expect(appAccounts.accountId, _accountId);
      expect(await appAccounts.answerCaptcha('AB12'), isA<AppAccountError>());
    });

    test('记住了账号直接核对；教务拒绝原样告诉用户；重登没成也算登录了、提示重新登录教务', () async {
      accounts.remembered = 'saved-secret';
      client.failure = const AppAccountException(AppAccountFailure.rejected, '账号或密码有误!');
      expect(await appAccounts.signIn(), isA<AppAccountError>().having((result) => result.message, 'message', '账号或密码有误!'));
      expect(appAccounts.accountId, isNull);
      expect(accounts.refreshed, isEmpty);
      client.failure = null;
      client.steps.add(const AppAccountSignedIn(account: _account, created: false));
      accounts.refreshOk = false;
      expect(await appAccounts.signIn(), isA<AppAccountDone>().having((result) => result.notice, 'notice', '已登录应用账号；教务需要重新登录一次'));
      expect(accounts.refreshed, [null]);
    });

    test('跟着教务走：换账号读那个账号的、丢掉没答完的验证码；退出教务时退出那个账号的', () async {
      client.records[_identity.loginId] = _accountId;
      await appAccounts.load();
      expect(appAccounts.accountId, _accountId);
      client.steps.add(const AppAccountCaptcha(CaptchaView(prompt: '', hint: '', contentType: 'image/jpeg', imageBase64: _captchaImage)));
      accounts.identity = _other;
      expect(await appAccounts.signIn(password: 'x'), isA<AppAccountError>(), reason: '还没读完新账号的记录');
      await appAccounts.load();
      expect(appAccounts.accountId, isNull);
      expect(await appAccounts.signIn(password: 'x'), isA<AppAccountNeedsCaptcha>());
      accounts.identity = _identity;
      accounts.notify();
      await pumpEventQueue();
      expect(client.abandoned, [_other.loginId]);
      expect(appAccounts.accountId, _accountId);
      await appAccounts.forget(_identity);
      expect(client.signedOut, [_identity.loginId]);
      expect(appAccounts.accountId, isNull);
    });

    test('每天最多看一次账号；别处注销了就退回未登录', () async {
      client.records[_identity.loginId] = _accountId;
      await appAccounts.load();
      await appAccounts.check();
      await appAccounts.check();
      expect(client.summaries, 1);
      now = now.add(AppAccounts.checkGap);
      client.failure = const AppAccountException(AppAccountFailure.notSignedIn, '应用账号已经退出');
      await appAccounts.check();
      expect(client.summaries, 2);
      expect(appAccounts.accountId, isNull);
      await appAccounts.check();
      expect(client.summaries, 2, reason: '没登录不联网');
    });
  });

  group('账号页', () {
    late _Accounts accounts;
    late _Client client;
    late AppAccounts appAccounts;
    late AppSession session;
    setUp(() async {
      accounts = _Accounts()..identity = _identity;
      client = _Client();
      appAccounts = AppAccounts(accounts: accounts, client: client);
      await appAccounts.load();
      session = AppSession(accounts);
    });
    tearDown(() { appAccounts.dispose(); session.dispose(); });

    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: AccountPage(session: session, name: '同学甲', appAccounts: appAccounts)));
      await tester.pumpAndSettle();
    }

    testWidgets('登录：先单独同意，输密码，答验证码，成功后显示已登录并给提示条', (tester) async {
      await pumpPage(tester);
      expect(find.text('应用账号'), findsOneWidget);
      expect(find.text('未登录'), findsOneWidget);
      await tester.tap(find.text('应用账号'));
      await tester.pumpAndSettle();
      expect(find.text('登录应用账号？'), findsOneWidget);
      expect(find.textContaining('不是明文'), findsOneWidget);
      await tester.tap(find.text('同意并登录'));
      await tester.pumpAndSettle();
      expect(find.text('输入当前账号的教务密码，核对后不保存。'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'typed-secret');
      await tester.pump();
      client.steps.add(const AppAccountCaptcha(CaptchaView(prompt: '', hint: '请输入图中的验证码', contentType: 'image/jpeg', imageBase64: _captchaImage)));
      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();
      expect(find.text('请输入图中的验证码'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'AB12');
      await tester.pump();
      client.steps.add(const AppAccountSignedIn(account: _account, created: true));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('已登录'), findsOneWidget);
      expect(find.text('已登录应用账号'), findsOneWidget);
      expect(accounts.refreshed, ['typed-secret']);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('不同意就不核对；登录着点开是退出与注销，都要确认', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('应用账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(client.signIns, isEmpty);
      expect(accounts.proofs, 0);

      client.records[_identity.loginId] = _accountId;
      await appAccounts.load();
      await tester.pumpAndSettle();
      expect(find.text('已登录'), findsOneWidget);
      await tester.tap(find.text('应用账号'));
      await tester.pumpAndSettle();
      expect(find.text('退出应用账号'), findsOneWidget);
      await tester.tap(find.text('注销应用账号'));
      await tester.pumpAndSettle();
      expect(find.text('注销应用账号？'), findsOneWidget);
      await tester.tap(find.text('注销'));
      await tester.pumpAndSettle();
      expect(client.deleted, [_identity.loginId]);
      expect(find.text('未登录'), findsOneWidget);
      expect(find.text('应用账号已注销'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    // 人工决策见 domain/diagnostic_upload.dart：登录着应用账号时，菜单里看与删记在账号下的诊断包。
    testWidgets('登录着点开多一项「我上传的诊断包」：列出记在账号下的包，点一行复制编号，⋯里删除要确认', (tester) async {
      final diagnosticsClient = _DiagnosticClient([
        // 刚传完：离删除差几分钟满 30 天，要写 30 天（同确认框），不能向下取整成 29。
        DiagnosticRecord(id: '7KQ2M9XD', bytes: 2 * 1024 * 1024, uploadedAt: DateTime.now().toUtc(), expiresAt: DateTime.now().toUtc().add(const Duration(days: 30, minutes: -1))),
      ]);
      final diagnostics = AccountDiagnostics(uploader: _NoUploader(), client: diagnosticsClient, account: () => appAccounts.current);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      client.records[_identity.loginId] = _accountId;
      await appAccounts.load();
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: AccountPage(session: session, name: '同学甲', appAccounts: appAccounts, diagnostics: diagnostics)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我上传的诊断包'));
      await tester.pumpAndSettle();
      expect(find.text('诊断编号 7KQ2M9XD'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('2.0 MB · 30 天后删除')), findsOneWidget);
      await tester.tap(find.text('诊断编号 7KQ2M9XD'));
      await tester.pumpAndSettle();
      expect(copied, '7KQ2M9XD');
      expect(find.text('已复制诊断编号'), findsOneWidget);
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除诊断包 7KQ2M9XD？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(diagnosticsClient.deleted, ['7KQ2M9XD']);
      expect(find.text('诊断编号 7KQ2M9XD'), findsNothing);
      expect(find.text('应用账号下还没有诊断包'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('没配中转时不显示这一组', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: AccountPage(session: session, name: '同学甲')));
      await tester.pumpAndSettle();
      expect(find.text('应用账号'), findsNothing);
      expect(find.text('退出登录'), findsOneWidget);
    });
  });
}

// 按客户端的布局解开信封（同服务端 account_keys.ts），验证只有中转私钥、而且只按发起的设备号打得开。
Future<List<int>> _open(List<int> recipientSeed, List<int> sealed, String deviceId) async {
  final recipient = await X25519().newKeyPairFromSeed(recipientSeed);
  final recipientPublic = (await recipient.extractPublicKey()).bytes;
  final ephemeral = sealed.sublist(1, 33);
  final shared = await X25519().sharedSecretKey(keyPair: recipient, remotePublicKey: SimplePublicKey(ephemeral, type: KeyPairType.x25519));
  final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(secretKey: shared, nonce: [...ephemeral, ...recipientPublic], info: utf8.encode('SXD1-account-sign-in'));
  final box = SecretBox(sealed.sublist(45, sealed.length - 16), nonce: sealed.sublist(33, 45), mac: Mac(sealed.sublist(sealed.length - 16)));
  final aes = AesGcm.with256bits();
  await expectLater(aes.decrypt(box, secretKey: key, aad: [1, ...ephemeral, ...utf8.encode('CCCCCCCCCCCCCCCCCCCCCC')]), throwsA(isA<SecretBoxAuthenticationError>()));
  return aes.decrypt(box, secretKey: key, aad: [1, ...ephemeral, ...utf8.encode(deviceId)]);
}

class _Request {
  _Request(this.method, this.path, this.headers, this.body);
  final String method;
  final String path;
  final Map<String, String> headers;
  final Map<String, Object?> body;
  String get deviceIdOfBody => deviceIdOf(decodeBase64UrlNoPad(body['signPublicKey'] as String? ?? ''));
}

class _Relay implements RelayTransport {
  final requests = <_Request>[];
  RelayResponse Function(_Request request) reply = (request) => const RelayResponse(204, {});
  @override
  Future<RelayResponse> send(String method, String pathWithQuery, Map<String, String> headers, List<int>? body, {Duration? timeout, int? limit, bool background = false}) async {
    final request = _Request(method, pathWithQuery, headers, body == null ? const {} : (jsonDecode(utf8.decode(body)) as Map).cast<String, Object?>());
    requests.add(request);
    return reply(request);
  }
}

class _Client implements AppAccountClient {
  final records = <String, String>{};
  final steps = <AppAccountStep>[];
  final signIns = <({String? captcha, String digest})>[];
  final abandoned = <String>[];
  final signedOut = <String>[];
  final deleted = <String>[];
  int summaries = 0;
  AppAccountException? failure;

  @override
  Future<AppAccountRef?> accountOf(AccountIdentity identity) async => records[identity.loginId] == null ? null : AppAccountRef(accountId: records[identity.loginId]!, slot: _account.slot);
  @override
  Future<AppAccountStep> signInWithKingo(AccountIdentity identity, KingoSignInProof proof, {String? captcha}) async {
    signIns.add((captcha: captcha, digest: proof.passwordDigest));
    if (failure case final error?) throw error;
    final step = steps.removeAt(0);
    if (step is AppAccountSignedIn) records[identity.loginId] = step.account.accountId;
    return step;
  }
  @override
  void abandon(AccountIdentity identity) => abandoned.add(identity.loginId);
  @override
  Future<AppAccountSummary> summary(AccountIdentity identity) async {
    summaries++;
    if (failure case final error?) throw error;
    return AppAccountSummary(accountId: records[identity.loginId]!, providers: const ['kingo'], deviceCount: 1, createdAt: DateTime.utc(2026));
  }
  @override
  Future<void> signOut(AccountIdentity identity) async {
    signedOut.add(identity.loginId);
    records.remove(identity.loginId);
  }
  @override
  Future<void> delete(AccountIdentity identity) async {
    deleted.add(identity.loginId);
    records.remove(identity.loginId);
  }
}

// 只实现应用账号与账号页用到的几项，其余交给 noSuchMethod。
class _Accounts extends AccountAccess {
  AccountIdentity? identity;
  String? remembered;
  bool refreshOk = true;
  int proofs = 0;
  final refreshed = <String?>[];
  final _loggedOut = StreamController<AccountIdentity>.broadcast();

  void notify() => notifyListeners();

  @override
  AccountIdentity? get activeIdentity => identity;
  @override
  SessionView? get activeSession => identity == null ? null : SessionView(loginId: identity!.loginId, name: '同学甲', className: '');
  @override
  int get generation => 1;
  @override
  Stream<AccountIdentity> get loggedOut => _loggedOut.stream;
  @override
  Future<LegacyImportState> legacyImportState() async => const LegacyImportState(available: false);
  @override
  Future<GatewayResult<KingoSignInProof>> appAccountProof({String? password}) async {
    proofs++;
    final secret = password ?? remembered;
    if (secret == null) return const GatewayResult(ok: false, source: 'local', fetchedAt: '', error: GatewayError(code: 'PASSWORD_NEEDED', message: '要输入一次教务密码'));
    return GatewayResult(ok: true, source: 'local', fetchedAt: '', data: kingoSignInProof(identity!.loginId, secret));
  }
  @override
  Future<GatewayResult<bool>> refreshSession({String? password}) async {
    refreshed.add(password);
    return refreshOk ? const GatewayResult(ok: true, source: 'local', fetchedAt: '', data: true) : const GatewayResult(ok: false, source: 'local', fetchedAt: '', error: GatewayError(code: 'SESSION_EXPIRED', message: ''));
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoUploader implements DiagnosticUploader {
  @override
  Future<DiagnosticReceipt> upload(String archivePath, {void Function(double sent)? onProgress}) => throw UnimplementedError();
}

class _DiagnosticClient implements DiagnosticAccountClient {
  _DiagnosticClient(this.records);
  final List<DiagnosticRecord> records;
  final deleted = <String>[];
  @override
  Future<DiagnosticRecord> claim(AppAccountRef account, String id, String claim) => throw UnimplementedError();
  @override
  Future<List<DiagnosticRecord>> list(AppAccountRef account) async => [...records];
  @override
  Future<void> delete(AppAccountRef account, String id) async {
    deleted.add(id);
    records.removeWhere((record) => record.id == id);
  }
}
