import 'package:webview_flutter/webview_flutter.dart';

import 'package:superxd/domain/campus_log.dart';

// 清掉 WebView 里残留的拼多多 Cookie。WebView 的 CookieManager 是进程级单例，与安全存储里的会话各存一份：
// 退出登录/清除数据只删了安全存储，残留的旧 Cookie（登录态等同凭据，异地登录后已被作废）会被下次登录页一加载就读到、
// 直接判成「已登录」关页返回，功能照样失效。所以重新登录前、退出登录与清除数据时都清一次。
// 没有 WebView 平台（纯单元测试）或清理失败不阻断调用方：记一行日志后继续。
Future<void> clearExpressWebCookies() async {
  try {
    await WebViewCookieManager().clearCookies();
  } catch (error, stack) {
    campusLog('[Express] action=clear_cookies errorType=${error.runtimeType}\n$stack');
  }
}
