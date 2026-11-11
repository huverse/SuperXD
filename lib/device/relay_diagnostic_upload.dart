import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import 'package:superxd/device/diagnostic_seal.dart';
import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/diagnostic_upload.dart';

// 响应只有诊断编号与保留天数，中转不会超过这么大；超过就当异常，不往下读。
const diagnosticResponseMaxBytes = 8 * 1024;
// 诊断编号：8 位 Crockford base32（同服务端 server/src/modules/diagnostic/diagnostic.store.ts）。
final diagnosticIdPattern = RegExp(r'^[0-9A-HJKMNP-TV-Z]{8}$');

// 诊断包上传的自建中转实现（人工决策见 domain/diagnostic_upload.dart）：先在后台 isolate 里用开发者公钥加密（二十来兆的包在手机上要几秒，不卡界面），
// 再 POST /v1/diagnostics 二进制请求体（免签名，没开私信也能传）。包大、校园网上传可能要几分钟，不用一刀切的 15 秒：
// 连续 stallTimeout 没有进展（发不出去或等不到响应）就中止，整次最多 timeout（服务端收一个请求最多也是 5 分钟）；不自动重试，由用户再点。
// 经共用请求内核 CampusHttp 发：密文文件边读边发、声明长度不分块，无进展超时与整次时限、响应上限与请求记录（模块 diagnostics）都在内核里。
class RelayDiagnosticUpload implements DiagnosticUploader {
  RelayDiagnosticUpload(this.baseUrl, {http.Client? client, this.recipientKey = diagnosticRecipientKey, this.stallTimeout = const Duration(seconds: 30), this.timeout = const Duration(minutes: 5)})
      : _http = CampusHttp('diagnostics', client: client);
  final String baseUrl;
  final String recipientKey;
  final Duration stallTimeout;
  final Duration timeout;
  final CampusHttp _http;

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
    var sent = 0;
    final body = sealed.openRead().map((chunk) {
      sent += chunk.length;
      onProgress?.call(sent / length);
      return chunk;
    });
    final http.Response response;
    try {
      response = await _http.send(
        'POST',
        uri,
        timeout: timeout,
        idleTimeout: stallTimeout,
        limit: diagnosticResponseMaxBytes,
        headers: const {'content-type': 'application/octet-stream'},
        bodyStream: (stream: body, length: length),
      );
    } on TimeoutException catch (_, stack) {
      campusLog('[Diagnostics] action=upload errorType=Timeout\n$stack');
      throw const DiagnosticUploadException('网络太慢没传完，请换个网络再试');
    } on CampusHttpTooLarge catch (error, stack) {
      campusLog('[Diagnostics] action=upload errorType=${error.runtimeType}\n$stack');
      throw const DiagnosticUploadException('服务器暂时不可用，请稍后再试');
    } catch (error, stack) {
      campusLog('[Diagnostics] action=upload errorType=${error.runtimeType}\n$stack');
      throw const DiagnosticUploadException('连不上服务器，请检查网络后再试');
    }
    final status = response.statusCode;
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
      final id = parseDiagnosticReceipt(jsonDecode(utf8.decode(response.bodyBytes)));
      campusLog('[Diagnostics] action=upload id=$id bytes=$length');
      return id;
    } on FormatException catch (error, stack) {
      campusLog('[Diagnostics] action=upload errorType=${error.runtimeType} message=${error.message}\n$stack');
      throw const DiagnosticUploadException('服务器返回的格式不对');
    }
  }
}

// 回执是外部输入：只认格式对的诊断编号，不合格抛 FormatException。
String parseDiagnosticReceipt(Object? json) => switch (json) {
  {'id': final String id} when diagnosticIdPattern.hasMatch(id) => id,
  _ => throw const FormatException('不是诊断包回执'),
};
