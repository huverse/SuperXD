import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

import 'package:superxd/toolbox/toolbox_image.dart';

// 百宝箱的小网络图（学习通头像、课程封面）：经请求内核取（超时、上限、只认公网 https），按显示大小解码（性能审查 P1-4、P2-8）。
void main() {
  final wide = Uint8List.fromList(img.encodePng(img.Image(width: 400, height: 200)..clear(img.ColorRgb8(90, 120, 160))));

  // 取一次：成功给解出来的图，失败给错误。
  Future<Object> load(ToolboxRemoteImage provider) {
    final done = Completer<Object>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      done.complete(info);
    }, onError: (error, _) {
      stream.removeListener(listener);
      done.complete(error);
    });
    stream.addListener(listener);
    return done.future;
  }

  setUp(() => PaintingBinding.instance.imageCache.clear());

  // 人工决策见 toolbox_image.dart 的 ToolboxRemoteImage 与 ToolboxImageGate（11-21 总交接第 7.3、7.5 节）。
  test('没注入客户端时一个模块共用一份请求内核（跨图片复用连接），不同模块各一份', () {
    expect(identical(ToolboxRemoteImage.transportFor('cinema'), ToolboxRemoteImage.transportFor('cinema')), isTrue);
    expect(identical(ToolboxRemoteImage.transportFor('cinema'), ToolboxRemoteImage.transportFor('chaoxing_image')), isFalse);
  });

  testWidgets('同时最多取 concurrency 张，其余排队；视频打开或卡住时先等、放开了再取', (tester) async {
    // 在真实时间里建（在假时钟里建的已完成 future，后来才等它的会卡在假时钟的微任务里）。
    final gate = (await tester.runAsync(() async => Completer<void>()))!;
    var running = 0, most = 0, requests = 0;
    // 注入的客户端每张图取完都会关掉，所以每张各给一个。
    Future<http.Response> handler(http.Request request) async {
      requests++;
      running++;
      most = running > most ? running : most;
      await gate.future;
      running--;
      return http.Response.bytes(wide, 200);
    }

    final owner = Object();
    ToolboxImageGate.hold(owner);
    addTearDown(() => ToolboxImageGate.release(owner));
    // 在真实时间里发起（解码要真的异步），之后都在 runAsync 里等。
    final loads = (await tester.runAsync(() async => [for (var index = 0; index < ToolboxRemoteImage.concurrency + 4; index++) load(ToolboxRemoteImage('https://p.example.com/$index.png', module: 'cinema', side: 44, client: () => MockClient(handler)))]))!;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    expect(requests, 0, reason: '播放在等，图先不取');
    ToolboxImageGate.release(owner);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    expect(most, ToolboxRemoteImage.concurrency);
    final results = await tester.runAsync(() {
      gate.complete();
      return Future.wait(loads);
    });
    expect(results!.whereType<ImageInfo>(), hasLength(ToolboxRemoteImage.concurrency + 4));
    expect(most, ToolboxRemoteImage.concurrency);
  });

  testWidgets('按铺满边长 side 的方块解码：短边就是 side 个像素，不按原图', (tester) async {
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      return http.Response.bytes(wide, 200);
    });
    final result = await tester.runAsync(() => load(ToolboxRemoteImage('https://p.example.com/a.png', module: 'chaoxing_image', side: 66, client: () => client)));
    final info = result! as ImageInfo;
    expect((info.image.width, info.image.height), (132, 66));
    expect(requests.single.host, 'p.example.com');
    info.dispose();
  });

  testWidgets('只认公网 https：明文、内网与跳到内网的都不取', (tester) async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response('', 302, headers: {'location': 'https://192.168.1.2/b.png'}, isRedirect: true);
    });
    for (final url in ['http://p.example.com/a.png', 'https://10.0.0.1/a.png', 'https://localhost/a.png']) {
      final error = await tester.runAsync(() => load(ToolboxRemoteImage(url, module: 'chaoxing_image', side: 66, client: () => client)));
      expect(error, isNot(isA<ImageInfo>()), reason: url);
    }
    expect(calls, 0);
    final error = await tester.runAsync(() => load(ToolboxRemoteImage('https://p.example.com/redirect.png', module: 'chaoxing_image', side: 66, client: () => client)));
    expect(error, isNot(isA<ImageInfo>()));
    expect(calls, 1, reason: '跳到内网的那一跳不发');
  });

  testWidgets('跳到别的公网 https 照常取；失败的不留在缓存里，下次显示重新取', (tester) async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (request.url.path == '/old.png') return http.Response('', 302, headers: {'location': '/new.png'}, isRedirect: true);
      return calls < 3 ? http.Response('busy', 503) : http.Response.bytes(wide, 200);
    });
    final provider = ToolboxRemoteImage('https://p.example.com/old.png', module: 'chaoxing_image', side: 44, client: () => client);
    final failed = await tester.runAsync(() => load(provider));
    expect(failed, isNot(isA<ImageInfo>()));
    await tester.pump();
    final info = (await tester.runAsync(() => load(provider)))! as ImageInfo;
    expect(info.image.height, 44);
    expect(calls, 4, reason: '第一次跳一次拿到 503，第二次重新跳一次再取到');
    info.dispose();
  });

  testWidgets('超过上限的不收；一直不回的到时限放弃', (tester) async {
    final huge = MockClient((request) async => http.Response.bytes(Uint8List(ToolboxRemoteImage.limit + 1), 200));
    final error = await tester.runAsync(() => load(ToolboxRemoteImage('https://p.example.com/huge.png', module: 'chaoxing_image', side: 44, client: () => huge)));
    expect(error, isNot(isA<ImageInfo>()));

    final stuck = MockClient((request) => Completer<http.Response>().future);
    Object? outcome;
    unawaited(load(ToolboxRemoteImage('https://p.example.com/stuck.png', module: 'chaoxing_image', side: 44, client: () => stuck)).then((value) => outcome = value));
    await tester.pump(ToolboxRemoteImage.timeout - const Duration(seconds: 1));
    expect(outcome, isNull);
    await tester.pump(const Duration(seconds: 2));
    expect(outcome, isA<TimeoutException>());
  });
}
