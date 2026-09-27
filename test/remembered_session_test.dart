import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/edu/kingo_client.dart';
import 'package:superxd/edu/login_rules.dart';
import 'package:superxd/edu/parse_schedule.dart';
import 'package:superxd/gateway/account_gateway.dart';
import 'package:superxd/local/account_store.dart';
import 'package:superxd/local/credential_store.dart';
import 'package:superxd/local/schedule_store.dart';

const _term = TermRef(xn: '2026', xq: '0');

void main() {
  setUpAll(() { sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; });
  late Directory directory;
  late AccountStore store;
  late AccountGateway gateway;
  late _Credentials credentials;
  late List<_Client> clients;
  late _Client Function() nextClient;
  setUp(() async {
    directory = await Directory(Platform.environment['CLAUDE_JOB_DIR'] == null ? Directory.systemTemp.path : '${Platform.environment['CLAUDE_JOB_DIR']}/tmp').createTemp('remembered-');
    store = await AccountStore.open(directory: directory.path);
    credentials = _Credentials();
    clients = [];
    nextClient = _Client.new;
    gateway = AccountGateway(store: store, credentials: credentials, clientFactory: () { final client = nextClient(); clients.add(client); return client; });
  });
  tearDown(() async { await gateway.close(); await directory.delete(recursive: true); });

  test('明确开启且认证成功才保存；错误、验证码取消、不记住均不保存新凭据', () async {
    expect((await gateway.loginRemembered('A', 'test-secret', remember: true)).ok, isTrue);
    final key = store.keyOf(gateway.activeIdentity!);
    expect(credentials.values[key]?.password, 'test-secret');
    expect((await gateway.loginRemembered('B', 'wrong', remember: true)).ok, isFalse);
    expect(credentials.values.keys, [key]);
    expect((await gateway.loginRemembered('B', 'captcha', remember: true)).needsInput, 'captcha');
    await gateway.cancelLogin();
    expect(credentials.values.keys, [key]);
    expect((await gateway.loginRemembered('B', 'test-secret', remember: false)).ok, isTrue);
    expect(await gateway.isRemembered(), isFalse);
    expect(credentials.values.keys, [key]);
    expect((await gateway.loginRemembered('A', 'test-secret', remember: false)).ok, isTrue);
    expect(credentials.values, isEmpty);
  });

  test('并发失效合并一次认证，每个读取仅重放一次且generation不变', () async {
    await gateway.loginRemembered('A', 'test-secret', remember: true);
    final old = clients.single..holdReads = true;
    final generation = gateway.generation;
    final first = gateway.syncSchedule(_term);
    final second = gateway.syncSchedule(_term);
    await old.twoReads.future;
    old.readGate.complete();
    final results = await Future.wait([first, second]).timeout(const Duration(seconds: 3));
    expect(results.every((result) => result.ok), isTrue);
    expect(clients, hasLength(2));
    expect(clients.last.logins, 1);
    expect(old.reads, 2);
    expect(clients.last.reads, 2);
    expect(gateway.generation, generation);
    expect((await gateway.restoreSession()).data?.loginId, 'A');
  });

  test('恢复中新增读取复用同一认证，不用旧cookie发送', () async {
    await gateway.loginRemembered('A', 'test-secret', remember: true);
    clients.single.failure = 'SESSION_EXPIRED';
    final recovery = _Client()..holdLogin = true;
    nextClient = () => recovery;
    final first = gateway.syncSchedule(_term);
    await recovery.loginStarted.future;
    final second = gateway.syncSchedule(_term);
    recovery.loginGate.complete();
    expect((await first).ok, isTrue);
    expect((await second).ok, isTrue);
    expect(clients.first.reads, 1);
    expect(recovery.reads, 2);
    expect(recovery.logins, 1);
  });

  test('重放仍失效不再次认证；格式错误和超时不触发认证', () async {
    await gateway.loginRemembered('A', 'test-secret', remember: true);
    for (final failure in ['UPSTREAM_FORMAT', 'NETWORK_TIMEOUT']) {
      clients.first.failure = failure;
      expect((await gateway.syncSchedule(_term)).error?.code, failure);
      expect(clients, hasLength(1));
    }
    clients.first.failure = 'SESSION_EXPIRED';
    nextClient = () => _Client()..failure = 'SESSION_EXPIRED';
    expect((await gateway.syncSchedule(_term)).error?.code, 'SESSION_EXPIRED');
    expect((await gateway.syncSchedule(_term)).error?.code, 'SESSION_EXPIRED');
    expect(clients, hasLength(2));
    expect(clients.last.logins, 1);
  });

  for (final failure in ['PASSWORD_WRONG', 'ACCOUNT_LOCKED', 'captcha']) {
    test('自动登录遇到$failure停止并转人工，不循环', () async {
      await gateway.loginRemembered('A', 'test-secret', remember: true);
      clients.first.failure = 'SESSION_EXPIRED';
      nextClient = () => _Client()..loginFailure = failure;
      final result = await gateway.syncSchedule(_term);
      expect(result.error?.code, 'SESSION_EXPIRED');
      if (failure == 'captcha') {
        expect(result.error?.message, contains('验证码'));
        expect(await gateway.isRemembered(), isTrue);
      } else {
        expect(await gateway.isRemembered(), isFalse);
      }
      await gateway.syncSchedule(_term);
      expect(clients, hasLength(2));
      expect(clients.last.logins, 1);
    });
  }

  for (final action in ['logout', 'forget', 'switch']) {
    test('恢复中$action使迟到认证失效，不复活旧账号', () async {
      await gateway.loginRemembered('A', 'test-secret', remember: true);
      final key = store.keyOf(gateway.activeIdentity!);
      clients.first.failure = 'SESSION_EXPIRED';
      final recovery = _Client()..holdLogin = true;
      nextClient = () => recovery;
      final syncing = gateway.syncSchedule(_term);
      await recovery.loginStarted.future;
      if (action == 'logout') {
        await gateway.logout();
      } else if (action == 'forget') {
        await gateway.forgetCredential();
      } else {
        nextClient = _Client.new;
        await gateway.loginRemembered('B', 'test-secret', remember: false);
      }
      final generation = gateway.generation;
      recovery.loginGate.complete();
      expect((await syncing).ok, isFalse);
      expect(gateway.generation, generation);
      expect(gateway.activeSession?.loginId, action == 'logout' ? null : action == 'forget' ? 'A' : 'B');
      if (action != 'switch') expect(credentials.values[key], isNull);
    });
  }

  test('安全存储写入期间取消，旧凭据、旧session和活动索引全部保留', () async {
    await gateway.loginRemembered('A', 'old-secret', remember: true);
    final key = store.keyOf(gateway.activeIdentity!);
    credentials.holdWrite = true;
    final switching = gateway.loginRemembered('A', 'new-secret', remember: true);
    await credentials.writeStarted.future;
    await gateway.cancelLogin();
    credentials.writeGate.complete();
    expect((await switching).ok, isFalse);
    expect(credentials.values[key]?.password, 'old-secret');
    expect((await store.currentIdentity())?.loginId, 'A');
    expect((await gateway.restoreSession()).data?.loginId, 'A');
    expect((await gateway.listTerms()).ok, isTrue);
  });

  test('安全存储失败不降级明文且保留成功登录；退出清除失败不冻结账号', () async {
    credentials.failWrite = true;
    final session = AppSession(gateway);
    expect((await gateway.loginRemembered('A', 'test-secret', remember: true)).ok, isTrue);
    expect(credentials.values, isEmpty);
    expect(session.takeNotice(), contains('不会降级为明文'));
    credentials.failDelete = true;
    await expectLater(gateway.logout(), throwsStateError);
    expect((await gateway.listTerms()).ok, isTrue);
    session.dispose();
  });

  test('主动退出删除凭据但保留课程版本，重启不会自动登录', () async {
    await gateway.loginRemembered('A', 'test-secret', remember: true);
    await gateway.saveScheduleRevision(_term, [], '保留版本', expectedRevisionId: null);
    await gateway.logout();
    expect(credentials.values, isEmpty);
    expect(await store.currentIdentity(), isNull);
    final count = clients.length;
    expect((await gateway.restoreSession()).ok, isFalse);
    expect(clients.length, count);
    await gateway.login('A', 'test-secret');
    expect((await gateway.listScheduleRevisions(_term)).data!.single.summary, '保留版本');
  });

  test('冷启动读取安全凭据期间退出，不得迟到自动登录', () async {
    await gateway.loginRemembered('A', 'test-secret', remember: true);
    final identity = gateway.activeIdentity!;
    await gateway.close();
    store = await AccountStore.open(directory: directory.path);
    final database = await store.openAccount(identity);
    await database.clearSession();
    await database.close();
    clients.clear();
    credentials.holdRead = true;
    gateway = AccountGateway(store: store, credentials: credentials, clientFactory: () { final client = _Client(); clients.add(client); return client; });
    final restoring = gateway.restoreSession();
    await credentials.readStarted.future;
    await gateway.logout();
    credentials.readGate.complete();
    expect((await restoring).ok, isFalse);
    expect(gateway.activeSession, isNull);
    expect(await store.currentIdentity(), isNull);
    expect(clients.where((client) => client.logins > 0), isEmpty);
  });

  for (final failure in [null, 'PASSWORD_WRONG', 'captcha']) {
    test('冷启动缺本地会话时最多恢复一次：${failure ?? '成功'}', () async {
      await gateway.loginRemembered('A', 'test-secret', remember: true);
      final identity = gateway.activeIdentity!;
      await gateway.close();
      store = await AccountStore.open(directory: directory.path);
      final database = await store.openAccount(identity);
      await database.clearSession();
      await database.close();
      clients.clear();
      gateway = AccountGateway(store: store, credentials: credentials, clientFactory: () { final client = _Client()..loginFailure = failure; clients.add(client); return client; });
      final session = AppSession(gateway);
      await session.restore();
      expect(clients.where((client) => client.logins > 0).length, 1);
      expect(session.loggedIn, failure == null);
      if (failure != null) {
        expect(session.takeNotice(), isNotNull);
        expect(await store.currentIdentity(), isNull);
        if (failure == 'PASSWORD_WRONG') expect(credentials.values, isEmpty);
      }
      await gateway.restoreSession();
      expect(clients.where((client) => client.logins > 0).length, 1);
      session.dispose();
    });
  }
}

class _Credentials implements CredentialStore {
  final values = <String, RememberedCredential>{};
  bool holdWrite = false;
  bool holdRead = false;
  final readStarted = Completer<void>();
  final readGate = Completer<void>();
  bool failWrite = false;
  bool failDelete = false;
  final writeStarted = Completer<void>();
  final writeGate = Completer<void>();
  @override
  Future<RememberedCredential?> read(String accountKey) async {
    if (holdRead) { holdRead = false; readStarted.complete(); await readGate.future; }
    return values[accountKey];
  }
  @override
  Future<void> write(String accountKey, RememberedCredential credential) async {
    if (failWrite) throw StateError('test storage unavailable');
    if (holdWrite) { holdWrite = false; writeStarted.complete(); await writeGate.future; }
    values[accountKey] = credential;
  }
  @override
  Future<void> delete(String accountKey) async {
    if (failDelete) throw StateError('test delete unavailable');
    values.remove(accountKey);
  }
}

class _Client extends KingoClient {
  _Client() : super(base: 'https://school.example/edu');
  int logins = 0;
  int reads = 0;
  String? failure;
  String? loginFailure;
  bool holdReads = false;
  bool holdLogin = false;
  final twoReads = Completer<void>();
  final readGate = Completer<void>();
  final loginStarted = Completer<void>();
  final loginGate = Completer<void>();
  @override
  Future<KingoLoginResult> login(String username, String password, {String captcha = ''}) async {
    logins++;
    loginStarted.complete();
    if (holdLogin) await loginGate.future;
    final rejected = loginFailure ?? (password == 'wrong' ? 'PASSWORD_WRONG' : password == 'captcha' ? 'captcha' : null);
    if (rejected == 'captcha') return const KingoLoginResult(ok: false, needsCaptcha: true, failure: null, captcha: CaptchaViewData(prompt: '验证码', hint: '', contentType: 'image/png', imageBase64: ''), loginId: null);
    if (rejected != null) return KingoLoginResult(ok: false, needsCaptcha: false, failure: LoginFailure(code: rejected, message: '需要手动登录'), captcha: null, loginId: null);
    jar['JSESSIONID'] = 'test-cookie-$username';
    return KingoLoginResult(ok: true, needsCaptcha: false, failure: null, captcha: null, loginId: username, userCode: 'internal-$username', currentXn: _term.xn, currentXq: _term.xq, terms: [(xn: _term.xn, xq: _term.xq, label: '')]);
  }
  @override
  Future<ParsedSchedule> fetchSchedule({required String xn, required String xq, required String userCode}) async {
    reads++;
    if (holdReads) {
      if (reads == 2) twoReads.complete();
      await readGate.future;
      throw KingoCallException(const LoginFailure(code: 'SESSION_EXPIRED', message: 'test expired'));
    }
    if (failure != null) throw KingoCallException(LoginFailure(code: failure!, message: 'test failure'));
    return const ParsedSchedule(termLabel: '', loginId: 'A', name: '', className: '', courses: []);
  }
}
