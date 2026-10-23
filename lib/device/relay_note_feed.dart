import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/developer_note.dart';

// 清单最多 developerNoteLimit 封、每封正文 developerNoteBodyMax 字，中转按 512KB 封顶；响应超过就当异常，不往下读。
const developerNoteResponseMaxBytes = 512 * 1024;

// 开发者的话的自建中转实现：GET /v1/app/notes，免签名、不带任何标识，单次 15 秒超时、不自动重试。
class RelayNoteFeed implements DeveloperNoteFeed {
  RelayNoteFeed(this.baseUrl, {http.Client? client, this.timeout = const Duration(seconds: 15)}) : _client = client ?? http.Client();
  final String baseUrl;
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
      return decodeDeveloperNotes(jsonDecode(utf8.decode(body)));
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
