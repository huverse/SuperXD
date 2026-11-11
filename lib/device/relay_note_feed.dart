import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/developer_note.dart';
import 'package:superxd/device/signed_content.dart';

// 清单最多 developerNoteLimit 封、每封正文 developerNoteBodyMax 字，明文一份加签名载荷一份，写满也不到 900KB，
// 中转与 tool/developer_notes.dart 都按 1MB 封顶；响应超过就当异常，不往下读。
const developerNoteResponseMaxBytes = 1024 * 1024;

// 开发者的话的自建中转实现：GET /v1/app/notes，请求免设备签名、不带任何标识，单次 15 秒超时、不自动重试。
// 只认验签通过的内容（人工决策见 device/signed_content.dart），没有签名或验不过按失败处理。
class RelayNoteFeed implements DeveloperNoteFeed {
  RelayNoteFeed(this.baseUrl, {this.keys = trustedSigningKeys, http.Client? client, this.timeout = const Duration(seconds: 15)}) : _client = client ?? http.Client();
  final String baseUrl;
  final List<TrustedSigningKey> keys;
  final Duration timeout;
  final http.Client _client;

  @override
  Future<List<DeveloperNote>> fetch() async {
    final uri = Uri.parse('$baseUrl/v1/app/notes');
    final int status;
    final List<int> body;
    // 开发者模式下记一条路径、状态、耗时与字节数（见 campusRequestLog）。
    final watch = Stopwatch()..start();
    try {
      final response = await _client.send(http.Request('GET', uri)).timeout(timeout);
      status = response.statusCode;
      body = await _read(response.stream).timeout(timeout);
      campusRequestLog('developer_notes', 'GET', uri, status: status, elapsed: watch.elapsed, bytes: body.length);
    } on DeveloperNoteException {
      rethrow;
    } catch (error, stack) {
      campusRequestLog('developer_notes', 'GET', uri, elapsed: watch.elapsed, error: error is TimeoutException ? 'timeout' : error.runtimeType.toString());
      campusLog('[DeveloperNotes] action=feed errorType=${error.runtimeType}\n$stack');
      throw const DeveloperNoteException('连不上服务器，请检查网络后再试');
    }
    if (status == 429 || status == 503) throw const DeveloperNoteException('请求太频繁，请稍后再试');
    if (status != 200) {
      campusLog('[DeveloperNotes] action=feed status=$status');
      throw const DeveloperNoteException('服务器暂时不可用，请稍后再试');
    }
    try {
      return await decodeSignedDeveloperNotes(jsonDecode(utf8.decode(body)), keys: keys);
    } on SignedEnvelopeException catch (error, stack) {
      campusLog('[DeveloperNotes] action=feed errorType=${error.runtimeType} reason=${error.reason}\n$stack');
      throw const DeveloperNoteException('内容没通过校验，请稍后再试');
    } on FormatException catch (error, stack) {
      campusLog('[DeveloperNotes] action=feed errorType=${error.runtimeType} message=${error.message}\n$stack');
      throw const DeveloperNoteException('内容格式不对，请稍后再试');
    }
  }

  Future<List<int>> _read(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
      if (bytes.length > developerNoteResponseMaxBytes) throw const DeveloperNoteException('服务器暂时不可用，请稍后再试');
    }
    return bytes;
  }
}

// 中转的返回：明文 notes（给旧客户端）一律不用，只取 envelope 验签，载荷交给 domain 的 decodeDeveloperNotes。
// 唯一例外：中转上还没放过信时给空列表、不带信封，这和中间人把内容扣下效果相同（签名本来就挡不住扣下），按没有信处理。
Future<List<DeveloperNote>> decodeSignedDeveloperNotes(Object? response, {List<TrustedSigningKey> keys = trustedSigningKeys}) async {
  if (response is! Map) throw const FormatException('不是开发者的话清单');
  if (response['envelope'] == null && response['notes'] is List && (response['notes'] as List).isEmpty) return const [];
  final payload = await openSignedEnvelope(response['envelope'], SignedContent.notes, keys: keys);
  return decodeDeveloperNotes(jsonDecode(utf8.decode(payload)));
}
