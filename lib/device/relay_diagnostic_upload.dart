import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import 'package:superxd/device/diagnostic_seal.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/diagnostic_upload.dart';

// 响应只有诊断编号与保留天数，中转不会超过这么大；超过就当异常，不往下读。
const diagnosticResponseMaxBytes = 8 * 1024;
// 诊断编号：8 位 Crockford base32（同服务端 server/src/modules/diagnostic/diagnostic.store.ts）。
final diagnosticIdPattern = RegExp(r'^[0-9A-HJKMNP-TV-Z]{8}$');

// 诊断包上传的自建中转实现（人工决策见 domain/diagnostic_upload.dart）：先在后台 isolate 里用开发者公钥加密（二十来兆的包在手机上要几秒，不卡界面），
// 再 POST /v1/diagnostics 二进制请求体（免签名，没开私信也能传）。包大、校园网上传可能要几分钟，不用一刀切的 15 秒：
// 连续 stallTimeout 没有进展（发不出去或等不到响应）就中止，整次最多 timeout（服务端收一个请求最多也是 5 分钟）；不自动重试，由用户再点。
class RelayDiagnosticUpload implements DiagnosticUploader {
  RelayDiagnosticUpload(this.baseUrl, {http.Client? client, this.recipientKey = diagnosticRecipientKey, this.stallTimeout = const Duration(seconds: 30), this.timeout = const Duration(minutes: 5)})
      : _client = client ?? http.Client();
  final String baseUrl;
  final String recipientKey;
  final Duration stallTimeout;
  final Duration timeout;
  final http.Client _client;

  @override
  Future<String> upload(String archivePath, {void Function(double sent)? onProgress}) async {
    final sealedPath = '$archivePath.sealed', key = decodeDiagnosticKey(recipientKey);
    try {
      final length = await Isolate.run(() async {
        final sealed = await sealDiagnostic(await File(archivePath).readAsBytes(), key);
        await File(sealedPath).writeAsBytes(sealed, flush: true);
        return sealed.length;
      });
      return await _send(File(sealedPath), length, onProgress);
    } finally {
      final sealed = File(sealedPath);
      if (await sealed.exists()) await sealed.delete();
    }
  }

  Future<String> _send(File sealed, int length, void Function(double sent)? onProgress) async {
    final uri = Uri.parse('$baseUrl/v1/diagnostics');
    // 看门狗：每发出一块、每收到一块都重新计时；到点触发中止（IOClient 真的断开连接），同时让正在等的那一步抛超时。
    final abort = Completer<void>();
    void stop() {
      if (!abort.isCompleted) abort.complete();
    }
    Timer? stall;
    void progress() {
      stall?.cancel();
      stall = Timer(stallTimeout, stop);
    }
    final deadline = Timer(timeout, stop);
    Future<T> guarded<T>(Future<T> future) => Future.any([future, abort.future.then<T>((_) => throw TimeoutException('上传没有进展'))]);
    var sent = 0;
    final body = sealed.openRead().map((chunk) {
      sent += chunk.length;
      progress();
      onProgress?.call(sent / length);
      return chunk;
    });
    final watch = Stopwatch()..start();
    final int status;
    final List<int> response;
    try {
      progress();
      final streamed = await guarded(_client.send(_UploadRequest(uri, body, length, abort.future)));
      status = streamed.statusCode;
      response = await guarded(_read(streamed.stream, progress));
      campusRequestLog('diagnostics', 'POST', uri, status: status, elapsed: watch.elapsed, bytes: response.length);
    } on DiagnosticUploadException {
      rethrow;
    } catch (error, stack) {
      final stalled = abort.isCompleted;
      campusRequestLog('diagnostics', 'POST', uri, elapsed: watch.elapsed, error: stalled ? 'timeout' : error.runtimeType.toString());
      campusLog('[Diagnostics] action=upload errorType=${stalled ? 'Timeout' : error.runtimeType}\n$stack');
      throw DiagnosticUploadException(stalled ? '网络太慢没传完，请换个网络再试' : '连不上服务器，请检查网络后再试');
    } finally {
      stall?.cancel();
      deadline.cancel();
    }
    switch (status) {
      case 200:
        break;
      case 429:
        throw const DiagnosticUploadException('上传太频繁，请过一会儿再试');
      case 503:
        throw const DiagnosticUploadException('服务器暂时存满了，请过几天再试，或改用导出日志');
      default:
        campusLog('[Diagnostics] action=upload status=$status');
        throw DiagnosticUploadException(status == 413 ? '日志包超过上传上限，请改用导出日志' : '服务器暂时不可用，请稍后再试');
    }
    try {
      final id = parseDiagnosticReceipt(jsonDecode(utf8.decode(response)));
      campusLog('[Diagnostics] action=upload id=$id bytes=$length');
      return id;
    } on FormatException catch (error, stack) {
      campusLog('[Diagnostics] action=upload errorType=${error.runtimeType} message=${error.message}\n$stack');
      throw const DiagnosticUploadException('服务器返回的格式不对');
    }
  }

  Future<List<int>> _read(Stream<List<int>> stream, void Function() progress) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      progress();
      bytes.addAll(chunk);
      if (bytes.length > diagnosticResponseMaxBytes) throw const DiagnosticUploadException('服务器暂时不可用，请稍后再试');
    }
    return bytes;
  }
}

// 回执是外部输入：只认格式对的诊断编号，不合格抛 FormatException。
String parseDiagnosticReceipt(Object? json) => switch (json) {
  {'id': final String id} when diagnosticIdPattern.hasMatch(id) => id,
  _ => throw const FormatException('不是诊断包回执'),
};

// 请求体直接用（数着字节的）文件流，声明长度、不分块；可中止（IOClient 收到 abortTrigger 即断开）。
final class _UploadRequest extends http.BaseRequest with http.Abortable {
  _UploadRequest(Uri url, this._body, int length, this.abortTrigger) : super('POST', url) {
    contentLength = length;
    headers['content-type'] = 'application/octet-stream';
  }
  final Stream<List<int>> _body;
  @override
  final Future<void>? abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_body);
  }
}
