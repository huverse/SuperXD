import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';

import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/toolbox/toolbox_url.dart';
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
  http.Client? _client;
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
    _client?.close();
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
    final client = widget.createClient?.call() ?? http.Client();
    final abort = Completer<void>();
    _client = client;
    _abort = abort;
    setState(() => _failed = false);
    final url = widget.url;
    try {
      final bytes = await (() async {
        var uri = toolboxPublicUrl(url.toString(), httpsOnly: true);
        for (var redirect = 0; redirect < 5; redirect++) {
          final request = http.AbortableRequest(
            'GET',
            uri,
            abortTrigger: abort.future,
          )..followRedirects = false;
          final response = await client.send(request);
          if (response.isRedirect) {
            final location = response.headers['location'];
            await response.stream.listen(null).cancel();
            if (location == null) throw const FormatException('缺少图片跳转地址');
            uri = toolboxPublicUrl(
              uri.resolve(location).toString(),
              httpsOnly: true,
            );
            continue;
          }
          if (response.statusCode != 200 ||
              (response.contentLength ?? 0) > 12 * 1024 * 1024) {
            throw const FormatException('图片不可用');
          }
          final buffer = BytesBuilder(copy: false);
          await for (final chunk in response.stream) {
            if (buffer.length + chunk.length > 12 * 1024 * 1024) {
              throw const FormatException('图片超过预览限制');
            }
            buffer.add(chunk);
          }
          final data = buffer.takeBytes();
          final type = lookupMimeType(
            'image',
            headerBytes: data.take(64).toList(),
          );
          if (type == null || !type.startsWith('image/')) {
            throw const FormatException('响应不是图片');
          }
          return data;
        }
        throw const FormatException('图片跳转过多');
      })().timeout(const Duration(seconds: 15));
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
        TextButton(onPressed: _load, child: const Text('重试图片')),
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
