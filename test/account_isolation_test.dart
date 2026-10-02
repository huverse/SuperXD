import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/edu/kingo_client.dart';
import 'package:superxd/edu/login_rules.dart';
import 'package:superxd/edu/parse_schedule.dart';
import 'package:superxd/gateway/account_gateway.dart';
import 'package:superxd/local/account_store.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';

const term = TermRef(xn: '2026', xq: '0', label: '测试学期');
CourseRecord course(String name) => CourseRecord(courseCode: 'C', courseName: name, sectionId: 'S', credit: 1, teacherName: '', meetings: []);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('A/B相同学期的课表版本隔离；退出/重启不删除缓存', () async {
    final dir = await Directory.systemTemp.createTemp('superxd-account-');
    var store = await AccountStore.open(directory: dir.path);
    var gateway = AccountGateway(store: store, clientFactory: _Client.new);
    expect((await gateway.restoreSession()).ok, isFalse);
    expect((await gateway.login('A', 'secret')).ok, isTrue);
    await gateway.setTermStart(term, '2026-08-31');
    await gateway.saveScheduleRevision(term, [course('A课表')], 'A自定义', expectedRevisionId: null);
    final aGeneration = gateway.generation;
    expect((await gateway.login('B', 'secret')).ok, isTrue);
    expect(gateway.generation, greaterThan(aGeneration));
    expect((await gateway.readSchedule(const ScheduleScope.term(term))).data!.courses, isEmpty);
    expect((await gateway.listScheduleRevisions(term)).data, isEmpty);
    await gateway.saveScheduleRevision(term, [course('B课表')], 'B自定义', expectedRevisionId: null);
    await gateway.close();

    store = await AccountStore.open(directory: dir.path);
    gateway = AccountGateway(store: store, clientFactory: _Client.new);
    expect((await gateway.restoreSession()).data?.loginId, 'B');
    expect((await gateway.readSchedule(const ScheduleScope.term(term))).data!.courses.single.courseName, 'B课表');
    expect((await gateway.login('A', 'secret')).ok, isTrue);
    final a = await gateway.readSchedule(const ScheduleScope.term(term));
    expect(a.data!.courses.single.courseName, 'A课表');
    expect(a.data!.termStartDate, '2026-08-31');
    await gateway.logout();
    expect(gateway.activeSession, isNull);
    expect((await gateway.readSchedule(const ScheduleScope.term(term))).ok, isFalse);
    expect((await gateway.login('A', 'secret')).ok, isTrue);
    expect((await gateway.listScheduleRevisions(term)).data!.single.summary, 'A自定义');
    await gateway.close();
    await dir.delete(recursive: true);
  });

  test('本机写入成功才通知课前提醒对账；提醒设置按账号隔离，非法档位不改原设置', () async {
    final dir = await Directory.systemTemp.createTemp('superxd-account-');
    final gateway = AccountGateway(store: await AccountStore.open(directory: dir.path), clientFactory: _Client.new);
    expect((await gateway.login('A', 'secret')).ok, isTrue);
    var changes = 0;
    gateway.scheduleChanges.addListener(() => changes++);
    expect((await gateway.setTermStart(term, '2026-08-31')).ok, isTrue);
    expect(changes, 1);
    expect((await gateway.setTermStart(term, '2026-02-30')).ok, isFalse);
    expect(changes, 1);
    expect((await gateway.readReminderSetting(term)).data, isA<ReminderSetting>().having((setting) => setting.enabled, 'enabled', isFalse).having((setting) => setting.leadMinutes, 'lead', 15));
    expect((await gateway.saveReminderSetting(term, const ReminderSetting(enabled: true, leadMinutes: 30))).ok, isTrue);
    expect(changes, 2);
    final invalid = await gateway.saveReminderSetting(term, const ReminderSetting(enabled: true, leadMinutes: 7));
    expect(invalid.error?.code, 'INVALID_REMINDER');
    expect(changes, 2);
    expect((await gateway.readReminderSetting(term)).data?.leadMinutes, 30);
    expect((await gateway.login('B', 'secret')).ok, isTrue);
    expect((await gateway.readReminderSetting(term)).data?.enabled, isFalse);
    await gateway.close();
    await dir.delete(recursive: true);
  });

  test('错误密码、验证码取消、无身份成功响应均保留活动账号', () async {
    final dir = await Directory.systemTemp.createTemp('superxd-pending-');
    final clients = <_Client>[];
    final gateway = AccountGateway(store: await AccountStore.open(directory: dir.path), clientFactory: () {
      final client = _Client(); clients.add(client); return client;
    });
    await gateway.login('A', 'secret');
    final generation = gateway.generation;
    await gateway.saveScheduleRevision(term, [course('A')], 'keep', expectedRevisionId: null);
    expect((await gateway.login('B', 'wrong')).error?.code, 'PASSWORD_WRONG');
    expect(gateway.activeSession?.loginId, 'A');
    expect(gateway.generation, generation);
    expect(clients.first.jar['JSESSIONID'], 'cookie-A');
    expect((await gateway.login('B', 'captcha')).needsInput, 'captcha');
    await gateway.cancelLogin();
    expect((await gateway.submitLoginCaptcha('ok')).ok, isFalse);
    expect(gateway.activeSession?.loginId, 'A');
    expect((await gateway.login('', 'secret')).error?.code, 'UPSTREAM_FORMAT');
    expect((await gateway.readSchedule(const ScheduleScope.term(term))).data!.courses.single.courseName, 'A');
    await gateway.close();
    await dir.delete(recursive: true);
  });

  test('取消慢登录后的迟到成功不得切换账号', () async {
    final dir = await Directory.systemTemp.createTemp('superxd-late-');
    final clients = <_Client>[];
    final gateway = AccountGateway(store: await AccountStore.open(directory: dir.path), clientFactory: () {
      final client = _Client(); clients.add(client); return client;
    });
    await gateway.login('A', 'secret');
    final slow = gateway.login('B', 'slow');
    await Future<void>.delayed(Duration.zero);
    final pending = clients.last;
    await pending.started.future;
    await gateway.cancelLogin();
    pending.loginGate.complete(pending.result('B'));
    expect((await slow).ok, isFalse);
    expect(gateway.activeSession?.loginId, 'A');
    await gateway.close();
    await dir.delete(recursive: true);
  });

  test('认证成功但正在等待旧任务收束时取消，不激活新账号', () async {
    final dir = await Directory.systemTemp.createTemp('superxd-cancel-drain-');
    final clients = <_Client>[];
    final store = await AccountStore.open(directory: dir.path);
    final gateway = AccountGateway(store: store, clientFactory: () { final client = _Client(); clients.add(client); return client; });
    await gateway.login('A', 'secret');
    final old = clients.first..holdSchedule = true;
    final syncing = gateway.syncSchedule(term);
    await old.started.future;
    final switching = gateway.login('B', 'secret');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await gateway.cancelLogin().timeout(const Duration(seconds: 1));
    old.scheduleGate.complete(const ParsedSchedule(termLabel: '', loginId: 'A', name: '', className: '', courses: []));
    await syncing;
    expect((await switching).ok, isFalse);
    expect(gateway.activeSession?.loginId, 'A');
    expect((await store.currentIdentity())?.loginId, 'A');
    await gateway.close(); await dir.delete(recursive: true);
  });

  for (final next in ['A', 'B']) {
    test('A同步迟到失效后登录$next，旧请求不能清新会话或写新库', () async {
      final dir = await Directory.systemTemp.createTemp('superxd-inflight-');
      final clients = <_Client>[];
      final gateway = AccountGateway(store: await AccountStore.open(directory: dir.path), clientFactory: () {
        final client = _Client(); clients.add(client); return client;
      });
      await gateway.login('A', 'secret');
      final old = clients.first..holdSchedule = true;
      final syncing = gateway.syncSchedule(term);
      await old.started.future;
      final switching = gateway.login(next, 'secret');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      old.scheduleGate.completeError(KingoCallException(const LoginFailure(code: 'SESSION_EXPIRED', message: 'old session')));
      expect((await syncing).error?.code, 'ACCOUNT_CHANGED');
      expect((await switching).ok, isTrue);
      expect((await gateway.restoreSession()).data?.loginId, next);
      await gateway.saveScheduleRevision(term, [course(next)], next, expectedRevisionId: null);
      expect((await gateway.readSchedule(const ScheduleScope.term(term))).data!.courses.single.courseName, next);
      await gateway.close();
      await dir.delete(recursive: true);
    });
  }
}

class _Client extends KingoClient {
  _Client() : super(base: 'https://school.example/edu');
  final started = Completer<void>();
  final loginGate = Completer<KingoLoginResult>();
  final scheduleGate = Completer<ParsedSchedule>();
  bool holdSchedule = false;

  KingoLoginResult result(String account) {
    jar['JSESSIONID'] = 'cookie-$account';
    return KingoLoginResult(ok: true, needsCaptcha: false, failure: null, captcha: null, loginId: account, userCode: 'internal-$account', currentXn: term.xn, currentXq: term.xq, terms: [(xn: term.xn, xq: term.xq, label: term.label)]);
  }

  @override
  Future<KingoLoginResult> login(String username, String password, {String captcha = ''}) async {
    if (password == 'wrong') return const KingoLoginResult(ok: false, needsCaptcha: false, failure: LoginFailure(code: 'PASSWORD_WRONG', message: '密码错误'), captcha: null, loginId: null);
    if (password == 'slow') { started.complete(); return loginGate.future; }
    if (password == 'captcha' && captcha.isEmpty) {
      pageSession = 'candidate';
      return const KingoLoginResult(ok: false, needsCaptcha: true, failure: null, captcha: CaptchaViewData(prompt: '验证码', hint: '', contentType: 'image/png', imageBase64: ''), loginId: null);
    }
    return result(username);
  }

  @override
  Future<ParsedSchedule> fetchSchedule({required String xn, required String xq, required String userCode}) {
    if (!holdSchedule) throw StateError('test must explicitly configure schedule');
    started.complete();
    return scheduleGate.future;
  }
}
