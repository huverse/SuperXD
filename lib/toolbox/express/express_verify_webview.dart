import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/toolbox/express/express_models.dart';

// 拼多多官方安全验证页（接口回 54001 时打开，同官方 mdkd 页面的做法）：由用户本人在官方页面完成验证，
// 页面验证完跳回 from 指定的官方 mdkd 页，跳到那里就算通过、关页返回 true；中途返回算没通过。应用不替用户做验证、不读页面内容。
class ExpressVerifyWebView extends StatefulWidget {
  const ExpressVerifyWebView({super.key, required this.token});
  final String token;

  @override
  State<ExpressVerifyWebView> createState() => _ExpressVerifyWebViewState();
}

class _ExpressVerifyWebViewState extends State<ExpressVerifyWebView> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _done = false;
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
          },
          onWebResourceError: (error) {
            if (mounted && error.isForMainFrame == true) setState(() => _error = error.description);
          },
          onNavigationRequest: _decideNavigation,
        ),
      )
      ..loadRequest(Uri.parse(PddConstants.verifyPage).replace(queryParameters: {'VerifyAuthToken': widget.token, 'from': PddConstants.verifyReturn}));
  }

  // 跳回 from（官方 mdkd 页）就是验证通过；其余只许拼多多相关域名，拦下拉起 App 的外部 scheme。
  NavigationDecision _decideNavigation(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return NavigationDecision.prevent;
    if (request.isMainFrame && request.url.startsWith(PddConstants.verifyReturn)) {
      if (!_done && mounted) {
        _done = true;
        Navigator.of(context).pop(true);
      }
      return NavigationDecision.prevent;
    }
    const hosts = ['yangkeduo.com', 'pinduoduo.com', 'pinduoduo.net', 'pddpic.com'];
    final allowed = !request.isMainFrame || hosts.any((host) => uri.host == host || uri.host.endsWith('.$host'));
    return allowed ? NavigationDecision.navigate : NavigationDecision.prevent;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('安全验证'),
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.of(context).maybePop(false), icon: const CampusIcon(CampusIcons.back)),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            // 手指落在网页上时拖动全归网页：不然 iOS 页面任意位置右滑返回会抢走横向拖动，滑块验证码拖不动、整页跟着滑走（10-28 iPhone 截图）。
            WebViewWidget(controller: _controller, gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)}),
            if (_loading) const Align(alignment: Alignment.topCenter, child: LinearProgressIndicator(minHeight: 2)),
            if (_error != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: 24,
                child: CampusLoadError(message: '验证页加载失败：$_error', onRetry: () => _controller.reload()),
              ),
          ],
        ),
      ),
    );
  }
}
