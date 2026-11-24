import 'dart:async';
import 'dart:convert';

import 'package:synchronized/synchronized.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/express/express_models.dart';

// 登录与绑定/解绑类请求前现取一个 v2 anti_content 的端口。anti_content 有时效：每次请求现生成、不缓存。
// [人工决策-2026-10-20 17:22:42] 见 express_models.dart：为让绑定/解绑可用，用隐藏 WebView 跑拼多多官方反爬 JS 产出合法 anti_content，
// 不自行重写风控、仅用于本人已授权账号的取件手机号管理；[人工决策-2026-10-30 18:03:16] 起查物流也带，[人工决策-2026-10-31 13:01:46] 起查物流又不带。
// 测试注入假实现（webViewController 为空、不起真实 WebView）。
abstract interface class PddAntiContent {
  Future<String> generate();

  // 生产实现要页面把这个 controller 离屏挂成 WebViewWidget（挂上才稳当地跑指纹 canvas）；假实现返回 null。
  WebViewController? get webViewController;
}

// 隐藏 WebView 实现：加载官方 mdkd 页，注入官方 chunk 把反爬 SDK 的生成器（包装模块，见 antiContentCapture）捕获到 window.__sxdGen，再调它取 anti_content。
// 10-22 真机（OPPO）查清生成器丢失的主因：这个隐藏页没有登录态，加载完几秒后会自己跳去 login.html、再试图拉起拼多多 App，
// 一跳走 window 全局（含 __sxdGen）就没了——每次生成都要先等满 8 秒、再重载重试，约 10 秒，偶尔两次都失败。
// （10-20 记的「被弹层盖住后 webpack 失效」多半也是它。）所以只许主框架停在官方 mdkd 页，跳走的导航一律拦下；
// 仍保留自适应兜底：生成器不在就重载官方页重建，一次没取到再重载重试一次。
class WebViewAntiContent implements PddAntiContent {
  WebViewAntiContent() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(PddConstants.userAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: antiPageNavigation,
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
  // 只有一个隐藏页：同时重载会互相顶掉 _loaded，所以排队一个一个生成。
  final _lock = Lock();

  @override
  WebViewController get webViewController => _controller;

  @override
  Future<String> generate() => _lock.synchronized(_generate);

  Future<String> _generate() async {
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
    await _controller.runJavaScript(antiContentCapture);
    // 没捕获到时记下卡在哪（module 是找不到包装模块、export 是它没导出函数，别的是 JS 报错），拼多多改版时一看就知道。
    final missing = _asString(await _controller.runJavaScriptReturningResult('window.__sxdGenError'));
    if (missing.isNotEmpty) campusLog('[Express] action=anti_setup errorType=${missing.length > 80 ? missing.substring(0, 80) : missing}');
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

// 把官方反爬 SDK 的生成器捕获到 window.__sxdGen 的注入脚本（首次 push 一个 chunk，拿到 webpack 的 require）。
// 不写死模块编号：拼多多每次重新发布 mdkd 页都可能变，11-24 用户真机诊断包里从 89320 变成了 9406，按旧编号取报
// 「Cannot read properties of undefined (reading 'call')」、绑定手机号报「风控令牌生成失败」。改在 webpack 的模块表（require.m）里按内容找
// 包装模块：同时含 messagePackSync（SDK 的生成方法）与 SERVER_TIME_URL（它先取服务器时间）的那一个，两版都只有它一个；导出名也不写死（现在是 a），
// 取它导出的函数。找不到时 window.__sxdGenError 写原因、__sxdGen 留空，交给重载重试与日志。
const antiContentCapture = 'window.__sxdGen=null;window.__sxdGenError="";'
    'try{self.webpackChunk_N_E.push([[990099],{990099:function(t,e,n){'
    'var id=null;for(var k in n.m){var s=String(n.m[k]);if(s.indexOf("messagePackSync")>=0&&s.indexOf("SERVER_TIME_URL")>=0){id=k;break}}'
    'if(id===null){window.__sxdGenError="module";return}'
    'var x=n(id),f=typeof x.a==="function"?x.a:null;'
    'if(!f){for(var p in x){if(typeof x[p]==="function"){f=x[p];break}}}'
    'if(!f){window.__sxdGenError="export";return}'
    'window.__sxdGen=function(){return f()}'
    '}},function(n){n(990099)}])}catch(e){window.__sxdGenError=String(e)}';

// 隐藏页的导航规则（见 WebViewAntiContent 类注释）：主框架只许停在官方 mdkd 页，跳登录页、拉起 App 的外部 scheme 一律拦下；子框架只放行网页地址。
NavigationDecision antiPageNavigation(NavigationRequest request) {
  final page = Uri.parse(PddConstants.antiContentPage);
  final uri = Uri.tryParse(request.url);
  final web = uri != null && (uri.scheme == 'https' || uri.scheme == 'http');
  final stays = request.isMainFrame ? web && uri.host == page.host && uri.path == page.path : web;
  return stays ? NavigationDecision.navigate : NavigationDecision.prevent;
}
