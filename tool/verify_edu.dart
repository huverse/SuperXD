import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as html;
import 'package:enough_convert/enough_convert.dart';
import 'package:http/http.dart' as http;

import 'package:superxd/edu/kingo_client.dart';

// 凭据只从stdin获取，不使用命令行参数/文件，输出只有状态和结构统计。
Future<void> main() async {
  final input = jsonDecode((await stdin.transform(utf8.decoder).join()).trim()) as Map<String, dynamic>;
  final transport = _InspectClient();
  final client = KingoClient(client: transport);
  try {
    final login = await client.login(input.remove('account') as String, input.remove('password') as String);
    stdout.writeln(jsonEncode({'login': login.ok, 'needsCaptcha': login.needsCaptcha, 'error': login.failure?.code}));
    if (!login.ok || login.needsCaptcha) return;
    for (final term in [('2026', '0'), ('2026', '1'), ('2025', '0'), ('2025', '1')]) {
      try {
        final data = await client.fetchSchedule(xn: term.$1, xq: term.$2, userCode: login.userCode);
        stdout.writeln(jsonEncode({'term': '${term.$1}-${term.$2}', 'kind': 'schedule', 'rows': data.courses.length, 'courses': data.courses.map((c) => c.courseCode).toSet().length, 'meetings': data.courses.fold(0, (n, c) => n + c.meetings.length)}));
      } on KingoCallException catch (error, stack) {
        stderr.writeln('[VerifyEdu] errorType=${error.runtimeType}\n$stack');
        stdout.writeln(jsonEncode({'term': '${term.$1}-${term.$2}', 'error': error.failure.code, 'reason': error.failure.message}));
      }
      final bells = await client.fetchBells(xn: term.$1, xq: term.$2);
      stdout.writeln(jsonEncode({'term': '${term.$1}-${term.$2}', 'kind': 'bells', 'empty': bells.empty, 'periods': bells.periods.length}));
    }
  } catch (error, stack) {
    stderr.writeln('[VerifyEdu] errorType=${error.runtimeType}\n$stack');
    exitCode = 1;
  } finally { client.dispose(); }
}

class _InspectClient extends http.BaseClient {
  final _client = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _client.send(request);
    final bytes = await response.stream.toBytes();
    if (request.url.path.contains('xkjg.ckdgxsxdkchj_data')) {
      final header = '${response.headers['content-type']} ${latin1.decode(bytes.take(1000).toList())}';
      final document = html.parse(header.toLowerCase().contains('gb') ? gbk.decode(bytes) : utf8.decode(bytes, allowMalformed: true));
      for (final node in document.querySelectorAll('script, style')) { node.remove(); }
      if (document.querySelectorAll('tr').isEmpty) {
        final text = document.body?.text.replaceAll(RegExp(r'\d{5,}'), '[id]') ?? '';
        stdout.writeln(jsonEncode({'emptyPageCues': RegExp(r'.{0,5}(?:未|没有|无|暂无).{0,35}').allMatches(text).map((m) => m.group(0)).toList()}));
      }
      final text = document.body?.text ?? '';
      final count = RegExp(r'课程门数\s*[：:]\s*(\d+)').firstMatch(text)?.group(1);
      final widths = document.querySelectorAll('tr').map((r) => r.children.where((e) => e.localName == 'td').length).toList();
      stdout.writeln(jsonEncode({'http': response.statusCode, 'count': count, 'cellCounts': widths, 'emptyWords': ['没有课程记录', '暂无课程', '未选课', '没有数据', '无数据', '无课程'].where(text.contains).toList(), 'title': text.contains('学生个人课表')}));
    }
    return http.StreamedResponse(Stream.value(bytes), response.statusCode, headers: response.headers, request: request);
  }
  @override
  void close() => _client.close();
}
