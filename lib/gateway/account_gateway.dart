import 'dart:async';

import 'package:synchronized/synchronized.dart';

import 'package:superxd/gateway/kingo_auth.dart';
import 'package:superxd/edu/kingo_client.dart';
import 'package:superxd/gateway/account_access.dart';
import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/gateway/kingo_campus_gateway.dart';
import 'package:superxd/local/account_store.dart';
import 'package:superxd/local/app_database.dart';
import 'package:superxd/local/credential_store.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/campus_log.dart';

// 门面只选择固定账号上下文；协议、缓存和课表业务仍由原网关负责。
class AccountGateway extends AccountAccess {
  AccountGateway({required this.store, this.clientFactory, this.credentials, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final AccountStore store;
  final CredentialStore? credentials;
  String? _accountNotice;
  int _recoveryEpoch = 0;
  KingoClient? _recoveryClient;
  bool _restoreAttempted = false;

  @override
  String? takeAccountNotice() { final notice = _accountNotice; _accountNotice = null; return notice; }

  @override
  Future<bool> isRemembered() async {
    final identity = activeIdentity;
    return identity != null && await credentials?.read(store.keyOf(identity)) != null;
  }

  void _cancelRecovery() { _recoveryEpoch++; _recoveryClient?.dispose(); _recoveryClient = null; }

  @override
  Future<void> forgetCredential() async {
    final identity = activeIdentity;
    _cancelRecovery();
    if (identity != null) await credentials?.delete(store.keyOf(identity));
  }
  final KingoClient Function()? clientFactory;
  final DateTime Function() _now;
  final Lock _transition = Lock();
  _AccountContext? _active;
  _PendingLogin? _pending;
  int _generation = 0;
  int _attemptEpoch = 0;
  bool _changing = false;
  bool _closed = false;

  @override
  int get generation => _generation;
  @override
  SessionView? get activeSession => _active?.session;
  @override
  AccountIdentity? get activeIdentity => _active?.identity;

  KingoClient _newClient({String? source}) => clientFactory?.call() ?? KingoClient(base: source ?? kingoBase);

  @override
  Future<GatewayResult<SessionView>> restoreSession() async {
    final result = await _restoreLocal();
    if (result.ok || _restoreAttempted || _active != null || credentials == null) return result;
    _restoreAttempted = true;
    final identity = await store.currentIdentity();
    if (identity == null) return result;
    final epoch = _recoveryEpoch;
    try {
      final saved = await credentials!.read(store.keyOf(identity));
      if (saved == null || _closed || epoch != _recoveryEpoch) return result;
      final login = await _login(saved.account, saved.password, source: identity.source, expected: identity);
      if (!login.ok || login.needsInput != null) {
        final code = login.error?.code;
        if (code == 'ACCOUNT_CHANGED') return result;
        await cancelLogin();
        await _transition.synchronized(() async {
          if (_active != null || _pending != null) return;
          if (code == 'PASSWORD_WRONG' || code == 'PASSWORD_WRONG_COUNT' || code == 'ACCOUNT_LOCKED') await credentials!.delete(store.keyOf(identity));
          // 转人工后不再沿活动指针在下次启动反复尝试同一份凭据。
          await store.clearCurrent();
          _accountNotice = login.needsInput == 'captcha' ? '自动登录需要验证码，请手动登录完成验证。' : '自动登录未完成：${login.error?.message ?? '请手动登录'}';
        });
        return result;
      }
      return _ok(login.data!.session!);
    } catch (error, stack) {
      campusLog('[AccountGateway] action=auto_restore errorType=${error.runtimeType}\n$stack');
      _accountNotice = '保存的鉴权数据不可用，请手动登录。';
      return result;
    }
  }

  Future<GatewayResult<SessionView>> _restoreLocal() => _guard(() => _transition.synchronized(() async {
    if (_closed) return _loginRequired();
    final active = _active;
    if (active != null) return _ok(active.session);
    final identity = await store.currentIdentity();
    if (identity == null) return _loginRequired();
    final database = await store.openAccount(identity);
    final client = _newClient(source: identity.source);
    var retained = false;
    try {
      if (store.keyOf(AccountIdentity(source: client.base, loginId: identity.loginId)) != store.keyOf(identity)) {
        return _fail('ACCOUNT_SOURCE_CHANGED', '教务来源已变化，请重新登录');
      }
      final gateway = KingoCampusGateway(database: database, client: client, now: _now);
      final restored = await gateway.restoreSession();
      if (!restored.ok || restored.data == null || restored.data!.loginId != identity.loginId) {
        return _loginRequired();
      }
      _active = _AccountContext(identity: identity, session: restored.data!, gateway: gateway);
      retained = true;
      _generation++;
      notifyListeners();
      return restored;
    } finally {
      if (!retained) {
        client.dispose();
        await database.close();
      }
    }
  }));

  @override
  Future<GatewayResult<LoginView>> login(String account, String password) => _login(account, password);

  @override
  Future<GatewayResult<LoginView>> loginRemembered(String account, String password, {required bool remember}) => _login(account, password, remember: remember);

  Future<GatewayResult<LoginView>> _login(String account, String password, {bool? remember, String? source, AccountIdentity? expected}) {
    _cancelRecovery();
    return _guard(() async {
    final pending = await _transition.synchronized(() {
      if (_closed) return null;
      _cancelPending();
      final candidate = _PendingLogin(epoch: _attemptEpoch, auth: KingoAuth(client: _newClient(source: source), now: _now), remember: remember, credential: remember == true ? RememberedCredential(account: account, password: password) : null, expected: expected);
      _pending = candidate;
      return candidate;
    });
    if (pending == null) return _loginRequired();
    return _finishLogin(pending, await pending.auth.login(account, password));
    });
  }

  @override
  Future<GatewayResult<LoginView>> submitLoginCaptcha(String code) => _guard(() async {
    final pending = _pending;
    if (pending == null || _closed) return _fail('LOGIN_FAILED', '请重新登录');
    return _finishLogin(pending, await pending.auth.submitLoginCaptcha(code));
  });

  @override
  Future<GatewayResult<CaptchaView>> refreshLoginCaptcha() => _guard(() async {
    final pending = _pending;
    if (pending == null || _closed) return _fail('LOGIN_FAILED', '请重新登录');
    final result = await pending.auth.refreshLoginCaptcha();
    return _transition.synchronized(() {
      if (!_isPending(pending)) return _changed<CaptchaView>();
      if (!result.ok && result.error?.code != 'LOGIN_BUSY') _cancelPending();
      return result;
    });
  });

  bool _isPending(_PendingLogin pending) => !_closed && identical(_pending, pending) && pending.epoch == _attemptEpoch;

  Future<GatewayResult<LoginView>> _finishLogin(_PendingLogin pending, GatewayResult<LoginView> result) => _transition.synchronized(() async {
    if (!_isPending(pending)) return _changed();
    if (result.needsInput != null || result.error?.code == 'LOGIN_BUSY') return result;
    final authenticated = pending.auth.session;
    if (!result.ok || authenticated == null) {
      _cancelPending();
      return result;
    }
    final identity = AccountIdentity(source: pending.auth.client.base, loginId: authenticated.loginId);
    if (pending.expected != null && store.keyOf(identity) != store.keyOf(pending.expected!)) { _cancelPending(); return _fail('ACCOUNT_MISMATCH', '自动登录身份不一致，已停止'); }
    final old = _active;
    final sameAccount = old != null && store.keyOf(old.identity) == store.keyOf(identity);
    AppDatabase? database;
    SavedSession? previousSession;
    AccountIdentity? previousIdentity;
    var sessionWritten = false;
    var indexWritten = false;
    RememberedCredential? previousCredential;
    var credentialWritten = false;
    var committed = false;
    void checkAttempt() {
      if (!_isPending(pending)) throw const _CancelledAccountSwitch();
    }
    _changing = true;
    try {
      // 所有旧任务固定绑定旧库；同账号也要 drain，避免旧失效响应清除新会话。
      await _pause(old);
      checkAttempt();
      database = sameAccount ? old.gateway.database : await store.openAccount(identity);
      checkAttempt();
      previousSession = await database.readSession();
      previousIdentity = await store.currentIdentity();
      checkAttempt();
      sessionWritten = true;
      await pending.auth.persistSession(database);
      checkAttempt();
      await store.activate(identity, displayName: authenticated.displayName);
      indexWritten = true;
      checkAttempt();
      if (pending.remember != null) {
        try {
          if (credentials == null && pending.remember == true) throw StateError('安全存储不可用');
          previousCredential = await credentials?.read(store.keyOf(identity));
          checkAttempt();
          credentialWritten = credentials != null;
          if (pending.remember == true) {
            await credentials!.write(store.keyOf(identity), pending.credential!);
          } else {
            await credentials?.delete(store.keyOf(identity));
          }
        } on _CancelledAccountSwitch {
          rethrow;
        } catch (error, stack) {
          campusLog('[AccountGateway] action=remember errorType=${error.runtimeType}\n$stack');
          _accountNotice = '已登录，但记住账号设置未能保存；不会降级为明文保存。';
        }
        pending.credential = null;
      }
      checkAttempt();
      final gateway = KingoCampusGateway(database: database, client: pending.auth.client, now: _now);
      _active = _AccountContext(identity: identity, session: result.data!.session!, gateway: gateway);
      _pending = null;
      _generation++;
      committed = true;
      if (old != null) {
        old.gateway.client.dispose();
        if (!sameAccount) await old.gateway.database.close();
      }
      return result;
    } catch (error, stack) {
      campusLog('[AccountGateway] action=activate errorType=${error.runtimeType}\n$stack');
      if (!committed) {
        if (identical(_pending, pending)) _cancelPending();
        if (credentialWritten) {
          final savedCredential = previousCredential;
          if (savedCredential == null) {
            await credentials!.delete(store.keyOf(identity));
          } else {
            await credentials!.write(store.keyOf(identity), savedCredential);
          }
        }
        if (sessionWritten && database != null) {
          final saved = previousSession;
          if (saved == null) {
            await database.clearSession();
          } else {
            await database.writeSession(saved);
          }
        }
        if (indexWritten) {
          final identity = previousIdentity;
          if (identity == null) {
            await store.clearCurrent();
          } else {
            await store.activate(identity);
          }
        }
        if (database != null && !sameAccount) await database.close();
        old?.accepting = true;
      }
      return error is _CancelledAccountSwitch ? _changed() : _fail('LOCAL_STORAGE_FAILED', '账号切换未完成，请重试');
    } finally {
      _changing = false;
      if (committed) notifyListeners();
    }
  });

  void _cancelPending() {
    _attemptEpoch++;
    final pending = _pending;
    _pending = null;
    if (pending == null) return;
    pending.credential = null;
    pending.auth.cancel();
    pending.auth.client.dispose();
  }

  @override
  Future<void> cancelLogin() {
    // 取消必须立即使attempt失效，不能排在正在等待旧任务的切换锁后面。
    _cancelPending();
    return Future.value();
  }

  Future<void> _pause(_AccountContext? context) async {
    if (context == null) return;
    context.accepting = false;
    context.gateway.client.cancelRequests();
    await context.drain();
  }

  @override
  Future<void> logout() { _cancelRecovery(); return _logout(forget: true); }

  @override
  Future<void> expireSession() { _cancelRecovery(); return _logout(forget: false); }

  Future<void> _logout({required bool forget}) => _transition.synchronized(() async {
    if (_closed) return;
    _cancelPending();
    _changing = true;
    final old = _active;
    try {
      await _pause(old);
      if (forget && old != null) await credentials?.delete(store.keyOf(old.identity));
      await old?.gateway.database.clearSession();
      await store.clearCurrent();
      _active = null;
      _generation++;
      if (old != null) {
        old.gateway.client.dispose();
        await old.gateway.database.close();
      }
    } finally {
      _changing = false;
      if (identical(_active, old)) old?.accepting = true;
      if (_active == null) notifyListeners();
    }
  });

  @override
  Future<LegacyImportState> legacyImportState() => _transition.synchronized(() async {
    final active = _active;
    if (_closed || active == null) return const LegacyImportState(available: false);
    return store.legacyState(active.identity);
  });

  @override
  Future<void> deferLegacyImport() => _transition.synchronized(() async {
    final active = _active;
    if (!_closed && active != null) await store.deferLegacy(active.identity);
  });

  @override
  Future<GatewayResult<LegacyImportReport>> importLegacy() {
    final context = _active;
    final expectedGeneration = generation;
    return _guard(() => _transition.synchronized(() async {
      if (_closed || context == null) return _loginRequired();
      if (!identical(context, _active) || expectedGeneration != generation) return _changed();
      var imported = false;
      _changing = true;
      try {
        await _pause(context);
        final report = await store.importLegacy(context.identity, context.gateway.database);
        _active = _AccountContext(
          identity: context.identity,
          session: context.session,
          gateway: KingoCampusGateway(database: context.gateway.database, client: context.gateway.client, now: _now),
        );
        _generation++;
        imported = true;
        return _ok(report);
      } catch (error, stack) {
        campusLog('[AccountGateway] action=import_legacy errorType=${error.runtimeType}\n$stack');
        return _fail('LEGACY_IMPORT_FAILED', '旧数据导入未完成，可重试；已有数据未被覆盖');
      } finally {
        if (!imported) context.accepting = true;
        _changing = false;
        if (imported) notifyListeners();
      }
    }));
  }

  @override
  Future<void> close() => _transition.synchronized(() async {
    if (_closed) return;
    _closed = true;
    _cancelRecovery();
    _cancelPending();
    final old = _active;
    await _pause(old);
    _active = null;
    if (old != null) {
      old.gateway.client.dispose();
      await old.gateway.database.close();
    }
    await store.close();
    super.dispose();
  });

  Future<GatewayResult<T>> _dispatch<T>(Future<GatewayResult<T>> Function(KingoCampusGateway gateway) operation, {bool recover = false}) async {
    final context = _active;
    final expectedGeneration = generation;
    if (_changing || (context != null && !context.accepting)) return _changed();
    if (_closed || context == null) return _loginRequired();
    if (recover && context.recovery != null) {
      final restored = await context.recovery!;
      if (!restored.ok) return _fail(restored.error!.code, restored.error!.message);
    }
    if (!identical(context, _active) || expectedGeneration != generation || !context.accepting) return _changed();
    final revision = context.sessionRevision;
    context.inflight++;
    late GatewayResult<T> result;
    try { result = await _guard(() => operation(context.gateway)); }
    finally { context.release(); }
    if (!identical(context, _active) || expectedGeneration != generation || !context.accepting) return _changed();
    if (!recover || result.error?.code != 'SESSION_EXPIRED' || credentials == null) return result;
    final restored = revision != context.sessionRevision ? _ok(true) : await _recover(context);
    if (!restored.ok) return _fail(restored.error!.code, restored.error!.message);
    if (!identical(context, _active) || expectedGeneration != generation || !context.accepting) return _changed();
    context.inflight++;
    try {
      final replayed = await _guard(() => operation(context.gateway));
      if (!identical(context, _active) || expectedGeneration != generation || !context.accepting) return _changed();
      if (replayed.error?.code == 'SESSION_EXPIRED') context.recoveryBlocked = true;
      return replayed;
    } finally { context.release(); }
  }

  Future<GatewayResult<bool>> _recover(_AccountContext context) {
    if (context.recovery != null) return context.recovery!;
    if (context.recoveryBlocked) return Future.value(_fail('SESSION_EXPIRED', '自动登录未完成，请手动登录'));
    final future = Future<GatewayResult<bool>>.microtask(() => _recoverOnce(context));
    context.recovery = future;
    future.whenComplete(() { if (identical(context.recovery, future)) context.recovery = null; });
    return future;
  }

  Future<GatewayResult<bool>> _recoverOnce(_AccountContext context) async {
    final epoch = _recoveryEpoch;
    bool active() => !_closed && identical(context, _active) && context.accepting && epoch == _recoveryEpoch;
    KingoClient? client;
    try {
      final saved = await credentials!.read(store.keyOf(context.identity));
      if (!active()) return _changed();
      if (saved == null) return _fail('SESSION_EXPIRED', '会话已失效，请登录或开启记住账号');
      await context.drain();
      if (!active()) return _changed();
      client = _newClient(source: context.identity.source);
      _recoveryClient = client;
      final auth = KingoAuth(client: client, now: _now);
      final login = await auth.login(saved.account, saved.password);
      if (!active()) return _changed();
      if (!login.ok || login.needsInput != null) {
        context.recoveryBlocked = true;
        final code = login.error?.code;
        if (code == 'PASSWORD_WRONG' || code == 'PASSWORD_WRONG_COUNT' || code == 'ACCOUNT_LOCKED') await credentials!.delete(store.keyOf(context.identity));
        return _fail('SESSION_EXPIRED', login.needsInput == 'captcha' ? '自动登录需要验证码，请手动登录完成验证' : '自动登录未完成：${login.error?.message ?? '需要人工验证'}');
      }
      if (auth.session?.loginId != context.identity.loginId) { context.recoveryBlocked = true; return _fail('SESSION_EXPIRED', '自动登录身份不一致，已停止'); }
      return await _transition.synchronized(() async {
        if (!active()) return _changed();
        final previous = await context.gateway.database.readSession();
        await auth.persistSession(context.gateway.database);
        if (!active()) {
          if (previous == null) { await context.gateway.database.clearSession(); } else { await context.gateway.database.writeSession(previous); }
          return _changed();
        }
        context.gateway.client.dispose();
        context.gateway = KingoCampusGateway(database: context.gateway.database, client: client!, now: _now);
        context.sessionRevision++;
        _recoveryClient = null;
        client = null;
        return _ok(true);
      });
    } catch (error, stack) {
      campusLog('[AccountGateway] action=recover errorType=${error.runtimeType}\n$stack');
      context.recoveryBlocked = true;
      return _fail('SESSION_EXPIRED', '无法自动恢复登录，请手动登录');
    } finally { client?.dispose(); if (identical(client, _recoveryClient)) _recoveryClient = null; }
  }

  @override
  Future<GatewayResult<List<TermRef>>> listTerms() => _dispatch((gateway) => gateway.listTerms());
  @override
  Future<GatewayResult<List<TermRef>>> syncTerms() => _dispatch((gateway) => gateway.syncTerms(), recover: true);
  @override
  Future<GatewayResult<ScheduleView>> syncSchedule(TermRef term) => _dispatch((gateway) => gateway.syncSchedule(term), recover: true);
  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) => _dispatch((gateway) => gateway.readSchedule(scope));
  @override
  Future<GatewayResult<GradesView>> syncGrades(TermRef term) => _dispatch((gateway) => gateway.syncGrades(term), recover: true);
  @override
  Future<GatewayResult<GradesView>> readGrades(TermRef term) => _dispatch((gateway) => gateway.readGrades(term));
  @override
  Future<GatewayResult<List<GradeTermOverview>>> readGradeYear(String year) => _dispatch((gateway) => gateway.readGradeYear(year));
  @override
  Future<GatewayResult<BellsView>> syncBells(TermRef term) => _dispatch((gateway) => gateway.syncBells(term), recover: true);
  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) => _dispatch((gateway) => gateway.readBells(term));
  @override
  Future<GatewayResult<TermRef?>> readBellsSource(TermRef term) => _dispatch((gateway) => gateway.readBellsSource(term));
  @override
  Future<GatewayResult<TermRef>> useBellsSource(TermRef target, TermRef source) => _dispatch((gateway) => gateway.useBellsSource(target, source));
  @override
  Future<GatewayResult<TermRef>> setTermStart(TermRef term, String date) => _dispatch((gateway) => gateway.setTermStart(term, date));
  @override
  Future<GatewayResult<RevisionView>> saveScheduleRevision(TermRef term, List<CourseRecord> courses, String summary, {required String? expectedRevisionId}) => _dispatch((gateway) => gateway.saveScheduleRevision(term, courses, summary, expectedRevisionId: expectedRevisionId));
  @override
  Future<GatewayResult<SyncPlan>> planScheduleSync(TermRef term, List<CourseRecord> courses) => _dispatch((gateway) => gateway.planScheduleSync(term, courses));
  @override
  Future<GatewayResult<RevisionView>> commitScheduleSync(TermRef term, List<CourseRecord> courses, {required bool confirm, String? expectedRevisionId}) => _dispatch((gateway) => gateway.commitScheduleSync(term, courses, confirm: confirm, expectedRevisionId: expectedRevisionId));
  @override
  Future<GatewayResult<List<RevisionView>>> listScheduleRevisions(TermRef term, {int? beforeSequence, int limit = 20}) => _dispatch((gateway) => gateway.listScheduleRevisions(term, beforeSequence: beforeSequence, limit: limit));
  @override
  Future<GatewayResult<ScheduleRevision>> readScheduleRevision(TermRef term, String id) => _dispatch((gateway) => gateway.readScheduleRevision(term, id));
  @override
  Future<GatewayResult<RevisionView>> restoreScheduleRevision(TermRef term, String id, {required String? expectedRevisionId}) => _dispatch((gateway) => gateway.restoreScheduleRevision(term, id, expectedRevisionId: expectedRevisionId));

  String _stamp() => _now().toUtc().toIso8601String();
  GatewayResult<T> _ok<T>(T data) => GatewayResult(ok: true, source: 'local', fetchedAt: _stamp(), data: data);
  GatewayResult<T> _fail<T>(String code, String message) => GatewayResult(ok: false, source: 'local', fetchedAt: _stamp(), error: GatewayError(code: code, message: message));
  GatewayResult<T> _changed<T>() => _fail('ACCOUNT_CHANGED', '账号已变化，请在当前账号重试');
  GatewayResult<T> _loginRequired<T>() => _fail('SESSION_EXPIRED', '请先登录教务账号');

  Future<GatewayResult<T>> _guard<T>(Future<GatewayResult<T>> Function() operation) async {
    try {
      return await operation();
    } catch (error, stack) {
      campusLog('[AccountGateway] action=operation errorType=${error.runtimeType}\n$stack');
      return _fail('OPERATION_FAILED', '操作未完成，请重试');
    }
  }
}

class _CancelledAccountSwitch implements Exception {
  const _CancelledAccountSwitch();
}

class _PendingLogin {
  _PendingLogin({required this.epoch, required this.auth, this.remember, this.credential, this.expected});
  final int epoch;
  final KingoAuth auth;
  final bool? remember;
  RememberedCredential? credential;
  final AccountIdentity? expected;
}

class _AccountContext {
  _AccountContext({required this.identity, required this.session, required this.gateway});
  final AccountIdentity identity;
  final SessionView session;
  KingoCampusGateway gateway;
  Future<GatewayResult<bool>>? recovery;
  bool recoveryBlocked = false;
  int sessionRevision = 0;
  int inflight = 0;
  bool accepting = true;
  Completer<void>? _drained;

  Future<void> drain() => inflight == 0 ? Future.value() : (_drained ??= Completer<void>()).future;

  void release() {
    inflight--;
    if (inflight == 0) {
      _drained?.complete();
      _drained = null;
    }
  }
}
