import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/app_background_sync.dart';
import 'package:superxd/application/auto_sync.dart';
import 'package:superxd/domain/auto_sync.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/edu/kingo_client.dart';
import 'package:superxd/edu/parse_schedule.dart';
import 'package:superxd/edu/parse_terms.dart';
import 'package:superxd/gateway/account_gateway.dart';
import 'package:superxd/local/account_store.dart';

// 前台登记的端口名（已发布的后台任务按它找前台，钉住线上取值）。
const _portName = 'superxd_auto_sync';
const _term = TermRef(xn: '2026', xq: '0', label: '合成学期');

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  late List<String> logs;
  setUp(() {
    IsolateNameServer.removePortNameMapping(_portName);
    logs = [];
    final previous = campusLog;
    campusLog = logs.add;
    addTearDown(() {
      campusLog = previous;
      IsolateNameServer.removePortNameMapping(_portName);
    });
  });

  group('交给前台那份', () {
    test('前台没登记：交不出去，自己跑', () async {
      expect(await forwardAutoSync(DateTime.now().add(const Duration(minutes: 1))), isFalse);
    });

    test('前台登记了：先回一声收到，按后台任务的时限跑完再回一声，交出去了', () async {
      final autoSync = _RecordingAutoSync();
      listenForBackgroundSync(autoSync);
      final deadline = DateTime.now().add(const Duration(minutes: 1));
      var returned = false;
      final forwarded = forwardAutoSync(deadline).then((value) {
        returned = true;
        return value;
      });
      await autoSync.started.future.timeout(const Duration(seconds: 5));
      expect(autoSync.keepGoing!(), isTrue, reason: '没到时限接着跑');
      await pumpEventQueue();
      expect(returned, isFalse, reason: '前台那份没跑完前后台任务不返回');
      autoSync.gate.complete();
      expect(await forwarded.timeout(const Duration(seconds: 5)), isTrue);
      expect(logs, contains('[AutoSync] action=background forwarded=true'));
    });

    test('交过去的那轮按后台任务的时限停：到点 keepGoing 就是假', () async {
      final autoSync = _RecordingAutoSync()..gate.complete();
      listenForBackgroundSync(autoSync);
      final deadline = DateTime.now().add(const Duration(milliseconds: 200));
      expect(await forwardAutoSync(deadline).timeout(const Duration(seconds: 5)), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(autoSync.keepGoing!(), isFalse);
    });

    test('前台那份出错也照常回声，后台任务不挂住', () async {
      final autoSync = _RecordingAutoSync()..failure = StateError('前台坏了');
      listenForBackgroundSync(autoSync);
      expect(await forwardAutoSync(DateTime.now().add(const Duration(minutes: 1))).timeout(const Duration(seconds: 5)), isTrue);
      expect(logs.any((log) => log.startsWith('[AutoSync] action=forwarded errorType=StateError')), isTrue);
    });

    test('登记还在、前台已经不回了：撤掉这条过期的登记自己跑；前台回来再登一次', () async {
      final stale = ReceivePort();
      addTearDown(stale.close);
      IsolateNameServer.registerPortWithName(stale.sendPort, _portName);
      expect(await forwardAutoSync(DateTime.now().add(const Duration(minutes: 1)), ackWait: const Duration(milliseconds: 50)), isFalse);
      expect(IsolateNameServer.lookupPortByName(_portName), isNull);

      final register = listenForBackgroundSync(_RecordingAutoSync()..gate.complete());
      final mine = IsolateNameServer.lookupPortByName(_portName);
      expect(mine, isNotNull);
      IsolateNameServer.removePortNameMapping(_portName);
      register();
      expect(IsolateNameServer.lookupPortByName(_portName), mine);
    });
  });

  group('应用不在时自己跑', () {
    late Directory directory;
    late Directory support;
    late _Client client;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('background-sync-');
      support = await Directory(path.join(directory.path, 'support')).create();
      client = _Client();
    });
    tearDown(() => directory.delete(recursive: true));

    Future<AccountGateway> open() async => AccountGateway(store: await AccountStore.open(directory: path.join(directory.path, 'databases')), clientFactory: () => client);
    void agree() => File(path.join(support.path, 'legal_notice.json')).writeAsStringSync('{"seenRevision":1,"agreedRevision":1}');
    Future<void> signInWithAutoSync() async {
      final gateway = await open();
      expect((await gateway.login('A', 'secret')).ok, isTrue);
      expect((await gateway.saveAutoSyncSetting(const AutoSyncSetting(enabled: true, years: {'2026'}, contents: {SyncContent.schedule}))).ok, isTrue);
      await gateway.close();
    }

    Future<AutoSyncStatus> status() async {
      final gateway = await open();
      try {
        expect((await gateway.restoreLocalSession()).ok, isTrue);
        return (await gateway.readAutoSync()).data!.status;
      } finally {
        await gateway.close();
      }
    }

    test('没同意协议与政策：不开账号库、不联网', () async {
      var opened = false;
      await headlessAutoSync(DateTime.now().add(const Duration(minutes: 1)), support: support, openGateway: () async {
        opened = true;
        return open();
      });
      expect(opened, isFalse);
    });

    test('本机会话恢复不了：记一行跳过，不登录、不清活动账号', () async {
      agree();
      await headlessAutoSync(DateTime.now().add(const Duration(minutes: 1)), support: support, openGateway: open);
      expect(logs, contains('[AutoSync] action=background skipped=no_session'));
      expect((client.logins, client.reads), (0, 0));
    });

    test('到期就用本机会话同步一轮并记下结果', () async {
      await signInWithAutoSync();
      agree();
      client.logins = 0;
      await headlessAutoSync(DateTime.now().add(const Duration(minutes: 1)), support: support, openGateway: open);
      expect(client.reads, 1);
      expect(client.logins, 0, reason: '会话还有效就不重新登录');
      final last = await status();
      expect(last.state, AutoSyncState.ok);
      expect(last.lastSuccessAt, isNotNull);
      expect(last.lastSuccessAt, last.lastAttemptAt);
    });

    test('前台已经登记了端口、或者过了时限：这一轮让出去，一个请求都不发', () async {
      await signInWithAutoSync();
      agree();
      final foreground = ReceivePort();
      addTearDown(foreground.close);
      IsolateNameServer.registerPortWithName(foreground.sendPort, _portName);
      await headlessAutoSync(DateTime.now().add(const Duration(minutes: 1)), support: support, openGateway: open);
      IsolateNameServer.removePortNameMapping(_portName);
      await headlessAutoSync(DateTime.now().subtract(const Duration(seconds: 1)), support: support, openGateway: open);
      expect(client.reads, 0);
      expect((await status()).lastAttemptAt, isNull);
    });
  });
}

// 只记下前台那一轮被怎么调用，等测试放行才结束。
class _RecordingAutoSync extends AutoSync {
  _RecordingAutoSync() : super(gateway: _UnusedGateway());
  final started = Completer<void>();
  final gate = Completer<void>();
  Object? failure;
  bool Function()? keepGoing;

  @override
  Future<void> runIfDue({bool foreground = false, bool Function()? keepGoing}) {
    this.keepGoing = keepGoing;
    if (!started.isCompleted) started.complete();
    return failure == null ? gate.future : Future.error(failure!);
  }
}

class _UnusedGateway implements CampusGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class _Client extends KingoClient {
  _Client() : super(base: 'https://school.example/edu');
  int logins = 0;
  int reads = 0;

  @override
  Future<KingoProfile> fetchProfile() async => KingoProfile(userCode: 'internal-A', xn: _term.xn, xq: _term.xq, loginId: 'A');
  @override
  Future<({List<ParsedTerm> terms, ({String xn, String xq})? published})> listTerms() async => (terms: [ParsedTerm(xn: _term.xn, xq: _term.xq, label: '合成学期', code: '')], published: null);
  @override
  Future<KingoLoginResult> login(String username, String password, {String captcha = ''}) async {
    logins++;
    jar['JSESSIONID'] = 'test-cookie-$username';
    return KingoLoginResult(ok: true, needsCaptcha: false, failure: null, captcha: null, loginId: username, userCode: 'internal-$username', currentXn: _term.xn, currentXq: _term.xq, terms: [(xn: _term.xn, xq: _term.xq, label: '')]);
  }

  @override
  Future<ParsedSchedule> fetchSchedule({required String xn, required String xq, required String userCode}) async {
    reads++;
    return ParsedSchedule(termLabel: '', loginId: 'A', name: '', className: '', courses: const []);
  }
}
