import 'dart:convert';

import 'package:enough_convert/enough_convert.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import 'package:superxd/edu/kingo_client.dart';
import 'package:superxd/gateway/kingo_campus_gateway.dart';
import 'package:superxd/local/account_store.dart';
import 'package:superxd/domain/campus_log.dart';

// 仅复用当前已登录的授权会话只读取成绩结构，不登录、不保存成绩、不输出凭据或成绩明细。
Future<void> main() async {
  campusLog = debugPrint;
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('只读成绩结构验证'))),
    ),
  );
  final store = await AccountStore.open();
  final identity = await store.currentIdentity();
  if (identity == null) {
    debugPrint('[GradesVerify] no_active_account');
    await store.close();
    return;
  }
  final database = await store.openAccount(identity);
  final client = KingoClient(client: _InspectClient(), base: identity.source);
  try {
    final gateway = KingoCampusGateway(database: database, client: client);
    final session = await gateway.restoreSession();
    if (!session.ok) {
      debugPrint('[GradesVerify] session_unavailable');
      return;
    }
    final form = await client.fetchGradeForm();
    for (final term in [('2025', '0'), ('2026', '0')]) {
      final pages = await client.fetchGrades(
        xn: term.$1,
        xq: term.$2,
        rxnj: form.rxnj,
        nj: form.nj,
      );
      debugPrint(
        '[GradesVerify] term=${term.$1}-${term.$2} effective=${pages.effective.courses.length} original=${pages.original.courses.length} identityPresent=${pages.effective.loginId.isNotEmpty} termLabel=${pages.effective.termLabel}',
      );
    }
  } catch (error, stack) {
    debugPrint('[GradesVerify] errorType=${error.runtimeType}\n$stack');
  } finally {
    client.dispose();
    await database.close();
    await store.close();
  }
}

class _InspectClient extends http.BaseClient {
  final _client = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _client.send(request);
    final bytes = await response.stream.toBytes();
    if (request.url.path.contains('xscj.stuckcj_data')) {
      final header =
          '${response.headers['content-type']} ${latin1.decode(bytes.take(1000).toList())}';
      final document = html.parse(
        header.toLowerCase().contains('gb')
            ? gbk.decode(bytes)
            : utf8.decode(bytes, allowMalformed: true),
      );
      for (final table in document.querySelectorAll('table')) {
        final rows = table
            .querySelectorAll('tr')
            .map(
              (row) => row.children
                  .where(
                    (cell) => cell.localName == 'td' || cell.localName == 'th',
                  )
                  .map(
                    (cell) => cell.text.replaceAll(RegExp(r'\s+'), '').trim(),
                  )
                  .toList(),
            )
            .toList();
        final headers = rows
            .where(
              (row) => row.any(
                (cell) => const [
                  '序号',
                  '课程',
                  '课程名称',
                  '加权平均分',
                  '合计',
                  '平均学分绩点',
                ].contains(cell),
              ),
            )
            .map(
              (row) => row
                  .map(
                    (cell) => RegExp(r'\d').hasMatch(cell)
                        ? '[value]'
                        : cell.length > 40
                        ? '[long]'
                        : cell,
                  )
                  .toList(),
            )
            .toList();
        if (headers.isNotEmpty) {
          debugPrint(
            '[GradesVerify] headers=${jsonEncode(headers)} widths=${rows.map((row) => row.length).toSet()}',
          );
          if (table.text.contains('加权平均')) {
            final structure = table
                .querySelectorAll('tr')
                .take(3)
                .map(
                  (row) => row.children
                      .where(
                        (cell) =>
                            cell.localName == 'td' || cell.localName == 'th',
                      )
                      .map(
                        (cell) => {
                          'label': RegExp(r'\d').hasMatch(cell.text)
                              ? '[value]'
                              : cell.text.trim(),
                          'rowspan': cell.attributes['rowspan'],
                          'colspan': cell.attributes['colspan'],
                        },
                      )
                      .toList(),
                )
                .toList();
            debugPrint(
              '[GradesVerify] summaryStructure=${jsonEncode(structure)}',
            );
          }
        }
      }
      final text = document.body?.text ?? '';
      debugPrint(
        '[GradesVerify] title=${text.contains('学生成绩')} emptyCues=${['没有成绩', '暂无成绩', '没有检索到记录', '没有符合条件的记录'].where(text.contains).toList()}',
      );
    }
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }

  @override
  void close() => _client.close();
}
