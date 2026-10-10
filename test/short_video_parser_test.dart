import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:superxd/toolbox/short_video/media_resource.dart';
import 'package:superxd/toolbox/short_video/bugpk_video_parser.dart';
import 'package:superxd/toolbox/short_video/parse_coordinator.dart';
import 'package:superxd/toolbox/short_video/parse_http.dart';
import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/short_video/parse_source.dart';
import 'package:superxd/toolbox/short_video/short_video_controller.dart';
import 'package:superxd/toolbox/short_video/short_video_service.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_url.dart';

import 'toolbox_test_support.dart';

void main() {
  final input = Uri.parse('https://v.douyin.com/example/');
  test('分享只提取单一公开链接', () {
    expect(
      shortVideoInput('分享 https://v.douyin.com/example/，看看').host,
      'v.douyin.com',
    );
    for (final value in [
      '无链接',
      'https://example.com/a https://example.org/b',
      'http://127.0.0.1/a',
      'https://10.1.1.1/a',
      'https://user:pass@example.com/a',
      'https://localhost/a',
      'https://example.com:8080/a',
      'file:///etc/passwd',
    ]) {
      expect(() => shortVideoInput(value), throwsA(isA<ToolboxException>()));
    }
  });
  test('同服务抖音接口及聚合路由只由适配器决定，无教务Cookie', () async {
    final paths = <String>[];
    final parser = BugpkVideoParser(
      client: MockClient((request) async {
        paths.add(request.url.path);
        expect(request.headers.containsKey('cookie'), isFalse);
        expect(request.followRedirects, isFalse);
        return http.Response(
          jsonEncode({
            'code': 200,
            'data': {'url': 'https://cdn.example.com/video.mp4'},
          }),
          200,
        );
      }),
    );
    final result = await parser.resolve(input, ToolboxCancellation());
    await parser.resolve(
      Uri.parse('https://example.com/work'),
      ToolboxCancellation(),
    );
    expect(paths, ['/api/douyin', '/api/short_videos']);
    expect(result.resources.single.kind, MediaKind.video);
    parser.close();
  });
  test('图集、作者对象、实况配对与音乐契约归一化', () {
    final parser = BugpkVideoParser();
    final result = parser.normalize({
      'type': 'live',
      'author': {'name': '测试'},
      'images': ['https://cdn.example.com/a.jpg'],
      'live_photo': [
        {
          'image': 'https://cdn.example.com/a.jpg',
          'video': 'https://cdn.example.com/a.mp4',
        },
      ],
      'music': {'url': 'https://cdn.example.com/music.mp3'},
      'time': 1780000000,
    }, input);
    expect(result.author, '测试');
    expect(result.images, hasLength(1));
    expect(result.videos.single.pairedImageId, result.images.single.id);
    expect(result.audio, hasLength(1));
    parser.close();
  });
  test('陌生响应、业务错误、非HTTPS、内网及清单拒绝', () async {
    for (final body in [
      '<html>blocked</html>',
      '[]',
      '{"code":500}',
      for (final url in [
        'http://cdn.example.com/a.mp4',
        'https://127.0.0.1/a.mp4',
        'https://cdn.example.com/a.m3u8',
      ])
        jsonEncode({
          'code': 200,
          'data': {'url': url},
        }),
    ]) {
      final parser = BugpkVideoParser(
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(
        parser.resolve(input, ToolboxCancellation()),
        throwsA(anyOf(isA<ParseFailure>(), isA<ToolboxException>())),
      );
      parser.close();
    }
  });
  test('429携带有界冷却，JSON体容量不超过1MiB', () async {
    for (final response in [
      http.Response('', 429, headers: {'retry-after': '99999'}),
      http.Response('x' * (ParseHttp.payloadLimit + 1), 200),
    ]) {
      final parser = BugpkVideoParser(
        client: MockClient((_) async => response),
      );
      await expectLater(
        parser.resolve(input, ToolboxCancellation()),
        throwsA(isA<ParseFailure>()),
      );
      parser.close();
    }
  });
  test('超时覆盖响应体并abort，取消无需等超时', () async {
    for (final cancel in [false, true]) {
      final transport = _StalledClient();
      final parser = BugpkVideoParser(
        client: transport,
        timeout: const Duration(milliseconds: 30),
      );
      final token = ToolboxCancellation();
      final result = parser.resolve(input, token);
      final assertion = expectLater(result, throwsA(isA<ParseFailure>()));
      await transport.started.future;
      if (cancel) token.cancel();
      await assertion;
      await transport.aborted.future.timeout(const Duration(seconds: 1));
      await transport.body.close();
      parser.close();
    }
  });
  test('自动有序切源、只调用已启用同意源，手动不回退', () async {
    final first = _Provider('first')
      ..failure = const ParseFailure(ParseFailureCode.provider, '失败');
    final second = _Provider('second');
    final hidden = _Provider('hidden');
    final coordinator = ParseCoordinator([first, second, hidden]);
    final outcome = await coordinator.parse(
      input,
      selected: 'auto',
      enabled: {'first', 'second'},
      consented: {'first', 'second'},
      cancellation: ToolboxCancellation(),
    );
    expect(outcome.result.providerId, 'second');
    expect(outcome.attempts, hasLength(2));
    expect(hidden.calls, 0);
    final manual = ParseCoordinator([
      _Provider('first')
        ..failure = const ParseFailure(ParseFailureCode.provider, '失败'),
      second,
    ]);
    await expectLater(
      manual.parse(
        input,
        selected: 'first',
        enabled: {'first', 'second'},
        consented: {'first', 'second'},
        cancellation: ToolboxCancellation(),
      ),
      throwsA(isA<ParseFailure>()),
    );
    expect(second.calls, 1);
  });
  test('未授权不调用，来源冷却及缓存不串源，刷新绕缓存', () async {
    var now = DateTime.utc(2026);
    final first = _Provider('first');
    final second = _Provider('second');
    final coordinator = ParseCoordinator([first, second], clock: () => now);
    await expectLater(
      coordinator.parse(
        input,
        selected: 'auto',
        enabled: {'first'},
        consented: {},
        cancellation: ToolboxCancellation(),
      ),
      throwsA(isA<ParseFailure>()),
    );
    expect(first.calls, 0);
    await coordinator.parse(
      input,
      selected: 'first',
      enabled: {'first'},
      consented: {'first'},
      cancellation: ToolboxCancellation(),
    );
    expect(
      (await coordinator.parse(
        input,
        selected: 'first',
        enabled: {'first'},
        consented: {'first'},
        cancellation: ToolboxCancellation(),
      )).fromCache,
      isTrue,
    );
    await coordinator.parse(
      input,
      selected: 'second',
      enabled: {'second'},
      consented: {'second'},
      cancellation: ToolboxCancellation(),
    );
    expect(second.calls, 1);
    now = now.add(const Duration(seconds: 1));
    await coordinator.parse(
      input,
      selected: 'first',
      enabled: {'first'},
      consented: {'first'},
      cancellation: ToolboxCancellation(),
      refresh: true,
    );
    expect(first.calls, 2);
  });
  test('总预算和取消中断整条尝试链', () async {
    final hanging = _Provider('first')..pending = Completer<ParseResult>();
    final second = _Provider('second');
    final coordinator = ParseCoordinator([
      hanging,
      second,
    ], budget: const Duration(milliseconds: 30));
    await expectLater(
      coordinator.parse(
        input,
        selected: 'auto',
        enabled: {'first', 'second'},
        consented: {'first', 'second'},
        cancellation: ToolboxCancellation(),
      ),
      throwsA(isA<ParseFailure>()),
    );
    expect(second.calls, 0);
    expect(hanging.token!.isCancelled, isTrue);
  });
  test('输入清空后迟到结果不能写回', () async {
    final fixture = ToolboxFixture();
    await fixture.initialize();
    final provider = _Provider('first')..pending = Completer<ParseResult>();
    final coordinator = ParseCoordinator([provider]);
    await fixture.store.grantConsent('first', '1');
    final controller = ShortVideoController(
      ShortVideoService(coordinator: coordinator, store: fixture.shortVideo.store, downloads: fixture.manager, consents: fixture.store),
    );
    await controller.initialize();
    final parsing = controller.parse(input.toString());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    controller.invalidate();
    provider.pending!.complete(provider.result(input));
    await parsing;
    expect(controller.outcome, isNull);
    expect(controller.busy, isFalse);
    controller.dispose();
    await fixture.close();
  });
}

class _Provider implements ParseProvider {
  _Provider(String id)
    : source = ParseSource(
        id: id,
        name: id,
        host: 'example.com',
        version: '1',
        consentVersion: '1',
      );
  @override
  final ParseSource source;
  int calls = 0;
  ParseFailure? failure;
  Completer<ParseResult>? pending;
  ToolboxCancellation? token;
  ParseResult result(Uri uri) => ParseResult(
    sourceUrl: uri,
    providerId: source.id,
    title: 'test',
    author: '',
    resources: [
      MediaResource(
        id: 'video',
        kind: MediaKind.video,
        url: Uri.parse('https://cdn.example.com/video.mp4'),
        label: '视频',
      ),
    ],
  );
  @override
  bool supports(Uri uri) => true;
  @override
  Future<ParseResult> resolve(Uri uri, ToolboxCancellation cancellation) async {
    calls++;
    token = cancellation;
    if (failure != null) throw failure!;
    return pending == null ? result(uri) : await pending!.future;
  }

  @override
  void close() {}
}

class _StalledClient extends http.BaseClient {
  final body = StreamController<List<int>>();
  final aborted = Completer<void>();
  final started = Completer<void>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    (request as http.AbortableRequest).abortTrigger!.then((_) {
      if (!aborted.isCompleted) aborted.complete();
    });
    started.complete();
    return http.StreamedResponse(body.stream, 200);
  }
}
