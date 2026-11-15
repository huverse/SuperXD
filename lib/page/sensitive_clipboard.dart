import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_log.dart';

// 复制恢复码这类敏感内容（人工决策见 domain/app_account.dart 的 19:18:31 那条）：安卓经 SensitiveClipboard.kt 标成敏感内容
// （ClipDescription 的 EXTRA_IS_SENSITIVE，Android 13 起剪贴板预览不显示原文），iOS 经 AppDelegate.swift 的 SensitiveClipboard 只放本机、不进通用剪贴板；
// 一分钟后清掉，只在剪贴板里还是这一串时才清（安卓在后台读不到剪贴板，等回到前台再看；iOS 用系统的过期时刻）。
// 没有这个通道的平台（测试、桌面）退回普通复制；原生出错时打印堆栈后同样退回，复制这一步总能完成。
const _channel = MethodChannel('superxd/sensitive_clipboard');
const sensitiveClearAfter = Duration(minutes: 1);

Future<void> copySensitive(String text) async {
  try {
    await _channel.invokeMethod<void>('copy', {'text': text, 'clearAfterMs': sensitiveClearAfter.inMilliseconds});
  } on MissingPluginException {
    await Clipboard.setData(ClipboardData(text: text));
  } on PlatformException catch (error, stack) {
    campusLog('[SensitiveClipboard] action=copy errorType=${error.runtimeType} code=${error.code}\n$stack');
    await Clipboard.setData(ClipboardData(text: text));
  }
}
