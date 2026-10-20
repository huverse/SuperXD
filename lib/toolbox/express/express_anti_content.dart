import 'dart:async';
import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/express/express_models.dart';

// 绑定/解绑请求前现取一个 v2 anti_content 的端口。anti_content 有时效：每次请求现生成、不缓存。
// [人工决策-2026-10-20 17:22:42] 见 express_models.dart：为让绑定/解绑可用，用隐藏 WebView 跑拼多多官方反爬 JS 产出合法 anti_content，
// 不自行重写风控、仅用于本人已授权账号的取件手机号管理。测试注入假实现（webViewController 为空、不起真实 WebView）。
abstract interface class PddAntiContent {
  Future<String> generate();

  // 生产实现要页面把这个 controller 离屏挂成 WebViewWidget（挂上才稳当地跑指纹 canvas）；假实现返回 null。
  WebViewController? get webViewController;
}

// 隐藏 WebView 实现：加载官方 mdkd 页，注入官方 chunk 把反爬 SDK（模块 89320→28828/25039）的生成器捕获到 window.__sxdGen，再调它取 anti_content。
// 真机实测：这个离屏 WebView 被弹层/对话框盖住后，Next.js 的 webpack 运行时会失效、window 全局丢失、.push 退化成普通数组追加不再执行模块；
// 恢复只能靠重新加载页面。故自适应：生成器不在（页面被重置）就重载官方页重建，一次没取到再重载重试一次。
class WebViewAntiContent implements PddAntiContent {
  WebViewAntiContent() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(PddConstants.userAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            final loaded = _loaded;
            if (loaded != null && !loaded.isCompleted) loaded.complete();
          },
          onWebResourceError: (error) {
            final loaded = _loaded;
            if (loaded != null && !loaded.isCompleted && error.isForMainFrame == true) {
              campusLog('[Express] action=anti_page errorType=load');
              loaded.completeError(const ExpressFailure(ExpressFailureCode.network, '风控页加载失败，请检查网络'));
            }
          },
        ),
      );
  }

  late final WebViewController _controller;
  Completer<void>? _loaded;
  var _counter = 0;

  @override
  WebViewController get webViewController => _controller;

  @override
  Future<String> generate() async {
    // 生成器不在（首次，或页面被盖住后重置了）就重载官方页重建。
    if (!await _hasGen()) await _loadAndSetup();
    final value = await _invoke();
    if (value != null) return value;
    // 没取到（可能刚被重置）：重载重建再试一次。
    await _loadAndSetup();
    final retry = await _invoke();
    if (retry != null) return retry;
    throw const ExpressFailure(ExpressFailureCode.server, '风控令牌生成失败，请稍后重试');
  }

  Future<bool> _hasGen() async {
    try {
      return _asString(await _controller.runJavaScriptReturningResult('typeof window.__sxdGen')) == 'function';
    } catch (_) {
      return false;
    }
  }

  // 重新加载官方页（页面被重置后 webpack 要重新初始化，只能靠重载），再把生成器捕获到 window.__sxdGen（首次 push，刚加载完 webpack 就绪、必执行）。
  Future<void> _loadAndSetup() async {
    final loaded = Completer<void>();
    _loaded = loaded;
    await _controller.loadRequest(Uri.parse(PddConstants.antiContentPage));
    await loaded.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () => throw const ExpressFailure(ExpressFailureCode.network, '风控页加载超时，请检查网络'),
    );
    await _controller.runJavaScript(
      'window.__sxdGen=null;'
      'try{self.webpackChunk_N_E.push([[990099],{990099:function(t,e,n){'
      'window.__sxdGen=function(){return n(89320).a()}}},function(n){n(990099)}])}catch(e){}',
    );
  }

  // 调一次生成器取 anti_content；拿到返回，超时或报错返回 null（交给上层重载重试）。
  Future<String?> _invoke() async {
    final slot = '__sxdAnti${_counter++}';
    await _controller.runJavaScript(
      'window.$slot="";window.${slot}E="";'
      'try{window.__sxdGen().then(function(v){window.$slot=v||""}).catch(function(x){window.${slot}E=String(x)})}'
      'catch(x){window.${slot}E=String(x)}',
    );
    for (var i = 0; i < 80; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final value = _asString(await _controller.runJavaScriptReturningResult('window.$slot'));
      if (value.isNotEmpty) return value;
      final error = _asString(await _controller.runJavaScriptReturningResult('window.${slot}E'));
      if (error.isNotEmpty) {
        // 错误文本截断入日志帮诊断风控/模块变动（JS 错误串，不含凭据）。
        final detail = error.length > 80 ? error.substring(0, 80) : error;
        campusLog('[Express] action=anti_content errorType=js detail=$detail');
        return null;
      }
    }
    return null;
  }

  // runJavaScriptReturningResult 各平台可能回带引号的 JSON 串，去壳取纯字符串。
  String _asString(Object? raw) {
    final text = '$raw';
    if (text == 'null' || text.isEmpty) return '';
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      try {
        return jsonDecode(text) as String;
      } catch (_) {}
    }
    return text;
  }
}
