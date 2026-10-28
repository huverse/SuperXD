import 'package:flutter/services.dart';

import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/domain/campus_log.dart';

class ChannelFilePublisher implements ToolboxFilePublisher {
  static const _channel = MethodChannel('superxd/toolbox_files');
  @override
  Future<Uri?> publish({
    required String id,
    required String source,
    required String filename,
    required String mimeType,
  }) async {
    try {
      final value = await _channel.invokeMethod<String>('publish', {
        'id': id,
        'source': source,
        'filename': filename,
        'mimeType': mimeType,
      });
      return value == null ? null : Uri.parse(value);
    } on PlatformException catch (error) {
      // 原生的错误码（没权限、相册拒收、参数不对）与系统错误号记下来，堆栈由下载管理记；只记种类分不清为什么存不进去。
      campusLog('[ToolboxFiles] action=publish errorType=${error.code} details=${error.details}');
      rethrow;
    }
  }

  @override
  Future<Uri?> publishExternal({
    required String source,
    required String filename,
    required String mimeType,
  }) async {
    final value = await _channel.invokeMethod<String>('publishExternal', {
      'source': source,
      'filename': filename,
      'mimeType': mimeType,
    });
    return value == null ? null : Uri.parse(value);
  }

  @override
  Future<void> open(Uri uri, String mimeType) => _channel.invokeMethod<void>(
    'open',
    {'uri': uri.toString(), 'mimeType': mimeType},
  );
}
