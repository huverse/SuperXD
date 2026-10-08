import 'package:flutter/services.dart';

import 'package:superxd/toolbox/toolbox_models.dart';

class AndroidFilePublisher implements ToolboxFilePublisher {
  static const _channel = MethodChannel('superxd/toolbox_files');
  @override
  Future<Uri?> publish({
    required String id,
    required String source,
    required String filename,
    required String mimeType,
  }) async {
    final value = await _channel.invokeMethod<String>('publish', {
      'id': id,
      'source': source,
      'filename': filename,
      'mimeType': mimeType,
    });
    return value == null ? null : Uri.parse(value);
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
