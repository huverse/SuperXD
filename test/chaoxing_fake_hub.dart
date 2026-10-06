import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 内存版代签中转：投递拿取件号、取走即删，规则与服务端一致。
// 供客户端测试走完整条代签链路；服务端行为本身由 server/test 的 e2e 覆盖。
class FakePackHub {
  final packs = <String, List<int>>{};
  final calls = <String>[];
  var _next = 0;

  static const maxBytes = 2048;

  http.Client client() => MockClient((request) async {
    calls.add('${request.method} ${request.url.path}');
    final segments = request.url.pathSegments;
    if (request.method == 'POST' && segments.length == 3 && segments[2] == 'packs') {
      final data = '${(jsonDecode(request.body) as Map)['data'] ?? ''}';
      final bytes = data.isEmpty ? <int>[] : base64Url.decode(data.padRight((data.length + 3) ~/ 4 * 4, '='));
      if (bytes.isEmpty) return _error(400, 'INVALID_REQUEST');
      if (bytes.length > maxBytes) return _error(413, 'ENVELOPE_TOO_LARGE');
      final id = 'pickup${(++_next).toString().padLeft(10, '0')}';
      packs[id] = bytes;
      return _json({'id': id, 'expiresAt': DateTime.now().millisecondsSinceEpoch + 600000});
    }
    if (request.method == 'POST' && segments.length == 5 && segments[4] == 'pickup') {
      final bytes = packs.remove(segments[3]);
      if (bytes == null) return _error(404, 'PACK_NOT_FOUND');
      return _json({'data': base64Url.encode(bytes).replaceAll('=', '')});
    }
    return _error(404, 'INVALID_REQUEST');
  });

  static http.Response _json(Object value) => http.Response(
    jsonEncode(value),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  static http.Response _error(int status, String code) => http.Response(
    jsonEncode({'code': code, 'message': code}),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}
