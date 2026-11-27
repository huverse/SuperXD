import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';

// 胖乖生活自己的网页里的主机：apwork.cn 码的饮水机页面在 h5.qiekj.com，会员、额度这类在 h5user.qiekj.com，接口在 userapi.qiekj.com；付款跳支付宝的收银台网页。
const _hosts = ['qiekj.com', 'apwork.cn', 'alipay.com', 'alipayobjects.com'];

bool pangguaiWebAllowed(Uri uri) => (uri.scheme == 'https' || uri.scheme == 'http') && _hosts.any((host) => uri.host == host || uri.host.endsWith('.$host'));

// 交给系统打开的外部 scheme（网页里点付款拉起支付宝或微信）。
bool pangguaiWebExternal(Uri uri) => const {'alipays', 'alipay', 'weixin'}.contains(uri.scheme);

// 饮水机（apwork.cn 码，胖乖的合作方设备）：同官方 App，打开胖乖自己的网页，带上这个账号的登录凭据，开水、计时、结算与付款都在网页里完成（用户说饮水机先用现有的，原生的以后再说）。
// 主框架只许停在胖乖与支付宝的网页，拉起支付宝、微信的链接交给系统，其余拦下；离开页面时删掉网页存下的凭据（网页把地址里的 token 写进它自己的 localStorage）。
class PangguaiWaterPage extends StatefulWidget {
  const PangguaiWaterPage({super.key, required this.imei, required this.token});
  final String imei;
  final String token;

  static Uri page(String imei, String token) => Uri.https('h5.qiekj.com', '/black/', {'companyType': 'apwork', 'IMEI': imei, 'token': token});

  @override
  State<PangguaiWaterPage> createState() => _PangguaiWaterPageState();
}

class _PangguaiWaterPageState extends State<PangguaiWaterPage> {
  late final WebViewController _controller;
  var _loading = true;
  String? _error;
  var _leaving = false;

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
          onNavigationRequest: _decide,
        ),
      )
      ..loadRequest(PangguaiWaterPage.page(widget.imei, widget.token));
  }

  NavigationDecision _decide(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.prevent;
    if (pangguaiWebExternal(uri)) {
      unawaited(launchUrl(uri, mode: LaunchMode.externalApplication).catchError((Object error, StackTrace stack) {
        campusLog('[Pangguai] action=web_external errorType=${error.runtimeType}\n$stack');
        return false;
      }));
      return NavigationDecision.prevent;
    }
    if (!request.isMainFrame || pangguaiWebAllowed(uri)) return NavigationDecision.navigate;
    campusLog('[Pangguai] action=web_blocked');
    return NavigationDecision.prevent;
  }

  // 离开前删掉网页存下的凭据（最多等 1 秒，删不掉也走：凭据只在胖乖自己网站的存储里，下次打开会被新的盖掉）。
  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    try {
      await _controller.runJavaScript("try{localStorage.removeItem('token')}catch(e){}").timeout(const Duration(seconds: 1));
    } catch (error) {
      campusLog('[Pangguai] action=web_forget errorType=${error.runtimeType}');
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_leave());
    },
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => unawaited(_leave()), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('饮水机'),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            // 手指落在网页上时拖动全归网页（同快递的验证页：不然 iOS 页面任意位置右滑返回会抢走网页里的横向拖动）。
            WebViewWidget(controller: _controller, gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)}),
            if (_loading) const Align(alignment: Alignment.topCenter, child: LinearProgressIndicator(minHeight: 2)),
            if (_error != null)
              Positioned(left: 16, right: 16, bottom: 24, child: CampusLoadError(message: '网页没打开：$_error', onRetry: () => unawaited(_controller.reload()))),
          ],
        ),
      ),
    ),
  );
}
