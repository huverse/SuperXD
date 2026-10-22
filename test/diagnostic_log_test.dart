import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/app_diagnostics.dart';
import 'package:superxd/device/diagnostic_device.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/local/developer_settings.dart';
import 'package:superxd/local/diagnostic_log.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('diagnostic_log_test'));
  tearDown(() => temp.deleteSync(recursive: true));

  // 默认时刻是 UTC 04:00，即校园时区 2026-10-21 12:00。
  Future<DiagnosticLog> open({DateTime? now, DiagnosticPublish? publish}) => DiagnosticLog.open(
    directory: Directory(path.join(temp.path, 'logs')),
    exports: Directory(path.join(temp.path, 'cache', 'diagnostics_export')),
    publish: publish ?? (archive, filename) async => true,
    clock: () => now ?? DateTime.utc(2026, 10, 21, 4),
  );
  File log(String name) => File(path.join(temp.path, 'logs', name));
  List<String> names() => log('x').parent.listSync().map((entity) => path.basename(entity.path)).toList()..sort();

  test('平时只记错误（带 errorType 或堆栈），开发者模式记全部；控制台照旧，落盘前掩去链接与手机号', () async {
    final logs = await open();
    final console = <String>[];
    final sink = logs.tee(console.add);
    sink('[Grades] action=sync state=start');
    sink('[Chaoxing] action=http errorType=timeout path=/newsign/signDetail\n#0      main (file:///x.dart:1)');
    sink('[KingoCampusGateway] Exception: 意外\n#0      main (file:///x.dart:2)');
    await logs.flush();
    expect(console, hasLength(3));
    final errors = log('errors.log').readAsStringSync();
    expect(errors, contains('2026-10-21T04:00:00.000Z [Chaoxing] action=http errorType=timeout'));
    expect(errors, contains('[KingoCampusGateway]'));
    expect(errors, isNot(contains('[Grades]')));
    expect(names(), ['errors.log']);

    logs.developer = true;
    sink('[Route] action=change path=/today 见 https://example.com/a?token=1 与 13800138000');
    await logs.flush();
    final diagnostics = log('diagnostics-2026-10-21.log').readAsStringSync();
    expect(diagnostics, contains('[Route] action=change path=/today'));
    expect(diagnostics, contains('<链接>'));
    expect(diagnostics, contains('<手机号>'));
    expect(diagnostics, isNot(contains('example.com')));
    expect(diagnostics, isNot(contains('13800138000')));
    expect(console.last, contains('13800138000'));
  });

  test('错误记录写满 512KB 改名成 errors.1.log 接着写，两份合计约 1MB，最旧的被覆盖', () async {
    final logs = await open();
    final padding = 'x' * 1000;
    // 每条都是不同种类的错误（签名掩掉数字，所以用字母区分），不被聚合。
    String letters(int value) => String.fromCharCodes([97 + value ~/ 676 % 26, 97 + value ~/ 26 % 26, 97 + value % 26]);
    for (var batch = 0; batch < 12; batch++) {
      for (var index = 0; index < 100; index++) {
        logs.record('[Test] action=fill errorType=batch${letters(batch)}${letters(index)} $padding');
      }
      await logs.flush();
    }
    expect(names(), ['errors.1.log', 'errors.log']);
    expect(log('errors.log').lengthSync(), lessThanOrEqualTo(diagnosticErrorLimit));
    expect(log('errors.1.log').lengthSync(), lessThanOrEqualTo(diagnosticErrorLimit));
    expect(log('errors.1.log').readAsStringSync(), isNot(contains('errorType=batch${letters(0)}${letters(0)} ')));
    expect(log('errors.log').readAsStringSync(), contains('errorType=batch${letters(11)}${letters(99)} '));
  });

  test('开发者模式日志按校园日分文件、单个超过 4MB 另起一份；超过 7 天的与总量超过 20MB 的从最旧删起', () async {
    final directory = log('x').parent..createSync(recursive: true);
    // 随机字节压不小，旧文件压成 .gz 后照样占地方，才测得到总量上限。
    final random = Random(1);
    void fill(String name, int bytes) => File(path.join(directory.path, name)).writeAsBytesSync(Uint8List.fromList([for (var index = 0; index < bytes; index++) random.nextInt(256)]));
    fill('diagnostics-2026-10-14.log', 10);
    fill('diagnostics-2026-10-15.log', 10);
    fill('errors.log', 10);
    final logs = await open();
    expect(names(), ['diagnostics-2026-10-15.log.gz', 'errors.log']);

    // 校园时区 10-22 凌晨 1 点：已是新的一天。
    final late = await open(now: DateTime.utc(2026, 10, 21, 17));
    late.developer = true;
    late.record('[Route] action=change path=/today');
    await late.flush();
    expect(log('diagnostics-2026-10-22.log').existsSync(), isTrue);

    fill('diagnostics-2026-10-21.log', diagnosticFileLimit);
    logs.developer = true;
    logs.record('[Route] action=change path=/mine');
    await logs.flush();
    expect(log('diagnostics-2026-10-21.2.log').readAsStringSync(), contains('path=/mine'));

    for (final day in ['16', '17', '18', '19', '20']) {
      fill('diagnostics-2026-10-$day.log', diagnosticFileLimit);
    }
    logs.record('[Route] action=change path=/service');
    await logs.flush();
    final kept = names().where((name) => name.startsWith('diagnostics-'));
    final total = kept.fold(0, (sum, name) => sum + log(name).lengthSync());
    expect(total, lessThanOrEqualTo(diagnosticTotalLimit));
    expect(kept.first, isNot('diagnostics-2026-10-15.log.gz'));
    expect(kept, contains('diagnostics-2026-10-21.2.log'));
  });

  test('查看日志：新的在前，堆栈续行并进同一条；可只看错误记录（开启前的错误也在）', () async {
    var now = DateTime.utc(2026, 10, 21, 4);
    final logs = await DiagnosticLog.open(
      directory: Directory(path.join(temp.path, 'logs')),
      exports: Directory(path.join(temp.path, 'cache')),
      publish: (archive, filename) async => true,
      clock: () => now,
    );
    logs.record('[Sync] action=run errorType=timeout\n#0      sync (file:///s.dart:3)\n#1      main (file:///m.dart:9)');
    await logs.flush();
    logs.developer = true;
    now = now.add(const Duration(seconds: 1));
    logs.record('[Route] action=change path=/today');
    now = now.add(const Duration(seconds: 1));
    logs.record('[Http] module=edu method=GET path=/x status=200 ms=12 bytes=34');
    final all = await logs.recent(errorsOnly: false);
    expect(all.map((record) => record.text.split(' ').first), ['[Http]', '[Route]']);
    expect(all.first.time, DateTime.utc(2026, 10, 21, 4, 0, 2));
    final errors = await logs.recent(errorsOnly: true);
    expect(errors, hasLength(1));
    expect(errors.single.text, contains('#1      main'));
  });

  test('关闭开发者模式只删开发者模式日志，错误记录保留；清除日志全删', () async {
    final logs = await open();
    logs.developer = true;
    logs.record('[Route] action=change path=/today');
    logs.record('[App] action=uncaught errorType=StateError\n#0 main');
    await logs.flush();
    expect(names(), ['diagnostics-2026-10-21.log', 'errors.log']);
    await logs.clearDiagnostics();
    expect(names(), ['errors.log']);
    await logs.clear();
    expect(names(), isEmpty);
    expect(await logs.totalBytes(), 0);
  });

  test('导出：全部日志加 about.txt 打成 zip 交给系统保存，返回文件名，临时包用完即删；没有日志不导出', () async {
    final published = <String, List<String>>{};
    final logs = await open(publish: (archive, filename) async {
      final decoded = ZipDecoder().decodeBytes(archive.readAsBytesSync());
      published[filename] = [for (final file in decoded.files) file.name];
      expect(utf8.decode(decoded.findFile('about.txt')!.content), allOf(contains('version: 1.0.0-alpha.6'), contains('developer: true')));
      return true;
    });
    expect(await logs.export(), isNull);
    logs.environment = {'version': '1.0.0-alpha.6', 'device': 'Google Pixel 8'};
    logs.developer = true;
    logs.record('[Route] action=change path=/today');
    logs.record('[App] action=uncaught errorType=StateError\n#0 main');
    final filename = await logs.export();
    expect(filename, 'SuperXD-日志-20261021-120000.zip');
    expect(published[filename], unorderedEquals(['about.txt', 'diagnostics-2026-10-21.log', 'errors.log']));
    expect(Directory(path.join(temp.path, 'cache', 'diagnostics_export')).listSync(), isEmpty);
  });

  test('请求诊断记录：只在开发者模式下记，不带域名与查询串，路径里像编号的段掩成 :id', () {
    final records = <String>[];
    final previous = campusLog;
    campusLog = records.add;
    addTearDown(() {
      campusLog = previous;
      campusDiagnostics = false;
    });
    campusRequestLog('chaoxing', 'GET', Uri.parse('https://mobilelearn.chaoxing.com/newsign/signDetail?msg=1'), status: 200, elapsed: const Duration(milliseconds: 12), bytes: 34);
    expect(records, isEmpty);
    campusDiagnostics = true;
    campusRequestLog('chaoxing', 'GET', Uri.parse('https://mobilelearn.chaoxing.com/newsign/signDetail?msg=1'), status: 200, elapsed: const Duration(milliseconds: 12), bytes: 34);
    campusRequestLog('chaoxing', 'GET', Uri.parse('https://p.cldisk.com/star3/origin/af34b2c9e8d71a00.jpg'), elapsed: const Duration(seconds: 15), error: 'no_response');
    campusRequestLog('relay', 'DELETE', Uri.parse('http://relay.example/v1/friends/Ab3dEf9hIjKlMnOp'), status: 204, elapsed: const Duration(milliseconds: 80), bytes: 0);
    campusRequestLog('edu', 'POST', Uri.parse('http://jw.example/jwweb/znpk/Pri_StuSel_rpt.aspx?m=1'), status: 200, elapsed: const Duration(milliseconds: 300), bytes: 9000);
    expect(records, [
      '[Http] module=chaoxing method=GET path=/newsign/signDetail status=200 ms=12 bytes=34',
      '[Http] module=chaoxing method=GET path=/star3/origin/:id status=- ms=15000 bytes=- error=no_response',
      '[Http] module=relay method=DELETE path=/v1/friends/:id status=204 ms=80 bytes=0',
      '[Http] module=edu method=POST path=/jwweb/znpk/Pri_StuSel_rpt.aspx status=200 ms=300 bytes=9000',
    ]);
  });

  test('开发者设置：写进文件、重开还在；关掉开发者模式连性能浮层一起关；坏文件当都关着', () async {
    final file = File(path.join(temp.path, 'developer.json'));
    final settings = await DeveloperSettings.open(file);
    expect((settings.enabled, settings.performanceOverlay), (false, false));
    await settings.setPerformanceOverlay(true);
    expect(settings.performanceOverlay, isFalse);
    await settings.setEnabled(true);
    await settings.setPerformanceOverlay(true);
    final reopened = await DeveloperSettings.open(file);
    expect((reopened.enabled, reopened.performanceOverlay), (true, true));
    await reopened.setEnabled(false);
    expect(reopened.performanceOverlay, isFalse);
    file.writeAsStringSync('{坏');
    final broken = await DeveloperSettings.open(file);
    expect((broken.enabled, broken.performanceOverlay), (false, false));
  });

  test('同类错误一分钟内只记第一条全文，其余计数，窗口到了补一条「又出现 N 次」；按种类汇总、诊断摘要都计进去', () async {
    var now = DateTime.utc(2026, 10, 21, 4);
    final logs = await DiagnosticLog.open(
      directory: Directory(path.join(temp.path, 'logs')),
      exports: Directory(path.join(temp.path, 'cache')),
      publish: (archive, filename) async => true,
      clock: () => now,
    );
    logs.environment = {'version': '1.0.0-alpha.6'};
    // 换了编号与耗时的同一处错误算同一种。
    for (var index = 0; index < 30; index++) {
      logs.record('[RelayTransport] action=request route=GET /v1/messages code=TIMEOUT waited=${index * 25}ms errorType=TimeoutException\n#0      main (file:///x.dart:$index)');
      now = now.add(const Duration(seconds: 1));
    }
    logs.record('[Sync] action=run errorType=StateError\n#0 main');
    await logs.flush();
    var errors = log('errors.log').readAsStringSync();
    expect('[RelayTransport]'.allMatches(errors).length, 1);
    expect(errors, isNot(contains('action=repeat')));

    now = now.add(const Duration(minutes: 1));
    await logs.flush();
    errors = log('errors.log').readAsStringSync();
    expect(errors, contains('[Diagnostics] action=repeat errorType=Repeated count=29 seconds=29 last=2026-10-21T04:00:29.000Z'));
    expect(errors, contains('| [RelayTransport] action=request route=GET /v#/messages code=TIMEOUT waited=#ms errorType=TimeoutException'));

    final kinds = await logs.errorKinds();
    expect(kinds.map((kind) => (kind.signature.split(' ').first, kind.count)), [('[Sync]', 1), ('[RelayTransport]', 30)]);
    expect(kinds.last.text, contains('#0      main'));
    final summary = await logs.summary();
    expect(summary, contains('version: 1.0.0-alpha.6'));
    expect(summary, contains('最近的错误（共 2 种'));
    expect(summary, contains('[RelayTransport] action=request route=GET /v#/messages code=TIMEOUT waited=#ms errorType=TimeoutException × 30'));
  });

  test('导出与切到后台前把聚合中的计数结算写出；签名掩掉编号、截到 200 字，种类有界', () async {
    final logs = await open();
    logs.record('[Chaoxing] action=http errorType=timeout path=/a');
    logs.record('[Chaoxing] action=http errorType=timeout path=/a');
    await logs.flush(settle: true);
    final settled = log('errors.log').readAsStringSync();
    expect(settled, contains('[Diagnostics] action=repeat errorType=Repeated count=1 seconds=0 last=2026-10-21T04:00:00.000Z | [Chaoxing] action=http errorType=timeout path=/a'));
    expect(diagnosticErrorSignature('[Relay] route=DELETE /v1/friends/Ab3dEf9hIjKlMnOp errorType=X\n#0 main'), '[Relay] route=DELETE /v# /friends/# errorType=X'.replaceAll('/v# /', '/v#/'));
    expect(diagnosticErrorSignature('[X] ${'很长' * 200}').length, 200);
  });

  test('早于今天的开发者模式日志压成 .gz，查看时解开照样读到，导出里也在', () async {
    final directory = log('x').parent..createSync(recursive: true);
    File(path.join(directory.path, 'diagnostics-2026-10-20.log')).writeAsStringSync('2026-10-20T08:00:00.000Z [Route] action=change path=/yesterday\n');
    final logs = await open();
    expect(names(), ['diagnostics-2026-10-20.log.gz']);
    final restored = utf8.decode(GZipDecoder().decodeBytes(log('diagnostics-2026-10-20.log.gz').readAsBytesSync()));
    expect(restored, contains('path=/yesterday'));
    logs.developer = true;
    logs.record('[Route] action=change path=/today');
    final records = await logs.recent(errorsOnly: false);
    expect(records.map((record) => record.text), ['[Route] action=change path=/today', '[Route] action=change path=/yesterday']);
  });

  test('上次退出原因：异常结束按错误记（ANR 附线程堆栈），正常结束只在开发者模式记；读过的最新时刻存下，不重复记', () async {
    final records = <String>[];
    final previous = campusLog;
    campusLog = records.add;
    addTearDown(() {
      campusLog = previous;
      campusDiagnostics = false;
    });
    final marker = File(path.join(temp.path, 'last_exit_seen'));
    final asked = <int>[];
    ProcessExit exit(int timestamp, String reason, {String trace = ''}) =>
        (timestamp: timestamp, reason: reason, status: 0, importance: 100, pssKb: 204800, rssKb: 409600, description: reason == 'ANR' ? 'Input dispatching timed out' : '', trace: trace);
    Future<List<ProcessExit>> read(int since) async {
      asked.add(since);
      return [exit(3000, 'ANR', trace: '"main" prio=5 tid=1 Blocked'), exit(2000, 'USER_REQUESTED'), exit(1000, 'CRASH_NATIVE')].where((item) => item.timestamp > since).toList();
    }

    await recordExitReasons(marker: marker, read: read);
    expect(records, hasLength(2));
    expect(records.first, startsWith('[App] action=last_exit errorType=CRASH_NATIVE at=1970-01-01T00:00:01.000Z'));
    expect(records.last, contains('errorType=ANR'));
    expect(records.last, contains('pssMb=200 rssMb=400 description=Input_dispatching_timed_out\n"main" prio=5 tid=1 Blocked'));
    expect(marker.readAsStringSync(), '3000');

    await recordExitReasons(marker: marker, read: read);
    expect(asked, [0, 3000]);
    expect(records, hasLength(2));

    marker.deleteSync();
    records.clear();
    campusDiagnostics = true;
    await recordExitReasons(marker: marker, read: read);
    expect(records.map((record) => record.split(' ')[2]), ['errorType=CRASH_NATIVE', 'reason=USER_REQUESTED', 'errorType=ANR']);
  });
}
