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

  test('日志目录写不进去时打开照样成功、记日志不抛，只把原因报到控制台（本机日志不能挡住应用启动）', () async {
    // 日志目录的位置被一个普通文件占着，建目录与写入都会失败。
    File(path.join(temp.path, 'logs')).writeAsStringSync('');
    final logs = await open();
    final console = <String>[];
    final sink = logs.tee(console.add);
    sink('[App] action=uncaught errorType=StateError\n#0 main');
    await logs.flush();
    expect(console.first, startsWith('[App] action=uncaught'));
    expect(console.last, startsWith('[Diagnostics] action=write errorType='));
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
    // 清理排在写入队列里、不挡打开（启动不等它），等队列走完再看。
    await logs.flush();
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
    // 第三方图片地址里的中文路径：GBK 编码的不能抛异常（记录在请求的 finally 里，抛了会改写请求结果），UTF-8 的不解码成明文、照样掩掉。
    campusRequestLog('short_video_image', 'GET', Uri.parse('https://img.example/%D6%D0%CE%C4/a.jpg'), status: 200, elapsed: const Duration(milliseconds: 40), bytes: 512);
    campusRequestLog('short_video_image', 'GET', Uri.parse('https://img.example/%E5%BC%A0%E4%B8%89/a.jpg'), status: 200, elapsed: const Duration(milliseconds: 40), bytes: 512);
    campusRequestLog('chaoxing_pack', 'POST', Uri(path: '/v1/chaoxing/packs'), status: 201, elapsed: const Duration(milliseconds: 90), bytes: 64);
    expect(records, [
      '[Http] module=chaoxing method=GET path=/newsign/signDetail status=200 ms=12 bytes=34',
      '[Http] module=chaoxing method=GET path=/star3/origin/:id status=- ms=15000 bytes=- error=no_response',
      '[Http] module=relay method=DELETE path=/v1/friends/:id status=204 ms=80 bytes=0',
      '[Http] module=edu method=POST path=/jwweb/znpk/Pri_StuSel_rpt.aspx status=200 ms=300 bytes=9000',
      '[Http] module=short_video_image method=GET path=/:id/a.jpg status=200 ms=40 bytes=512',
      '[Http] module=short_video_image method=GET path=/:id/a.jpg status=200 ms=40 bytes=512',
      '[Http] module=chaoxing_pack method=POST path=/v1/chaoxing/packs status=201 ms=90 bytes=64',
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
      logs.record('[RelayTransport] action=request route=GET /v1/messages code=TIMEOUT waited=${index * 25}ms errorType=TimeoutException\n#0      main (file:///x.dart:7)');
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
    expect(summary, matches(RegExp(r'\[RelayTransport\] action=request route=GET /v#/messages code=TIMEOUT waited=#ms errorType=TimeoutException @[0-9a-f]{8} × 30')));
  });

  // 审查发现：签名只看首行时，一分钟内两个页面各自的 StateError 被并成一条，后一处的堆栈丢了（[人工决策-2026-10-22 16:24:03] 改成加上出错位置）。
  test('同一种错误类型在不同位置出的错分开记、各留各的堆栈；同一位置照样合并（正式包按 virt 偏移，不看每次启动都变的 abs 地址）', () async {
    final logs = await open();
    logs.record('[App] action=uncaught errorType=StateError\n#0      PageA.load (package:superxd/page/a.dart:10:5)');
    logs.record('[App] action=uncaught errorType=StateError\n#0      PageB.load (package:superxd/page/b.dart:20:5)');
    logs.record('[App] action=uncaught errorType=StateError\n#0      PageA.load (package:superxd/page/a.dart:10:5)');
    String release(String abs, String virt) => '[App] action=uncaught errorType=StateError\n*** *** *** *** ***\npid: 1, tid: 2, name 1.ui\n    #00 abs $abs virt $virt _kDartSnapshotText+0x$virt';
    logs.record(release('00007fa166daaca8', '72ca8'));
    logs.record(release('00007fb000000ca8', '72ca8'));
    logs.record(release('00007fa166daacb0', '72cb0'));
    await logs.flush(settle: true);
    final errors = log('errors.log').readAsStringSync();
    expect('PageA.load'.allMatches(errors).length, 1);
    expect('PageB.load'.allMatches(errors).length, 1);
    expect('virt 72ca8'.allMatches(errors).length, 1);
    expect('virt 72cb0'.allMatches(errors).length, 1);
    expect('action=repeat'.allMatches(errors).length, 2);
    final kinds = await logs.errorKinds();
    expect(kinds.map((kind) => kind.count), unorderedEquals([2, 1, 2, 1]));
  });

  // 审查发现：发版流水线用 --split-debug-info 构建，正式包的堆栈是缩进的「    #00 abs … virt …」，不带 errorType= 的教务错误（会话失效、限流、超时）平时进不了错误记录。
  test('正式包的堆栈格式同样算错误；上次退出原因每条都留全文，不参与同类合并', () async {
    final logs = await open();
    logs.record('[KingoCampusGateway] code=SESSION_EXPIRED\n*** *** *** *** ***\npid: 1, tid: 2, name 1.ui\n    #00 abs 00007fa166daaca8 virt 0000000000072ca8 _kDartSnapshotText+0x3eca8');
    logs.record('[App] action=last_exit errorType=ANR at=1970-01-01T00:00:01.000Z status=0 importance=100 pssMb=200 rssMb=400\n"main" prio=5 tid=1 Blocked\n  at a.B.c(B.java:1)');
    logs.record('[App] action=last_exit errorType=ANR at=1970-01-01T00:00:02.000Z status=0 importance=100 pssMb=200 rssMb=400\n"main" prio=5 tid=1 Native\n  at d.E.f(E.java:2)');
    await logs.flush(settle: true);
    final errors = log('errors.log').readAsStringSync();
    expect(errors, contains('[KingoCampusGateway] code=SESSION_EXPIRED'));
    expect(errors, allOf(contains('at a.B.c(B.java:1)'), contains('at d.E.f(E.java:2)')));
    expect(errors, isNot(contains('action=repeat')));
  });

  test('按种类汇总读整份错误记录（两份约 1MB）：较早那份里的错误也算进去，次数不少算', () async {
    final directory = log('x').parent..createSync(recursive: true);
    final stack = [for (var index = 0; index < 30; index++) '#$index      frame (package:superxd/x.dart:$index)'].join('\n');
    String errors(String module, int count, int hour) => [for (var index = 0; index < count; index++) '2026-10-21T0$hour:00:${(index % 60).toString().padLeft(2, '0')}.000Z [$module] action=run errorType=Failed\n$stack\n'].join();
    // 两份各约 475KB（轮换后每份不超过 512KB）：较早那份开头有一种只出现过一次的错误。
    File(path.join(directory.path, 'errors.1.log')).writeAsStringSync('2026-10-21T00:00:00.000Z [Old] action=run errorType=Gone\n$stack\n${errors('Mid', 360, 1)}');
    File(path.join(directory.path, 'errors.log')).writeAsStringSync(errors('New', 360, 2));
    final logs = await open();
    final kinds = await logs.errorKinds();
    expect(kinds.map((kind) => (kind.signature.split(' ').first, kind.count)), [('[New]', 360), ('[Mid]', 360), ('[Old]', 1)]);
  });

  test('导出与切到后台前把聚合中的计数结算写出；签名掩掉编号、截到 200 字，种类有界', () async {
    final logs = await open();
    logs.record('[Chaoxing] action=http errorType=timeout path=/a');
    logs.record('[Chaoxing] action=http errorType=timeout path=/a');
    await logs.flush(settle: true);
    final settled = log('errors.log').readAsStringSync();
    expect(settled, contains('[Diagnostics] action=repeat errorType=Repeated count=1 seconds=0 last=2026-10-21T04:00:00.000Z | [Chaoxing] action=http errorType=timeout path=/a'));
    expect(diagnosticErrorSignature('[Relay] route=DELETE /v1/friends/Ab3dEf9hIjKlMnOp errorType=X'), '[Relay] route=DELETE /v#/friends/# errorType=X');
    expect(diagnosticErrorSignature('[Relay] route=DELETE /v1/friends/Ab3dEf9hIjKlMnOp errorType=X\n#0 main'), matches(RegExp(r'^\[Relay\] route=DELETE /v#/friends/# errorType=X @[0-9a-f]{8}$')));
    expect(diagnosticErrorSignature('[X] ${'很长' * 200}').length, 200);
  });

  test('清除日志后聚合重新开始：再出同一个错要记全文，不能只补一行「又出现 N 次」', () async {
    final logs = await open();
    logs.record('[Chaoxing] action=http errorType=timeout path=/a\n#0      main (file:///x.dart:1)');
    await logs.flush();
    await logs.clear();
    logs.record('[Chaoxing] action=http errorType=timeout path=/a\n#0      main (file:///x.dart:1)');
    await logs.flush(settle: true);
    expect(log('errors.log').readAsStringSync(), allOf(contains('#0      main'), isNot(contains('action=repeat'))));
  });

  test('当天分卷只往最新一卷追加，放不下另起下一卷，不回头填早先几卷的空余（查看页按卷号读，新的不能排到旧的后面）', () async {
    final logs = await open();
    logs.developer = true;
    log('x').parent.createSync(recursive: true);
    log('diagnostics-2026-10-21.log').writeAsStringSync('2026-10-21T03:00:00.000Z [Old] action=fill\n' * ((diagnosticFileLimit - 300) ~/ 43));
    logs.record('[Big] action=fill ${'x' * 400}');
    await logs.flush();
    logs.record('[Route] action=change path=/newest');
    await logs.flush();
    expect(log('diagnostics-2026-10-21.2.log').readAsStringSync(), contains('path=/newest'));
    expect((await logs.recent(errorsOnly: false)).first.text, '[Route] action=change path=/newest');
  });

  test('落盘前掩去带 +86 或分隔符的手机号、不带协议的链接', () async {
    final logs = await open();
    logs.developer = true;
    logs.record('[Mark] action=mark note=+8613800138000 8613800138000 138 0013 8000 138-0013-8000 www.example.com/a?token=1 jw.example.edu.cn/jwweb/x?id=1');
    await logs.flush();
    final text = log('diagnostics-2026-10-21.log').readAsStringSync();
    expect('<手机号>'.allMatches(text).length, 4);
    expect('<链接>'.allMatches(text).length, 2);
    expect(text, isNot(anyOf(contains('0013'), contains('example'), contains('token'))));
  });

  test('很长的一串字母数字照样很快掩完（耗时不随长度平方涨），后面跟的链接照样掩掉', () async {
    final logs = await open();
    final watch = Stopwatch()..start();
    logs.record('[Test] action=long errorType=Long ${'x' * 20000} jw.example.edu.cn/jwweb/x');
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
    await logs.flush();
    final text = log('errors.log').readAsStringSync();
    expect(text, contains('<链接>'));
    expect(text, isNot(contains('example')));
  });

  test('两处同时导出共用一次：只打一个包、交给系统一次', () async {
    var published = 0;
    final logs = await open(publish: (archive, filename) async {
      published++;
      return archive.existsSync();
    });
    logs.record('[App] action=uncaught errorType=StateError\n#0 main');
    final results = await Future.wait([logs.export(), logs.export()]);
    expect(results, ['SuperXD-日志-20261021-120000.zip', 'SuperXD-日志-20261021-120000.zip']);
    expect(published, 1);
  });

  test('早于今天的开发者模式日志压成 .gz，查看时解开照样读到，导出里也在', () async {
    final directory = log('x').parent..createSync(recursive: true);
    File(path.join(directory.path, 'diagnostics-2026-10-20.log')).writeAsStringSync('2026-10-20T08:00:00.000Z [Route] action=change path=/yesterday\n');
    final logs = await open();
    // 打开时不等压缩（启动不被拖慢），写入队列走完才压好。
    expect(names(), ['diagnostics-2026-10-20.log']);
    await logs.flush();
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

  // [人工决策-2026-10-22 16:24:03] 后台被系统回收不算错误：国产系统的后台清理很频繁，平时记成错误会刷满错误记录、诊断摘要前几名都是它。
  test('上次退出原因：内存不足、被信号杀只在当时在前台或可见时算错误，后台被回收的只在开发者模式下记一行；崩溃不论前后台都算', () async {
    final records = <String>[];
    final previous = campusLog;
    campusLog = records.add;
    addTearDown(() {
      campusLog = previous;
      campusDiagnostics = false;
    });
    final marker = File(path.join(temp.path, 'last_exit_seen'));
    ProcessExit exit(int timestamp, String reason, int importance) => (timestamp: timestamp, reason: reason, status: 9, importance: importance, pssKb: 0, rssKb: 0, description: '', trace: '');
    Future<List<ProcessExit>> read(int since) async => [exit(5000, 'CRASH', 400), exit(4000, 'SIGNALED', 125), exit(3000, 'LOW_MEMORY', 200), exit(2000, 'SIGNALED', 400), exit(1000, 'LOW_MEMORY', 400)];

    await recordExitReasons(marker: marker, read: read);
    expect(records.map((record) => record.split(' ')[2]), ['errorType=LOW_MEMORY', 'errorType=SIGNALED', 'errorType=CRASH']);

    marker.deleteSync();
    records.clear();
    campusDiagnostics = true;
    await recordExitReasons(marker: marker, read: read);
    expect(records.map((record) => record.split(' ')[2]), ['reason=LOW_MEMORY', 'reason=SIGNALED', 'errorType=LOW_MEMORY', 'errorType=SIGNALED', 'errorType=CRASH']);
  });

  test('开发者设置连着改（快速连点开关）时写入一个接一个，不抛错，文件里是最后的状态', () async {
    final file = File(path.join(temp.path, 'developer.json'));
    final settings = await DeveloperSettings.open(file);
    await Future.wait([
      for (var index = 0; index < 50; index++) ...[settings.setEnabled(true), settings.setPerformanceOverlay(index.isEven)],
    ]);
    final reopened = await DeveloperSettings.open(file);
    expect((reopened.enabled, reopened.performanceOverlay), (true, false));
  });
}
