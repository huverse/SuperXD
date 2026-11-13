import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/application/auto_sync.dart';
import 'package:superxd/domain/auto_sync.dart';
import 'package:superxd/edu/kingo_client.dart';
import 'package:superxd/edu/kingo_codec.dart';
import 'package:superxd/edu/login_rules.dart';
import 'package:superxd/edu/parse_schedule.dart';
import 'package:superxd/edu/parse_terms.dart';
import 'package:superxd/gateway/account_gateway.dart';
import 'package:superxd/local/account_store.dart';
import 'package:superxd/local/credential_store.dart';
import 'package:superxd/domain/schedule_store.dart';

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

  // 人工决策见 domain/auto_sync.dart：登录过期时不打断、只暂停。以前网关一遇到失效就清本机会话，
  // 后台试一次之后下次冷启动直接停在登录页，看不了本机课表；手动操作才按原规则重新登录。
  group('自动同步遇到登录过期', () {
    AutoSync autoSyncOf() => AutoSync(gateway: gateway, clock: () => DateTime.utc(2026, 11, 5));

    Future<void> enable() async {
      await gateway.saveAutoSyncSetting(const AutoSyncSetting(enabled: true, years: {'2026'}, contents: {SyncContent.schedule}));
    }

    test('没记住账号：本机会话留着，只记暂停；冷启动照常进应用', () async {
      await gateway.login('A', 'test-secret');
      await enable();
      clients.single.failure = 'SESSION_EXPIRED';
      final generation = gateway.generation;
      await autoSyncOf().runIfDue();
      expect((await gateway.readAutoSync()).data!.status.state, AutoSyncState.paused);
      expect(gateway.generation, generation, reason: '不换代次，页面不重建');
      expect(gateway.activeSession?.loginId, 'A', reason: '不退出登录');

      final restarted = AccountGateway(store: await AccountStore.open(directory: directory.path), clientFactory: _Client.new);
      addTearDown(restarted.close);
      expect((await restarted.restoreLocalSession()).data?.loginId, 'A', reason: '下次打开还能看本机数据');
    });

    test('之后手动同步仍报失效（由页面转登录）：这时才清本机会话', () async {
      await gateway.login('A', 'test-secret');
      await enable();
      clients.single.failure = 'SESSION_EXPIRED';
      await autoSyncOf().runIfDue();
      expect((await gateway.syncSchedule(_term)).error?.code, 'SESSION_EXPIRED');
      final restarted = AccountGateway(store: await AccountStore.open(directory: directory.path), clientFactory: _Client.new);
      addTearDown(restarted.close);
      expect((await restarted.restoreLocalSession()).ok, isFalse);
    });

    test('记住了账号且恢复成功：用新会话接着同步，不算暂停', () async {
      await gateway.loginRemembered('A', 'test-secret', remember: true);
      await enable();
      clients.single.failure = 'SESSION_EXPIRED';
      await autoSyncOf().runIfDue();
      expect(clients, hasLength(2));
      expect((await gateway.readAutoSync()).data!.status.state, AutoSyncState.ok);
    });

    test('记住了账号但自动登录要验证码：不打断，本机会话留着', () async {
      await gateway.loginRemembered('A', 'test-secret', remember: true);
      await enable();
      clients.single.failure = 'SESSION_EXPIRED';
      nextClient = () => _Client()..loginFailure = 'captcha';
      await autoSyncOf().runIfDue();
      expect((await gateway.readAutoSync()).data!.status.state, AutoSyncState.paused);
      expect(gateway.activeSession?.loginId, 'A');
      final restarted = AccountGateway(store: await AccountStore.open(directory: directory.path), clientFactory: _Client.new);
      addTearDown(restarted.close);
      expect((await restarted.restoreLocalSession()).data?.loginId, 'A');
    });

    test('自动同步里自动重登没成（要验证码）只算这一轮：之后手动同步照常再自动重登一次', () async {
      await gateway.loginRemembered('A', 'test-secret', remember: true);
      await enable();
      clients.single.failure = 'SESSION_EXPIRED';
      nextClient = () => _Client()..loginFailure = 'captcha';
      await autoSyncOf().runIfDue();
      expect((await gateway.readAutoSync()).data!.status.state, AutoSyncState.paused);
      nextClient = _Client.new;
      final manual = await gateway.syncSchedule(_term);
      expect(manual.ok, isTrue, reason: '手动同步的那次自动重登没被自动同步用掉');
      expect(clients, hasLength(3));
    });

    test('另一份引擎退出了这个账号（账号索引里不再是它）：不把会话写回去', () async {
      await gateway.login('A', 'test-secret');
      await enable();
      final other = await AccountStore.open(directory: directory.path);
      addTearDown(other.close);
      final identity = (await other.currentIdentity())!;
      final old = clients.single..failure = 'SESSION_EXPIRED';
      old.beforeRead = () async {
        old.beforeRead = null;
        await other.clearCurrent();
      };
      await autoSyncOf().runIfDue();
      final database = await other.openAccount(identity);
      addTearDown(database.close);
      expect(await database.readSession(), isNull, reason: '退出就是退出，另一份引擎的也算');
    });

    test('自动同步期间用户退出了：不把会话写回去', () async {
      await gateway.login('A', 'test-secret');
      await enable();
      final old = clients.single..failure = 'SESSION_EXPIRED';
      var logoutDone = false;
      old.beforeRead = () async {
        old.beforeRead = null;
        unawaited(gateway.logout().then((_) => logoutDone = true));
      };
      await autoSyncOf().runIfDue();
      expect(logoutDone, isTrue);
      expect(gateway.activeSession, isNull);
      final restarted = AccountGateway(store: await AccountStore.open(directory: directory.path), clientFactory: _Client.new);
      addTearDown(restarted.close);
      expect((await restarted.restoreLocalSession()).ok, isFalse, reason: '退出就是退出');
    });
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

  test('关闭后原地输密码重新开启：只核对不切换，错了不保存，要验证码时交了才保存', () async {
    await gateway.loginRemembered('A', 'test-secret', remember: false);
    final generation = gateway.generation;
    final session = gateway.activeSession;
    expect(await gateway.isRemembered(), isFalse);
    expect((await gateway.rememberWithPassword('wrong')).error?.code, 'PASSWORD_WRONG');
    expect(await gateway.isRemembered(), isFalse);
    final captcha = await gateway.rememberWithPassword('captcha');
    expect(captcha.needsInput, 'captcha');
    expect(await gateway.isRemembered(), isFalse);
    expect((await gateway.submitLoginCaptcha('1234')).ok, isTrue);
    expect(await gateway.isRemembered(), isTrue);
    expect(credentials.values.values.single.password, 'captcha');
    // 不换会话、不加代次；核对用的客户端用完即弃，当前会话照常同步。
    expect(gateway.generation, generation);
    expect(identical(gateway.activeSession, session), isTrue);
    expect((await gateway.syncSchedule(_term)).ok, isTrue);
    expect(clients.first.reads, 1);
    expect(clients.skip(1).every((client) => client.reads == 0), isTrue);
  });

  // 应用账号（人工决策见 domain/app_account.dart）：网关只往上给口令摘要；中转代登录挤掉本机会话后，用同一个密码重登，不换代次。
  group('应用账号核对', () {
    test('口令摘要：给了密码用它，没给用记住的，都没有要输密码', () async {
      await gateway.loginRemembered('A', 'test-secret', remember: false);
      expect((await gateway.appAccountProof()).error?.code, 'PASSWORD_NEEDED');
      final given = await gateway.appAccountProof(password: 'typed-secret');
      expect(given.data?.toJson(), kingoSignInProof('A', 'typed-secret').toJson());
      await gateway.loginRemembered('A', 'test-secret', remember: true);
      expect((await gateway.appAccountProof()).data?.passwordDigest, hexMd5('test-secret'));
      await gateway.logout();
      expect((await gateway.appAccountProof(password: 'x')).error?.code, 'SESSION_EXPIRED');
    });

    test('重登换上新会话、不换代次；给的密码不对时不删记住的凭据', () async {
      await gateway.loginRemembered('A', 'test-secret', remember: true);
      final generation = gateway.generation;
      final refreshed = await gateway.refreshSession(password: 'typed-secret');
      expect(refreshed.ok, isTrue);
      expect(gateway.generation, generation);
      expect(clients, hasLength(2));
      expect(clients.last.logins, 1);
      expect((await gateway.syncSchedule(_term)).ok, isTrue);
      expect(clients.last.reads, 1);
      expect((await gateway.refreshSession(password: 'wrong')).ok, isFalse);
      expect(credentials.values.values.single.password, 'test-secret');
      // 没给密码用记住的：上一次失败把自动恢复堵上了，这次成功要放开。
      expect((await gateway.refreshSession()).ok, isTrue);
      expect(gateway.generation, generation);
    });

    test('主动退出发出退出事件，会话过期不发', () async {
      final events = <String>[];
      final subscription = gateway.loggedOut.listen((identity) => events.add(identity.loginId));
      await gateway.loginRemembered('A', 'test-secret', remember: false);
      await gateway.expireSession();
      await gateway.loginRemembered('A', 'test-secret', remember: false);
      await gateway.logout();
      await pumpEventQueue();
      expect(events, ['A']);
      await subscription.cancel();
    });
  });

  test('姓名只增不丢：同步课表学到后当前会话立即带上，自动重登与重新登录都沿用', () async {
    final session = AppSession(gateway);
    await gateway.loginRemembered('A', 'test-secret', remember: true);
    // 登录页不给姓名，先显示学号。
    expect(gateway.activeSession?.name, '');
    var notified = 0;
    session.addListener(() => notified++);
    clients.single.name = '张三';
    expect((await gateway.syncSchedule(_term)).ok, isTrue);
    expect(gateway.activeSession?.name, '张三');
    expect(notified, 1);
    // 会话过期整行会话被清、自动重登（新客户端的课表不带姓名）：当前会话与重登后的会话行都留着姓名。
    clients.single.failure = 'SESSION_EXPIRED';
    expect((await gateway.syncSchedule(_term)).ok, isTrue);
    expect(clients, hasLength(2));
    expect(gateway.activeSession?.name, '张三');
    session.dispose();
    await gateway.close();
    store = await AccountStore.open(directory: directory.path);
    gateway = AccountGateway(store: store, credentials: credentials, clientFactory: _Client.new);
    expect((await gateway.restoreSession()).data?.name, '张三');
    // 退出登录清掉会话行后重新登录：姓名从账号索引补回。
    await gateway.logout();
    await gateway.login('A', 'test-secret');
    expect(gateway.activeSession?.name, '张三');
    expect((await gateway.readSchedule(const ScheduleScope.week(term: _term, week: 1))).data?.student.name, '张三');
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
  String name = '';
  bool holdReads = false;
  bool holdLogin = false;
  final twoReads = Completer<void>();
  final readGate = Completer<void>();
  final loginStarted = Completer<void>();
  final loginGate = Completer<void>();
  Future<void> Function()? beforeRead;
  // 刷新学期：自动同步每轮先走它。真实教务在会话失效时 fetchProfile 就报过期，这里交给课表那一步报，免得把用例绑死在第几个请求上。
  @override
  Future<KingoProfile> fetchProfile() async => KingoProfile(userCode: 'internal-A', xn: _term.xn, xq: _term.xq, loginId: 'A');
  @override
  Future<({List<ParsedTerm> terms, ({String xn, String xq})? published})> listTerms() async => (terms: [ParsedTerm(xn: _term.xn, xq: _term.xq, label: '合成学期', code: '')], published: null);
  @override
  Future<KingoLoginResult> login(String username, String password, {String captcha = ''}) async {
    logins++;
    if (!loginStarted.isCompleted) loginStarted.complete();
    if (holdLogin) await loginGate.future;
    final rejected = loginFailure ?? (password == 'wrong' ? 'PASSWORD_WRONG' : password == 'captcha' && captcha.isEmpty ? 'captcha' : null);
    if (rejected == 'captcha') return const KingoLoginResult(ok: false, needsCaptcha: true, failure: null, captcha: CaptchaViewData(prompt: '验证码', hint: '', contentType: 'image/png', imageBase64: ''), loginId: null);
    if (rejected != null) return KingoLoginResult(ok: false, needsCaptcha: false, failure: LoginFailure(code: rejected, message: '需要手动登录'), captcha: null, loginId: null);
    jar['JSESSIONID'] = 'test-cookie-$username';
    return KingoLoginResult(ok: true, needsCaptcha: false, failure: null, captcha: null, loginId: username, userCode: 'internal-$username', currentXn: _term.xn, currentXq: _term.xq, terms: [(xn: _term.xn, xq: _term.xq, label: '')]);
  }
  @override
  Future<ParsedSchedule> fetchSchedule({required String xn, required String xq, required String userCode}) async {
    reads++;
    await beforeRead?.call();
    if (holdReads) {
      if (reads == 2) twoReads.complete();
      await readGate.future;
      throw KingoCallException(const LoginFailure(code: 'SESSION_EXPIRED', message: 'test expired'));
    }
    if (failure != null) throw KingoCallException(LoginFailure(code: failure!, message: 'test failure'));
    return ParsedSchedule(termLabel: '', loginId: 'A', name: name, className: '', courses: const []);
  }
}
