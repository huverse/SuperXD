import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/edu/kingo_client.dart';
import 'package:superxd/gateway/kingo_campus_gateway.dart';
import 'package:superxd/local/app_database.dart';
import 'package:superxd/domain/schedule_store.dart';

void main() {
  test('合法空课表可读取，陌生HTML和HTTP错误不可当空课表', () async {
    for (final body in ['<h1>学生个人课表</h1><p>课程门数：0</p>', '<h1>学生个人课表</h1><p>暂无课程信息</p><tbody></tbody>', '<html><body><h1>学生个人课表</h1><center>没有检索到记录!</center></body></html>']) {
      final client = KingoClient(client: MockClient((_) async => http.Response(body, 200, headers: {'content-type': 'text/html; charset=utf-8'})));
      expect((await client.fetchSchedule(xn: '2026', xq: '1', userCode: 'test')).courses, isEmpty);
    }
    final unknown = KingoClient(client: MockClient((_) async => http.Response('系统维护', 200, headers: {'content-type': 'text/html; charset=utf-8'})));
    await expectLater(unknown.fetchSchedule(xn: '2026', xq: '1', userCode: 'test'), throwsA(isA<KingoCallException>().having((error) => error.failure.code, 'code', 'UPSTREAM_FORMAT')));
    final failed = KingoClient(client: MockClient((_) async => http.Response('server unavailable', 500)));
    await expectLater(failed.fetchSchedule(xn: '2026', xq: '1', userCode: 'test'), throwsA(isA<KingoCallException>().having((error) => error.failure.code, 'code', 'UPSTREAM_HTTP')));
  });

  test('带课表标题的权限错误不生成空版本覆盖已有教务课表', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db = await AppDatabase.openMemory();
    await db.writeSession(const SavedSession(loginId: 'test', displayName: '', className: '', cookieJson: '{"cookies":{},"userCode":"test"}', savedAt: 'stamp'));
    var body = '<h1>学生个人课表</h1><tbody><tr><td colspan="12">没有访问权限，请联系管理员</td></tr></tbody>';
    final client = KingoClient(client: MockClient((_) async => http.Response(body, 200, headers: {'content-type': 'text/html; charset=utf-8'})));
    final gateway = KingoCampusGateway(database: db, client: client);
    const term = TermRef(xn: '2026', xq: '0');
    final original = [CourseRecord(courseCode: 'C1', courseName: '不能丢的课程', sectionId: 'S1', credit: 1, teacherName: '', meetings: [])];
    await gateway.commitScheduleSync(term, original, confirm: false);
    final denied = await gateway.syncSchedule(term);
    expect(denied.error?.code, 'UPSTREAM_FORMAT');
    expect((await gateway.readSchedule(const ScheduleScope.term(term))).data!.courses.single.courseName, '不能丢的课程');
    expect((await gateway.listScheduleRevisions(term)).data, hasLength(1));
    body = '<h1>学生个人课表</h1><tbody><tr><td colspan="12">没有课程记录</td></tr></tbody>';
    expect((await gateway.syncSchedule(term)).ok, isTrue);
    expect((await gateway.readSchedule(const ScheduleScope.term(term))).data!.courses, isEmpty);
    expect((await gateway.listScheduleRevisions(term)).data, hasLength(2));
    await db.close();
  });

  test('登录失效页和重定向被明确识别', () async {
    for (final response in [
      http.Response('<form action="/cas/logon.action">登录</form>', 200, headers: {'content-type': 'text/html; charset=utf-8'}),
      http.Response('', 302, headers: {'location': '/cas/login.action'}),
    ]) {
      final client = KingoClient(client: MockClient((_) async => response));
      await expectLater(client.fetchSchedule(xn: '2026', xq: '0', userCode: 'test'), throwsA(isA<KingoCallException>().having((error) => error.failure.code, 'code', 'SESSION_EXPIRED')));
    }
  });

  test('作息明确未设置才是empty，未知内容拒绝', () async {
    final empty = KingoClient(client: MockClient((_) async => http.Response('未设置作息时间', 200, headers: {'content-type': 'text/html; charset=utf-8'})));
    expect((await empty.fetchBells(xn: '2026', xq: '0')).empty, isTrue);
    final bad = KingoClient(client: MockClient((_) async => http.Response('维护中', 200, headers: {'content-type': 'text/html; charset=utf-8'})));
    await expectLater(bad.fetchBells(xn: '2026', xq: '0'), throwsFormatException);
  });

  test('超时覆盖响应体，不只覆盖headers，发送取消信号', () async {
    final transport = _BodyStalls();
    final client = KingoClient(client: transport, requestTimeout: const Duration(milliseconds: 20));
    await expectLater(client.fetchSchedule(xn: '2026', xq: '0', userCode: 'test'), throwsA(isA<TimeoutException>()));
    await transport.aborted.future.timeout(const Duration(seconds: 1));
    await transport.body.close();
  });

  test('500与畸形回包不会覆盖已有版本或清空会话', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db = await AppDatabase.openMemory();
    await db.writeSession(const SavedSession(loginId: 'test', displayName: '', className: '', cookieJson: '{"cookies":{},"userCode":"test"}', savedAt: 'stamp'));
    final transport = MockClient((_) async => http.Response('server unavailable', 500));
    final gateway = KingoCampusGateway(database: db, client: KingoClient(client: transport));
    const term = TermRef(xn: '2026', xq: '0');
    final saved = await gateway.saveScheduleRevision(term, [], '原始本地记录', expectedRevisionId: null);
    final result = await gateway.syncSchedule(term);
    expect(result.error?.code, 'UPSTREAM_HTTP');
    expect((await gateway.listScheduleRevisions(term)).data!.single.id, saved.data!.id);
    expect((await db.readSession())?.loginId, 'test');
    await db.close();
  });
}

class _BodyStalls extends http.BaseClient {
  final body = StreamController<List<int>>();
  final aborted = Completer<void>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final abortable = request as http.AbortableRequest;
    abortable.abortTrigger!.then((_) => aborted.complete());
    return http.StreamedResponse(body.stream, 200);
  }
}
