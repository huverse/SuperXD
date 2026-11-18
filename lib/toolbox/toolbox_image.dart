import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/toolbox_url.dart';

// 百宝箱里的小网络图（学习通头像、课程封面）：经共用请求内核 CampusHttp 取字节（整次 timeout、响应上限 limit、开发者模式下的请求记录），
// 逐跳只认公网 https、最多跳 5 次；按显示大小解码：铺满边长 side 个物理像素的方块（cover）时短边不小于 side，原图更小就按原图，不多占内存。
// 以前直接用 Image.network：Flutter 自带的 HttpClient 没有超时与上限、不进请求记录，44dp 的头像也按原图解码（性能审查 P1-4、P2-8）。
// 取失败的从图片缓存里拿掉，下次显示时重新取（同 NetworkImage），不自动重试。
@immutable
class ToolboxRemoteImage extends ImageProvider<ToolboxRemoteImage> {
  const ToolboxRemoteImage(this.url, {required this.module, required this.side, this.client});
  final String url;
  // 请求记录里的模块名。
  final String module;
  final int side;
  // 测试注入；为空用默认客户端（每次取图一份、取完关掉）。
  final http.Client Function()? client;

  static const timeout = Duration(seconds: 15);
  static const limit = 2 * 1024 * 1024;

  @override
  Future<ToolboxRemoteImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(ToolboxRemoteImage key, ImageDecoderCallback decode) => MultiFrameImageStreamCompleter(codec: _load(key, decode), scale: 1);

  static Future<ui.Codec> _load(ToolboxRemoteImage key, ImageDecoderCallback decode) async {
    final transport = CampusHttp(key.module, client: key.client?.call());
    try {
      final bytes = await _fetch(transport, key.url);
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes), getTargetSize: (width, height) {
        final scale = math.max(key.side / width, key.side / height);
        return scale >= 1 ? const ui.TargetImageSize() : ui.TargetImageSize(width: math.max(1, (width * scale).ceil()), height: math.max(1, (height * scale).ceil()));
      });
    } catch (error, stack) {
      campusLog('[ToolboxImage] action=load module=${key.module} errorType=${error.runtimeType}\n$stack');
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    } finally {
      transport.close();
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
