import 'dart:io';

// [人工决策-2026-09-29 21:16:24] 全项目日志只走这一个出口。Android 上 stderr 不进 logcat（断网同步对照实验坐实），应用与设备端工具入口须注入 debugPrint；默认 stderr 留给纯 Dart 命令行工具与测试。格式 [模块] action=... errorType=...，附完整堆栈，不写原始 HTML、链接或凭据。
void Function(String message) campusLog = stderr.writeln;
