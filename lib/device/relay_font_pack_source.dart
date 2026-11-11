import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/font_pack.dart';

// 字体包文件的自建中转实现（人工决策见 domain/font_pack.dart）：GET /v1/app/files/<文件名>（免签名、不带任何标识，同安装包下载），
// 进程内流式写进目标文件。等响应头 15 秒、两块数据之间最多停 30 秒，超时算失败；响应超过登记的大小就停，不往下收；不自动重试。
// SHA-256 由调用方（local/font_packs.dart）核对，这里只管传输。
class RelayFontPackSource implements FontPackSource {
  RelayFontPackSource(this.baseUrl, {http.Client Function()? client, this.timeout = const Duration(seconds: 15), this.idle = const Duration(seconds: 30)}) : _client = client ?? http.Client.new;
  final String baseUrl;
  final Duration timeout;
  final Duration idle;
  final http.Client Function() _client;

  @override
  Future<void> download(FontPackFile file, String target, {required void Function(int received) onProgress, required Future<void> abort}) async {
    if (!fontPackFileName.hasMatch(file.name)) throw ArgumentError.value(file.name, 'file');
    final uri = Uri.parse('$baseUrl/v1/app/files/${file.name}');
    var aborted = false;
    unawaited(abort.then((_) => aborted = true));
    // 每个文件一个连接，用完关掉；取消时 abortTrigger 立刻断开连接（卡在等数据时也不用等到超时）。
    final client = _client();
    final watch = Stopwatch()..start();
    var received = 0;
    int? status;
    IOSink? sink;
    try {
      final response = await client.send(http.AbortableRequest('GET', uri, abortTrigger: abort)).timeout(timeout);
      status = response.statusCode;
      if (status != 200) throw FontPackException(_statusMessage(status));
      final length = response.contentLength;
      if (length != null && length != file.size) throw const FontPackException('字体文件不对，请稍后再试');
      sink = File(target).openWrite();
      await for (final chunk in response.stream.timeout(idle)) {
        if (aborted) throw const FontPackCancelled();
        received += chunk.length;
        if (received > file.size) throw const FontPackException('字体文件不对，请稍后再试');
        sink.add(chunk);
        onProgress(received);
      }
      if (aborted) throw const FontPackCancelled();
      await sink.flush();
      campusRequestLog('font_pack', 'GET', uri, status: status, elapsed: watch.elapsed, bytes: received);
    } on FontPackException {
      campusRequestLog('font_pack', 'GET', uri, status: status, elapsed: watch.elapsed, bytes: received);
      rethrow;
    } on FontPackCancelled {
      campusRequestLog('font_pack', 'GET', uri, status: status, elapsed: watch.elapsed, error: 'cancelled');
      rethrow;
    } catch (error, stack) {
      if (aborted) {
        campusRequestLog('font_pack', 'GET', uri, status: status, elapsed: watch.elapsed, error: 'cancelled');
        throw const FontPackCancelled();
      }
      campusRequestLog('font_pack', 'GET', uri, status: status, elapsed: watch.elapsed, error: error is TimeoutException ? 'timeout' : error.runtimeType.toString());
      campusLog('[FontPack] action=download file=${file.name} errorType=${error.runtimeType}\n$stack');
      throw const FontPackException('连不上服务器，请检查网络后重试');
    } finally {
      await sink?.close();
      client.close();
    }
  }

  static String _statusMessage(int status) => switch (status) {
    404 => '服务器上还没有这个字体，请稍后再试',
    429 || 503 => '下载的人太多，请稍后再试',
    _ => '服务器暂时不可用，请稍后再试',
  };
}
