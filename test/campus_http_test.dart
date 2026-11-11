import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_pack_client.dart';
import 'package:superxd/toolbox/express/express_http.dart';
import 'package:superxd/toolbox/express/express_models.dart';

void main() {
  late List<String> logs;
  setUp(() {
    logs = [];
    final previous = campusLog;
    campusLog = logs.add;
    campusDiagnostics = true;
    addTearDown(() {
      campusLog = previous;
      campusDiagnostics = false;
    });
  });

  test('读完的响应交回状态、响应头与字节，请求记录只记路径、状态与字节数', () async {
    late http.BaseRequest seen;
    final kernel = CampusHttp('demo', client: MockClient.streaming((request, body) async {
      seen = request;
      await body.drain<void>();
      return http.StreamedResponse(Stream.value(utf8.encode('你好')), 201, headers: {'x-a': '1'});
    }));
    final response = await kernel.send('POST', Uri.parse('https://example.com/v1/items/12345678?secret=1'),
        timeout: const Duration(seconds: 5), limit: 1024, headers: const {'content-type': 'text/plain'}, body: '{}', followRedirects: false);
    expect((response.statusCode, utf8.decode(response.bodyBytes), response.headers['x-a']), (201, '你好', '1'));
    expect(seen, isA<http.AbortableRequest>());
    expect(seen.followRedirects, isFalse);
    expect(seen.headers['content-type'], 'text/plain; charset=utf-8', reason: 'body 按 http.Request.body 的规则补 charset');
    expect(logs, ['[Http] module=demo method=POST path=/v1/items/:id status=201 ms=${_ms(logs.single)} bytes=6']);
  });

  test('bodyBytes 原样写、不动请求头；logUri 替换记录里的地址', () async {
    late http.Request seen;
    final kernel = CampusHttp('relay', client: MockClient((request) async {
      seen = request;
      return http.Response('', 204);
    }));
    await kernel.send('POST', Uri.parse('https://example.com/v1/packs/once-only-ticket'),
        timeout: const Duration(seconds: 5), limit: 16, headers: const {'content-type': 'application/json'}, bodyBytes: [1, 2, 3], logUri: Uri(path: '/pickup'));
    expect(seen.headers['content-type'], 'application/json');
    expect(seen.bodyBytes, [1, 2, 3]);
    expect(logs.single, startsWith('[Http] module=relay method=POST path=/pickup status=204 '));
  });

  test('表单文件上传走可中断的 multipart 请求', () async {
    late http.BaseRequest seen;
    final kernel = CampusHttp('demo', client: MockClient.streaming((request, body) async {
      seen = request;
      await body.drain<void>();
      return http.StreamedResponse(Stream.value(utf8.encode('ok')), 200);
    }));
    await kernel.send('POST', Uri.parse('https://example.com/upload'), timeout: const Duration(seconds: 5), limit: 16,
        multipart: (fields: {'a': '1'}, files: [http.MultipartFile.fromBytes('file', [1], filename: 'a.jpg')]));
    expect(seen, isA<http.AbortableMultipartRequest>());
    expect((seen as http.MultipartRequest).fields, {'a': '1'});
  });

  test('超时管到读完响应体：到点中断连接、抛 TimeoutException，堆栈带得上调用方', () async {
    final transport = _Stalled();
    final kernel = CampusHttp('demo', client: transport);
    Object? error;
    StackTrace? stack;
    try {
      await kernel.send('GET', Uri.parse('https://example.com/slow'), timeout: const Duration(milliseconds: 30), limit: 16);
    } catch (caught, trace) {
      (error, stack) = (caught, trace);
    }
    expect(error, isA<TimeoutException>());
    expect('$stack', contains('campus_http_test.dart'));
    await transport.aborted.future.timeout(const Duration(seconds: 1));
    expect(logs.single, allOf(contains('path=/slow status=200 '), endsWith('bytes=- error=timeout')));
    await transport.body.close();
  });

  test('底层不理会中断信号（替身永远不回）也按时抛超时', () async {
    final kernel = CampusHttp('demo', client: MockClient((_) => Completer<http.Response>().future));
    final watch = Stopwatch()..start();
    await expectLater(kernel.send('GET', Uri.parse('https://example.com/hang'), timeout: const Duration(milliseconds: 30), limit: 16), throwsA(isA<TimeoutException>()));
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(logs.single, endsWith('status=- ms=${_ms(logs.single)} bytes=- error=timeout'));
  });

  test('外部取消：不用等超时，中断连接并抛 RequestAbortedException', () async {
    final transport = _Stalled();
    final kernel = CampusHttp('demo', client: transport);
    final cancel = Completer<void>();
    final result = kernel.send('GET', Uri.parse('https://example.com/slow'), timeout: const Duration(minutes: 1), limit: 16, cancel: cancel.future);
    final assertion = expectLater(result, throwsA(isA<http.RequestAbortedException>()));
    await transport.started.future;
    cancel.complete();
    await assertion;
    await transport.aborted.future.timeout(const Duration(seconds: 1));
    expect(logs.single, endsWith('error=cancelled'));
    await transport.body.close();
  });

  test('响应上限：正好上限照常；声明的长度超了不读，读到超过上限就停、取消订阅并中断连接', () async {
    final exact = CampusHttp('demo', client: MockClient((_) async => http.Response('x' * 8, 200)));
    expect((await exact.send('GET', Uri.parse('https://example.com/a'), timeout: const Duration(seconds: 5), limit: 8)).bodyBytes, hasLength(8));

    final declared = CampusHttp('demo', client: MockClient((_) async => http.Response('x' * 9, 200)));
    await expectLater(declared.send('GET', Uri.parse('https://example.com/a'), timeout: const Duration(seconds: 5), limit: 8),
        throwsA(isA<CampusHttpTooLarge>().having((error) => error.limit, 'limit', 8)));
    expect(logs.last, endsWith('error=too_large'));

    final transport = _Stalled(contentLength: null);
    final streamed = CampusHttp('demo', client: transport);
    final result = streamed.send('GET', Uri.parse('https://example.com/a'), timeout: const Duration(minutes: 1), limit: 8);
    final assertion = expectLater(result, throwsA(isA<CampusHttpTooLarge>()));
    await transport.started.future;
    transport.body.add(List.filled(5, 1));
    transport.body.add(List.filled(5, 1));
    await assertion;
    await transport.aborted.future.timeout(const Duration(seconds: 1));
    await transport.cancelled.future.timeout(const Duration(seconds: 1));
    expect(logs.last, allOf(contains('status=200'), endsWith('error=too_large')));
  });

  test('断网、读响应体出错原样抛出；收到响应头的照样记状态码', () async {
    final refused = CampusHttp('demo', client: MockClient((_) async => throw http.ClientException('connection refused')));
    StackTrace? stack;
    await expectLater(refused.send('GET', Uri.parse('https://example.com/a'), timeout: const Duration(seconds: 5), limit: 8).catchError((Object error, StackTrace trace) {
      stack = trace;
      throw error;
    }), throwsA(isA<http.ClientException>().having((error) => error.message, 'message', 'connection refused')));
    expect('$stack', allOf(contains('mock_client.dart'), contains('campus_http_test.dart')), reason: '原堆栈之后接上调用方那一串');
    expect(logs.last, endsWith('status=- ms=${_ms(logs.last)} bytes=- error=ClientException'));

    final broken = CampusHttp('demo', client: MockClient.streaming((_, _) async => http.StreamedResponse(Stream<List<int>>.error(const FormatException('坏块')), 502)));
    await expectLater(broken.send('GET', Uri.parse('https://example.com/a'), timeout: const Duration(seconds: 5), limit: 8), throwsFormatException);
    expect(logs.last, allOf(contains('status=502'), endsWith('error=FormatException')));
  });

  test('collect 由调用方自己累加响应体，拿到同一个上限', () async {
    int? given;
    final kernel = CampusHttp('demo', client: MockClient((_) async => http.Response('abc', 200)));
    final response = await kernel.send('GET', Uri.parse('https://example.com/a'), timeout: const Duration(seconds: 5), limit: 64, collect: (stream, limit) async {
      given = limit;
      final bytes = <int>[];
      await for (final chunk in stream) {
        bytes.addAll(chunk);
      }
      return bytes;
    });
    expect((given, response.body), (64, 'abc'));
  });

  group('迁到内核后各模块的封装照旧映射', () {
    test('快递：超时、响应过大、TLS 与断网各归各的错误码，日志只记路径', () async {
      Future<ExpressFailure> failure(http.Client client) async {
        try {
          await ExpressHttp(client: client, timeout: const Duration(milliseconds: 30)).getJson(Uri.parse('https://mobile.example.com/api/x?token=secret'), headers: const {});
        } on ExpressFailure catch (error) {
          return error;
        }
        fail('没有失败');
      }

      expect((await failure(MockClient((_) => Completer<http.Response>().future))).code, ExpressFailureCode.timeout);
      expect(logs.where((log) => log.startsWith('[Express] action=http errorType=timeout path=/api/x\n')), hasLength(1));
      expect((await failure(MockClient((_) async => http.Response('x' * (ExpressHttp.payloadLimit + 1), 200)))).code, ExpressFailureCode.tooLarge);
      expect(logs, contains('[Express] action=http errorType=too_large path=/api/x limit=${ExpressHttp.payloadLimit}'));
      expect((await failure(MockClient((_) async => throw const HandshakeException('terminated')))).code, ExpressFailureCode.network);
      expect((await failure(MockClient((_) async => throw http.ClientException('reset')))).message, '网络请求未完成，请稍后重试');
      expect(logs.join('\n'), isNot(contains('secret')));
    });

    test('学习通：超时与响应过大；403 只在 forbiddenExpired 时算会话过期', () async {
      Future<ChaoxingFailure> failure(http.Client client, {bool forbiddenExpired = false}) async {
        try {
          await ChaoxingHttp(client: client, timeout: const Duration(milliseconds: 30)).postForm(Uri.parse('https://mobilelearn.chaoxing.com/pptSign/stuSignajax'), 'a=1', forbiddenExpired: forbiddenExpired);
        } on ChaoxingFailure catch (error) {
          return error;
        }
        fail('没有失败');
      }

      expect((await failure(MockClient((_) => Completer<http.Response>().future))).code, ChaoxingFailureCode.timeout);
      expect((await failure(MockClient((_) async => http.Response('x' * (ChaoxingHttp.payloadLimit + 1), 200)))).code, ChaoxingFailureCode.invalidResponse);
      expect((await failure(MockClient((_) async => http.Response('', 403)), forbiddenExpired: true)).code, ChaoxingFailureCode.sessionExpired);
      expect((await failure(MockClient((_) async => http.Response('', 403)))).code, ChaoxingFailureCode.server);
    });

    test('代签中转：超时、响应过大，请求记录只写路由模板', () async {
      Future<ChaoxingFailure> failure(http.Client client) async {
        try {
          await ChaoxingPackHub(baseUrl: Uri.parse('http://relay.example:8080'), client: client, timeout: const Duration(milliseconds: 30)).pickup('ticketticketabcd');
        } on ChaoxingFailure catch (error) {
          return error;
        }
        fail('没有失败');
      }

      expect((await failure(MockClient((_) => Completer<http.Response>().future))).code, ChaoxingFailureCode.timeout);
      expect((await failure(MockClient((_) async => http.Response('x' * (ChaoxingPackHub.payloadLimit + 1), 200)))).code, ChaoxingFailureCode.invalidResponse);
      expect(logs, contains('[ChaoxingPack] action=request errorType=too_large route=pickup'));
      expect(logs.where((log) => log.startsWith('[Http]')).every((log) => log.contains('path=/pickup ') && !log.contains('ticket')), isTrue);
    });

    test('私信中转：普通接口 64KB，拉信箱按条数放宽；超了算响应格式不对', () async {
      final big = '{"messages":[],"more":false,"pad":"${'x' * HttpRelayTransport.responseLimit}"}';
      final transport = HttpRelayTransport('http://relay.example:8080', client: MockClient((_) async => http.Response(big, 200)));
      await expectLater(transport.send('GET', '/v1/friends', const {}, null), throwsA(isA<RelayException>().having((error) => error.code, 'code', RelayCode.badResponse)));
      expect(logs.where((log) => log.startsWith('[RelayTransport] action=request route=GET /v1/friends code=BAD_RESPONSE errorType=CampusHttpTooLarge')), hasLength(1));
      final response = await transport.send('GET', '/v1/messages?limit=50', const {}, null, limit: RelayClient.inboxLimit(50));
      expect(response.body['more'], isFalse);
      expect(RelayClient.inboxLimit(50), greaterThan(50 * (256 * 1024 * 4 ~/ 3)), reason: '50 条最大的密文经 base64url 也放得下');
    });
  });

  test('开发者模式关着不记请求', () async {
    campusDiagnostics = false;
    final kernel = CampusHttp('demo', client: MockClient((_) async => http.Response('ok', 200)));
    await kernel.send('GET', Uri.parse('https://example.com/a'), timeout: const Duration(seconds: 5), limit: 8);
    expect(logs, isEmpty);
  });
}

String _ms(String log) => RegExp(r'ms=(\d+)').firstMatch(log)![1]!;

// 响应头立即到、响应体由测试推：记下有没有收到中断信号、订阅有没有被取消。
class _Stalled extends http.BaseClient {
  _Stalled({this.contentLength = 2});
  final int? contentLength;
  late final body = StreamController<List<int>>(onCancel: () {
    if (!cancelled.isCompleted) cancelled.complete();
  });
  final aborted = Completer<void>();
  final started = Completer<void>();
  final cancelled = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    unawaited((request as http.Abortable).abortTrigger!.then((_) {
      if (!aborted.isCompleted) aborted.complete();
    }));
    started.complete();
    return http.StreamedResponse(body.stream, 200, contentLength: contentLength);
  }
}
