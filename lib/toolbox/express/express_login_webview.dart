import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/toolbox/express/express_cookies.dart';
import 'package:superxd/toolbox/express/express_models.dart';

// 拼多多官方 H5 登录页（WebView）：用户在官方页面完成短信/扫码登录，组件从原生 Cookie 读 PDDAccessToken 组装会话。
// 不生成、不绕过 anti_content 与风控指纹，这些由拼多多官方页面自己处理。
class ExpressLoginWebView extends StatefulWidget {
  const ExpressLoginWebView({super.key, required this.onLogin});
  final ValueChanged<PddSession> onLogin;

  @override
  State<ExpressLoginWebView> createState() => _ExpressLoginWebViewState();
}

class _ExpressLoginWebViewState extends State<ExpressLoginWebView> {
  late final WebViewController _controller;
  final _cookies = WebViewCookieManager();
  Timer? _poll;
  bool _found = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
            _checkSession();
          },
          onWebResourceError: (error) {
            if (mounted && error.isForMainFrame == true) setState(() => _error = error.description);
          },
          onNavigationRequest: _decideNavigation,
        ),
      );
    _begin();
  }

  // 重新登录必须从干净的 Cookie 开始：先清掉残留的旧会话 Cookie，再加载登录页，再启动兜底轮询。
  // 否则登录页一加载就被 _checkSession 读到作废的旧 PDDAccessToken，直接判「已登录」关页返回、功能照样失效。
  Future<void> _begin() async {
    await clearExpressWebCookies();
    if (!mounted) return;
    await _controller.loadRequest(Uri.parse(PddConstants.loginPage));
    // 登录成功后页面不一定触发 onPageFinished，轮询兜底。
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _checkSession());
  }

  // 只许拼多多相关域名，拦下 pinduoduo:// 等外部 scheme，避免跳出 WebView 打开 App。
  NavigationDecision _decideNavigation(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return NavigationDecision.prevent;
    const hosts = ['yangkeduo.com', 'pinduoduo.com', 'pinduoduo.net', 'pddpic.com'];
    final allowed = hosts.any((host) => uri.host == host || uri.host.endsWith('.$host'));
    return allowed ? NavigationDecision.navigate : NavigationDecision.prevent;
  }

  Future<void> _checkSession() async {
    if (_found) return;
    final session = await _readSession();
    if (session != null && !_found && mounted) {
      _found = true;
      _poll?.cancel();
      widget.onLogin(session);
    }
  }

  // PDDAccessToken 是 HttpOnly Cookie，JS 读不到，经原生 CookieManager 可读。
  Future<PddSession?> _readSession() async {
    final domains = [
      Uri.parse('https://mobile.yangkeduo.com/'),
      Uri.parse('https://m.pinduoduo.net/'),
      Uri.parse('https://api.pinduoduo.com/'),
    ];
    final seen = <String>{};
    final parts = <String>[];
    var accessToken = '';
    var installToken = '';
    var etag = '';
    var userId = '';
    for (final domain in domains) {
      List<WebViewCookie> cookies;
      try {
        cookies = await _cookies.getCookies(domain: domain);
      } catch (error, stack) {
        campusLog('[Express] action=read_cookies errorType=${error.runtimeType}\n$stack');
        continue;
      }
      for (final cookie in cookies) {
        if (seen.add('${cookie.name}=${cookie.value}')) parts.add('${cookie.name}=${cookie.value}');
        switch (cookie.name) {
          case 'PDDAccessToken':
            accessToken = cookie.value;
          case 'install_token':
            installToken = cookie.value;
          case 'ETag':
            etag = cookie.value;
          case 'pdd_user_id':
            userId = cookie.value;
        }
      }
    }
    if (accessToken.isEmpty) return null;
    return PddSession(accessToken: accessToken, cookie: parts.join('; '), installToken: installToken, etag: etag, userId: userId);
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录拼多多'),
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.of(context).maybePop(), icon: const CampusIcon(CampusIcons.back)),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_loading) const Align(alignment: Alignment.topCenter, child: LinearProgressIndicator(minHeight: 2)),
            if (_error != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: 24,
                child: CampusLoadError(message: '登录页加载失败：$_error', onRetry: () => _controller.reload()),
              ),
          ],
        ),
      ),
    );
  }
}
