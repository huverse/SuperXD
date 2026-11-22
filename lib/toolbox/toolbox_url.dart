import 'dart:io';

import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/toolbox/toolbox_models.dart';

// anyPort：不限端口（电影院的媒体地址：片源的 CDN 常用非标准端口），本机与内网照样拒绝。
Uri toolboxPublicUrl(String value, {bool httpsOnly = false, bool anyPort = false}) {
  if (value.length > 8192) throw const ToolboxException('链接过长');
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      !(httpsOnly
          ? uri.scheme == 'https'
          : const {'http', 'https'}.contains(uri.scheme)) ||
      (!anyPort && uri.hasPort && uri.port != (uri.scheme == 'https' ? 443 : 80))) {
    throw const ToolboxException('请使用公开的网页链接');
  }
  final host = uri.host.toLowerCase().replaceAll(RegExp(r'\.$'), '');
  final address = InternetAddress.tryParse(host);
  if ((address == null && !host.contains('.')) ||
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal') ||
      (address != null && !campusPublicAddress(address))) {
    throw const ToolboxException('不支持本机或内网地址');
  }
  return uri.removeFragment();
}

Uri shortVideoInput(String value) {
  if (value.length > 8192) throw const ToolboxException('分享内容过长，请只粘贴作品链接');
  final links = RegExp(r'''https?://[^\s<>"'，。！；、（）]+''', caseSensitive: false)
      .allMatches(value)
      .map(
        (match) => match.group(0)!.replaceFirst(RegExp(r'[)\]}>.,!;]+$'), ''),
      )
      .toSet();
  if (links.length != 1) {
    throw ToolboxException(links.isEmpty ? '请粘贴一个作品链接' : '请只保留一个作品链接');
  }
  return toolboxPublicUrl(links.single);
}
