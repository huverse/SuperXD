import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:superxd/toolbox/download/channel_file_publisher.dart';
import 'package:superxd/toolbox/express/express_anti_content.dart';
import 'package:superxd/toolbox/express/express_client.dart';
import 'package:superxd/toolbox/express/express_cookies.dart';
import 'package:superxd/toolbox/express/express_models.dart';
import 'package:superxd/toolbox/express/express_vault.dart';
import 'package:superxd/toolbox/express/express_verify_webview.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_module.dart';

// 快递（拼多多身份码与快递查询）的服务：只持有登录会话的安全存储与建客户端的工厂，
// 没有自己的业务库——身份码不落盘，待取件即查即用（安全存储里只另记每件寄到的手机尾号）。框架（ToolboxRuntime）只给目录与公共能力。
class ExpressService implements ToolboxService {
  ExpressService({
    required this.vault,
    ExpressClient Function(PddSession session)? clientFactory,
    this.antiContent,
    this.filePublisher = ChannelFilePublisher.new,
    this.temporaryDirectory = getTemporaryDirectory,
    this.launchExternal = _launchExternal,
    this.verifyPage = _verifyPage,
  }) : clientFactory = clientFactory ?? ((session) => ExpressClient(session: session));
  final ExpressVault vault;

  // 建客户端的工厂：测试注入走假 HTTP 的客户端。
  final ExpressClient Function(PddSession session) clientFactory;

  // 绑定/解绑要用的 anti_content 生成器（隐藏 WebView）；测试注入假实现、不起真实 WebView。
  final PddAntiContent? antiContent;

  // 只能微信取件时把驿站码存进相册（一次性导出到公共目录）与拉起微信用；测试注入假实现。
  final ToolboxFilePublisher Function() filePublisher;
  final Future<Directory> Function() temporaryDirectory;
  final Future<bool> Function(Uri uri) launchExternal;

  static Future<bool> _launchExternal(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

  // 拼多多要求先过安全验证时打开的官方验证页（关页时返回是否通过）；测试注入不起 WebView 的假页面。
  final Widget Function(String token) verifyPage;

  static Widget _verifyPage(String token) => ExpressVerifyWebView(token: token);

  // 工具 id：路由、服务与同意记录共用（同意记录里存的就是它，不能改）。
  static const serviceId = 'express';

  static Future<ExpressService> open(ToolboxServiceContext context) async => ExpressService(vault: SecureExpressVault(), antiContent: WebViewAntiContent());

  @override
  Future<void> close() async {}

  // 清除数据：安全存储里本工具命名空间下的登录会话全删，WebView 残留的会话 Cookie 也一并清（登录态等同凭据，退出即删）；
  // 拼多多账号本身与其服务器上的数据不动。
  @override
  Future<void> clearData() async {
    await vault.deleteAll();
    await clearExpressWebCookies();
  }
}
