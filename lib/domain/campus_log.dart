import 'dart:io';

// [人工决策-2026-09-29 21:16:24] 全项目日志只走这一个出口。Android 上 stderr 不进 logcat（断网同步对照实验坐实），应用与设备端工具入口须注入 debugPrint；默认 stderr 留给纯 Dart 命令行工具与测试。格式 [模块] action=... errorType=...，附完整堆栈，不写原始 HTML、链接或凭据。
void Function(String message) campusLog = stderr.writeln;

// 开发者模式开着时为真（组合根按开发者设置切换）：只在这时才记的诊断记录（请求耗时、页面切换、卡顿与内存）先看它再记，关着时不产生这些记录。
bool campusDiagnostics = false;

// 对外请求的诊断记录：模块、方法、路径、状态码、耗时与响应字节数，只在开发者模式下记。
// 不记域名、查询串、请求与响应内容；路径里像编号的段（含数字且 8 位以上、或 4 位以上纯数字）掩成 :id，免得拼出能打开的地址。
void campusRequestLog(String module, String method, Uri uri, {int? status, required Duration elapsed, int? bytes, String? error}) {
  if (!campusDiagnostics) return;
  final path = uri.pathSegments.map((segment) => _identifier.hasMatch(segment) ? ':id' : segment).join('/');
  campusLog('[Http] module=$module method=$method path=/$path status=${status ?? '-'} ms=${elapsed.inMilliseconds} bytes=${bytes ?? '-'}${error == null ? '' : ' error=$error'}');
}

final _identifier = RegExp(r'^(?=[^.]*\d)[^.]{8,}|^\d{4,}');
