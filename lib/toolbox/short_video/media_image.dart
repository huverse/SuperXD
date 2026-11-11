import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';

import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/toolbox/toolbox_url.dart';
import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';

class MediaImage extends StatefulWidget {
  const MediaImage({
    super.key,
    required this.url,
    this.width = 800,
    this.createClient,
  });
  final Uri url;
  final int width;
  final http.Client Function()? createClient;
  @override
  State<MediaImage> createState() => _MediaImageState();
}

class _MediaImageState extends State<MediaImage> {
  CampusHttp? _http;
  Completer<void>? _abort;
  bool _failed = false;
  ImageProvider? _image;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url || widget.width != oldWidget.width) _load();
  }

  void _release() {
    final abort = _abort;
    if (abort != null && !abort.isCompleted) abort.complete();
    _http?.close();
    _image?.evict().catchError((Object error, StackTrace stack) {
      campusLog(
        '[MediaImage] action=evict errorType=${error.runtimeType}\n$stack',
      );
      return false;
    });
    _image = null;
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _release();
    final client = CampusHttp('short_video_image', client: widget.createClient?.call());
    final abort = Completer<void>();
    _http = client;
    _abort = abort;
    setState(() => _failed = false);
    try {
      final bytes = await _fetch(client, abort.future);
      if (mounted && generation == _generation) {
        setState(
          () => _image = ResizeImage(
            MemoryImage(bytes),
            width: widget.width,
            allowUpscaling: false,
          ),
        );
      }
    } catch (error, stack) {
      campusLog(
        '[MediaImage] action=load errorType=${error.runtimeType}\n$stack',
      );
      if (mounted && generation == _generation) setState(() => _failed = true);
    } finally {
      if (!abort.isCompleted) abort.complete();
      client.close();
    }
  }

  // 逐跳只认公网 https，最多跳 5 次；总共 15 秒、图片上限 12MB。每一跳经共用内核 CampusHttp 发：
  // 到点或换图、离开时中断连接，开发者模式下每跳记一条状态、耗时与字节数（路径不带域名与查询串）。
  Future<Uint8List> _fetch(CampusHttp client, Future<void> abort) async {
    final watch = Stopwatch()..start();
    var uri = toolboxPublicUrl(widget.url.toString(), httpsOnly: true);
    try {
      for (var redirect = 0; redirect < 5; redirect++) {
        final response = await client.send(
          'GET',
          uri,
          timeout: _budget - watch.elapsed,
          limit: _limit,
          followRedirects: false,
          cancel: abort,
        );
        if (response.isRedirect) {
          final location = response.headers['location'];
          if (location == null) throw const FormatException('缺少图片跳转地址');
          uri = toolboxPublicUrl(
            uri.resolve(location).toString(),
            httpsOnly: true,
          );
          continue;
        }
        if (response.statusCode != 200) {
          throw const FormatException('图片不可用');
        }
        final data = response.bodyBytes;
        final type = lookupMimeType(
          'image',
          headerBytes: data.take(64).toList(),
        );
        if (type == null || !type.startsWith('image/')) {
          throw const FormatException('响应不是图片');
        }
        return data;
      }
    } on CampusHttpTooLarge catch (_, stack) {
      Error.throwWithStackTrace(const FormatException('图片超过预览限制'), stack);
    }
    throw const FormatException('图片跳转过多');
  }

  static const _budget = Duration(seconds: 15);
  static const _limit = 12 * 1024 * 1024;

  @override
  void dispose() {
    _generation++;
    _release();
    super.dispose();
  }

  Widget _failure() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('图片不可用'),
        TextButton.icon(onPressed: _load, icon: const CampusIcon(CampusIcons.sync), label: const Text('重试图片')),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => _failed
      ? _failure()
      : _image == null
      ? const Center(child: CampusLoading(label: '加载图片'))
      : Image(
          image: _image!,
          fit: BoxFit.contain,
          errorBuilder: (_, error, stack) {
            campusLog(
              '[MediaImage] action=decode errorType=${error.runtimeType}\n$stack',
            );
            return _failure();
          },
        );
}
