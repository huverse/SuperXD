import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/gateway_code.dart';
import 'package:superxd/edu/kingo_client.dart';
import 'package:superxd/edu/login_rules.dart';
import 'package:superxd/gateway/kingo_auth.dart';
import 'package:superxd/local/app_database.dart';

// 一次登录的暂态 KingoAuth（审查 P2-14：教务登录是最关键的路径之一，以前只测了验证码走通）：验证码、密码错误、输错次数、锁定、
// 教务不给身份、迟到回写、处理中重复提交、各类网络异常与落库。教务一律是合成数据：按顺序回答的假客户端，最后一组走真实客户端加假的教务接口。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  KingoAuth authOf(_ScriptedKingo client) => KingoAuth(client: client, now: () => DateTime.utc(2026, 9, 24, 8));

  test('验证码：停在同一次会话，刷新沿用这次会话，输错再要，输对才成功；会话里没有密码', () async {
    final client = _ScriptedKingo([_needsCaptcha(), _needsCaptcha(hint: '验证码不正确，请重新输入'), _success()]);
    final auth = authOf(client);
    final first = await auth.login('20260000001', 'secret-value');
    expect(first.ok, isTrue);
    expect(first.needsInput, 'captcha');
    expect(first.data?.captcha?.imageBase64, 'aa');
    expect(auth.session, isNull);
    final refreshed = await auth.refreshLoginCaptcha();
    expect(refreshed.ok, isTrue);
    expect(refreshed.data?.imageBase64, 'refreshed');
    final wrong = await auth.submitLoginCaptcha('bad');
    expect(wrong.needsInput, 'captcha');
    expect(wrong.data?.captcha?.hint, '验证码不正确，请重新输入');
    final done = await auth.submitLoginCaptcha('ok');
    expect(done.ok, isTrue);
    expect(done.needsInput, isNull);
    expect(done.data?.session?.loginId, '20260000001');
    expect(client.captchas, ['', 'bad', 'ok']);
    expect(client.accounts.toSet(), {'20260000001'});
    final cookies = jsonDecode(auth.session!.cookieJson) as Map<String, Object?>;
    expect(cookies['pageSession'], 'SESSION');
    expect(cookies['userCode'], 'U1');
    expect((cookies['cookies'] as Map)['JSESSIONID'], 'jar-20260000001');
    expect(auth.session!.cookieJson, isNot(contains('secret-value')));
    expect(auth.session!.savedAt, '2026-09-24T08:00:00.000Z');
    // 成功后暂存的密码已清：再交验证码要重新登录。
    expect((await auth.submitLoginCaptcha('ok')).error?.code, GatewayCode.loginFailed);
  });

  test('密码错误、输错次数、锁定与短信验证：按教务的错误码失败，这次登录整个清掉，之后交验证码或刷新都要重新登录', () async {
    final failures = {
      GatewayCode.passwordWrong: explainLogin('402', '账号或密码有误!', '{}'),
      GatewayCode.passwordWrongCount: explainLogin('402', '密码不正确，已输错1次|1', '{}'),
      GatewayCode.accountLocked: explainLogin('402', '您的账号已被锁定', '{}'),
      GatewayCode.smsRequired: explainLogin('505', '请先完成短信验证', '{}'),
    };
    for (final MapEntry(key: code, value: failure) in failures.entries) {
      final client = _ScriptedKingo([_needsCaptcha(), _failed(failure)]);
      final auth = authOf(client);
      expect((await auth.login('20260000001', 'secret-value')).needsInput, 'captcha');
      final result = await auth.submitLoginCaptcha('ok');
      expect(result.ok, isFalse, reason: code);
      expect(result.error?.code, code);
      expect(result.error?.message, failure.message);
      expect(auth.session, isNull);
      expect(client.jar, isEmpty, reason: '失败后 cookie 清掉');
      expect(client.pageSession, isEmpty);
      expect(client.cancelled, greaterThanOrEqualTo(2), reason: '登录开始一次、失败后又一次取消在途请求');
      expect((await auth.submitLoginCaptcha('ok')).error?.code, GatewayCode.loginFailed);
      expect((await auth.refreshLoginCaptcha()).error?.code, GatewayCode.loginFailed);
      expect(client.captchas, ['', 'ok'], reason: '失败之后不再拿旧密码去试');
    }
    expect(failures[GatewayCode.passwordWrongCount]?.failCount, 1);
  });

  test('教务说要验证码却没给图、没给结果、或登录成功却没给学号与用户号：都不切换账号', () async {
    final cases = <(KingoLoginResult, String)>[
      (const KingoLoginResult(ok: false, needsCaptcha: true, failure: null, captcha: null, loginId: null), GatewayCode.loginFailed),
      (_failed(explainLogin(null, null, '')), GatewayCode.serverUnavailable),
      (_success(loginId: '  '), GatewayCode.upstreamFormat),
      (_success(userCode: ''), GatewayCode.upstreamFormat),
    ];
    for (final (reply, code) in cases) {
      final auth = authOf(_ScriptedKingo([reply]));
      final result = await auth.login('20260000001', 'secret-value');
      expect(result.error?.code, code);
      expect(auth.session, isNull);
      final database = await AppDatabase.openMemory();
      await expectLater(auth.persistSession(database), throwsStateError);
      await database.close();
    }
  });

  test('迟到回写：登录进行中被取消、或被新的一次登录替换，旧结果作废，不碰新一次的会话', () async {
    final cancelled = Completer<KingoLoginResult>();
    final cancelledClient = _ScriptedKingo([cancelled]);
    final cancelledAuth = authOf(cancelledClient);
    final pending = cancelledAuth.login('20260000001', 'secret-value');
    await Future<void>.delayed(Duration.zero);
    cancelledAuth.cancel();
    cancelled.complete(_success());
    expect((await pending).error?.code, GatewayCode.accountChanged);
    expect(cancelledAuth.session, isNull);

    final older = Completer<KingoLoginResult>(), newer = Completer<KingoLoginResult>();
    final client = _ScriptedKingo([older, newer]);
    final auth = authOf(client);
    final first = auth.login('20260000001', 'first-secret');
    await Future<void>.delayed(Duration.zero);
    final second = auth.login('20260000002', 'second-secret');
    await Future<void>.delayed(Duration.zero);
    newer.complete(_success(loginId: '20260000002', userCode: 'U2'));
    expect((await second).data?.session?.loginId, '20260000002');
    older.complete(_success());
    expect((await first).error?.code, GatewayCode.accountChanged);
    expect(auth.session?.loginId, '20260000002', reason: '旧的那次迟到了，不能把新会话换掉');
    expect(client.jar['JSESSIONID'], 'jar-20260000002', reason: '旧的那次失败也不清新一次的 cookie');
  });

  test('处理中再交验证码或刷新：报 LOGIN_BUSY，不打断进行中的那次', () async {
    final slow = Completer<KingoLoginResult>();
    final client = _ScriptedKingo([_needsCaptcha(), slow]);
    final auth = authOf(client);
    await auth.login('20260000001', 'secret-value');
    final submitting = auth.submitLoginCaptcha('ok');
    await Future<void>.delayed(Duration.zero);
    expect((await auth.submitLoginCaptcha('again')).error?.code, GatewayCode.loginBusy);
    expect((await auth.refreshLoginCaptcha()).error?.code, GatewayCode.loginBusy);
    slow.complete(_success());
    expect((await submitting).ok, isTrue);
    expect(client.captchas, ['', 'ok']);
  });

  test('网络与格式异常按类型换成错误码并带堆栈记日志，失败后清掉这次登录；刷新验证码出错同样处理', () async {
    final logged = <String>[];
    final previous = campusLog;
    campusLog = logged.add;
    addTearDown(() => campusLog = previous);
    final cases = <(Object, String, String?)>[
      (TimeoutException('教务请求超时'), GatewayCode.networkTimeout, eduTimeoutMessage),
      (const SocketException('Connection refused'), GatewayCode.networkFailed, eduUnreachableMessage),
      (http.ClientException('Connection closed before full header was received'), GatewayCode.networkFailed, eduUnreachableMessage),
      (const FormatException('坏了'), GatewayCode.upstreamFormat, '教务返回的数据格式异常'),
      (KingoCallException(const LoginFailure(code: GatewayCode.rateLimited, message: '教务限流')), GatewayCode.rateLimited, '教务限流'),
      (StateError('login.action 没有会话'), GatewayCode.loginFailed, '登录未完成，请重试'),
    ];
    for (final (error, code, message) in cases) {
      logged.clear();
      final client = _ScriptedKingo([error]);
      final auth = authOf(client);
      final result = await auth.login('20260000001', 'secret-value');
      expect(result.error?.code, code, reason: '${error.runtimeType}');
      expect(result.error?.message, message);
      expect(client.jar, isEmpty);
      final line = logged.singleWhere((line) => line.startsWith('[KingoAuth] code=$code errorType=${error.runtimeType}'));
      expect(line.split('\n').length, greaterThan(1), reason: '错误带堆栈');
      expect(line, isNot(contains('secret-value')));
    }
    final client = _ScriptedKingo([_needsCaptcha()])..captchaReply = TimeoutException('教务请求超时');
    final auth = authOf(client);
    await auth.login('20260000001', 'secret-value');
    final refreshed = await auth.refreshLoginCaptcha();
    expect(refreshed.error?.code, GatewayCode.networkTimeout);
    expect((await auth.submitLoginCaptcha('ok')).error?.code, GatewayCode.loginFailed, reason: '刷新失败也清掉这次登录');
  });

  test('persistSession：写会话与学期；教务没给学期列表时只记当前学期，两样都没有时只写会话', () async {
    final listed = authOf(_ScriptedKingo([_success(currentXq: '1', terms: const [(xn: '2026', xq: '0', label: '2026-2027学年第一学期'), (xn: '2026', xq: '1', label: '2026-2027学年第二学期')])]));
    await listed.login('20260000001', 'secret-value');
    final listedDatabase = await AppDatabase.openMemory();
    await listed.persistSession(listedDatabase);
    expect((await listedDatabase.readSession())?.loginId, '20260000001');
    expect((await listedDatabase.readSession())?.cookieJson, isNot(contains('secret-value')));
    expect([for (final term in await listedDatabase.terms()) term.key], ['2026-1', '2026-0'], reason: '当前学期排最前');
    // 内存库同一路径共用一份，关掉才是新的一份。
    await listedDatabase.close();

    final currentOnly = authOf(_ScriptedKingo([_success(currentXq: '1')]));
    await currentOnly.login('20260000001', 'secret-value');
    final currentDatabase = await AppDatabase.openMemory();
    await currentOnly.persistSession(currentDatabase);
    expect([for (final term in await currentDatabase.terms()) term.key], ['2026-1']);
    await currentDatabase.close();

    final bare = authOf(_ScriptedKingo([_success(currentXn: '', currentXq: '')]));
    await bare.login('20260000001', 'secret-value');
    final bareDatabase = await AppDatabase.openMemory();
    await bare.persistSession(bareDatabase);
    expect((await bareDatabase.readSession())?.loginId, '20260000001');
    expect(await bareDatabase.terms(), isEmpty);
    await bareDatabase.close();
  });

  test('真实客户端加合成教务接口：密码错误、锁定与验证码三种回答经 KingoAuth 给出对应结果', () async {
    final replies = {
      '{"status":"402","message":"账号或密码有误!"}': GatewayCode.passwordWrong,
      '{"status":"402","message":"您的账号已被锁定"}': GatewayCode.accountLocked,
    };
    for (final MapEntry(key: body, value: code) in replies.entries) {
      final auth = KingoAuth(client: KingoClient(client: _school(body)));
      final result = await auth.login('20260000001', 'secret-value');
      expect(result.error?.code, code, reason: body);
      expect(auth.session, isNull);
    }
    final captcha = KingoAuth(client: KingoClient(client: _school('{"status":"401","message":"验证码不正确"}')));
    final asked = await captcha.login('20260000001', 'secret-value');
    expect(asked.needsInput, 'captcha');
    expect(asked.data?.captcha?.hint, '验证码不正确，请重新输入');
    expect(asked.data?.captcha?.imageBase64, base64Encode(const [0xff, 0xd8, 0xff]));
  });
}

// 合成的教务登录接口：登录页给会话号、两个加密脚本与临时密钥、时间戳照常回，logon.action 回给定的 JSON，验证码图是三个字节。
MockClient _school(String logon) => MockClient((request) async {
  final path = request.url.path;
  if (path.endsWith('/cas/login.action')) return http.Response('var _ssessionid = "SESSION";', 200, headers: {'content-type': 'text/html; charset=utf-8'});
  if (path.endsWith('/cas/logon.action')) return http.Response(logon, 200, headers: {'content-type': 'application/json'});
  if (path.endsWith('/cas/genValidateCode')) return http.Response.bytes(const [0xff, 0xd8, 0xff], 200, headers: {'content-type': 'image/jpeg'});
  if (request.url.queryParameters['method'] == 'getTempDeskey') return http.Response('a1b2c3d4e5f6a7b8', 200);
  if (request.url.queryParameters['method'] == 'getTempNowtime') return http.Response('1790000000000', 200);
  return http.Response('', 200);
});

const _captchaImage = CaptchaViewData(prompt: '请输入图中的验证码', hint: '请输入图中的验证码', contentType: 'image/jpeg', imageBase64: 'refreshed');

KingoLoginResult _needsCaptcha({String hint = '请输入图中的验证码'}) => KingoLoginResult(
  ok: false,
  needsCaptcha: true,
  failure: null,
  captcha: CaptchaViewData(prompt: '请输入图中的验证码', hint: hint, contentType: 'image/jpeg', imageBase64: 'aa'),
  loginId: null,
);

KingoLoginResult _failed(LoginFailure failure) => KingoLoginResult(ok: false, needsCaptcha: false, failure: failure, captcha: null, loginId: null);

KingoLoginResult _success({
  String loginId = '20260000001',
  String userCode = 'U1',
  String currentXn = '2026',
  String currentXq = '0',
  List<({String xn, String xq, String label})> terms = const [],
}) => KingoLoginResult(ok: true, needsCaptcha: false, failure: null, captcha: null, loginId: loginId, userCode: userCode, currentXn: currentXn, currentXq: currentXq, terms: terms);

// 按顺序回答登录的假教务客户端：每次 login 取下一项（结果、挂起的 Completer，或别的就当异常抛出），记下带的账号与验证码。
class _ScriptedKingo extends KingoClient {
  _ScriptedKingo(this.replies);
  final List<Object> replies;
  final accounts = <String>[], captchas = <String>[];
  Object captchaReply = _captchaImage;
  int cancelled = 0;

  @override
  Future<KingoLoginResult> login(String username, String password, {String captcha = ''}) async {
    accounts.add(username);
    captchas.add(captcha);
    pageSession = 'SESSION';
    jar['JSESSIONID'] = 'jar-$username';
    final reply = replies.removeAt(0);
    if (reply is Completer<KingoLoginResult>) return reply.future;
    if (reply is KingoLoginResult) return reply;
    throw reply;
  }

  @override
  Future<CaptchaViewData> fetchCaptcha() async {
    final reply = captchaReply;
    if (reply is CaptchaViewData) return reply;
    throw reply;
  }

  @override
  void cancelRequests() {
    cancelled++;
    super.cancelRequests();
  }
}
