import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:pool/pool.dart';

import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/toolbox_url.dart';

// 百宝箱里的小网络图（学习通头像、课程封面）：经共用请求内核 CampusHttp 取字节（整次 timeout、响应上限 limit、开发者模式下的请求记录），
// 逐跳只认公网 https、最多跳 5 次；按显示大小解码：铺满边长 side 个物理像素的方块（cover）时短边不小于 side，原图更小就按原图，不多占内存。
// 以前直接用 Image.network：Flutter 自带的 HttpClient 没有超时与上限、不进请求记录，44dp 的头像也按原图解码（性能审查 P1-4、P2-8）。
// 取失败的从图片缓存里拿掉，下次显示时重新取（同 NetworkImage），不自动重试。
// [人工决策-2026-11-21 14:04:30] 共用连接与同时取的上限（11-21 Codex 总交接第 7.3 节，用户说按最佳实践做）：原来每张图各建一份 CampusHttp、
// 取完就关，一屏十几张海报各自重新握手；改成每个模块共用一份（随进程存在，Dart 默认空闲 15 秒断开，一屏海报是一阵一阵取的够用），
// 同时最多取 concurrency 张（其余排队），不和播放、搜索抢带宽。测试注入了 client 的仍是每次一份、用完关掉。
@immutable
class ToolboxRemoteImage extends ImageProvider<ToolboxRemoteImage> {
  const ToolboxRemoteImage(this.url, {required this.module, required this.side, this.client});
  final String url;
  // 请求记录里的模块名。
  final String module;
  final int side;
  // 测试注入（每次取图一份、取完关掉）；为空用这个模块共用的那份（transportFor）。
  final http.Client Function()? client;

  static const timeout = Duration(seconds: 15);
  static const limit = 2 * 1024 * 1024;
  static const concurrency = 6;
  static final _shared = <String, CampusHttp>{};
  static final _pool = Pool(concurrency);

  // 一个模块共用的那份（随进程存在，不关）。
  @visibleForTesting
  static CampusHttp transportFor(String module) => _shared.putIfAbsent(module, () => CampusHttp(module));

  @override
  Future<ToolboxRemoteImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(ToolboxRemoteImage key, ImageDecoderCallback decode) => MultiFrameImageStreamCompleter(codec: _load(key, decode), scale: 1);

  static Future<ui.Codec> _load(ToolboxRemoteImage key, ImageDecoderCallback decode) async {
    final injected = key.client;
    final transport = injected == null ? transportFor(key.module) : CampusHttp(key.module, client: injected());
    try {
      // 播放优先（见 ToolboxImageGate）：视频在打开或卡住缓冲时先等一等，再排进同时取的上限里。
      await ToolboxImageGate.wait();
      final bytes = await _pool.withResource(() => _fetch(transport, key.url));
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes), getTargetSize: (width, height) {
        final scale = math.max(key.side / width, key.side / height);
        return scale >= 1 ? const ui.TargetImageSize() : ui.TargetImageSize(width: math.max(1, (width * scale).ceil()), height: math.max(1, (height * scale).ceil()));
      });
    } catch (error, stack) {
      campusLog('[ToolboxImage] action=load module=${key.module} errorType=${error.runtimeType}\n$stack');
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    } finally {
      if (injected != null) transport.close();
    }
  }

  static Future<Uint8List> _fetch(CampusHttp client, String url) async {
    final watch = Stopwatch()..start();
    var uri = toolboxPublicUrl(url, httpsOnly: true);
    for (var hop = 0; hop < 5; hop++) {
      final response = await client.send('GET', uri, timeout: timeout - watch.elapsed, limit: limit, followRedirects: false);
      if (response.isRedirect) {
        final location = response.headers['location'];
        if (location == null) throw const FormatException('缺少图片跳转地址');
        uri = toolboxPublicUrl(uri.resolve(location).toString(), httpsOnly: true);
        continue;
      }
      if (response.statusCode != 200) throw FormatException('图片不可用：${response.statusCode}');
      return response.bodyBytes;
    }
    throw const FormatException('图片跳转过多');
  }

  @override
  bool operator ==(Object other) => other is ToolboxRemoteImage && other.url == url && other.module == module && other.side == side;

  @override
  int get hashCode => Object.hash(url, module, side);
}

// [人工决策-2026-11-21 14:04:30] 播放优先（11-21 Codex 总交接第 7.5 节，用户说按最佳实践做）：电影院播放页在打开视频、卡住缓冲时 hold，
// 这期间新的小网络图先等着（最多 holdLimit，免得一直不出图），播放顺了 release 再取；海报、头像在播放时都不急。
// 只管经 ToolboxRemoteImage 取的图（Dart 这一侧）；播放器自己取分片不归它管，不能说成全链路统一调度。
class ToolboxImageGate {
  static const holdLimit = Duration(seconds: 10);
  static final _holders = <Object>{};
  static Completer<void>? _opened;

  static bool get held => _holders.isNotEmpty;

  static void hold(Object owner) => _holders.add(owner);

  static void release(Object owner) {
    if (!_holders.remove(owner) || _holders.isNotEmpty) return;
    _opened?.complete();
    _opened = null;
  }

  static Future<void> wait() {
    if (_holders.isEmpty) return Future.value();
    return (_opened ??= Completer<void>()).future.timeout(holdLimit, onTimeout: () {});
  }
}
