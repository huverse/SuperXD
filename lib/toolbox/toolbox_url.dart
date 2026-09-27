import 'dart:io';

import 'package:superxd/toolbox/toolbox_models.dart';

Uri toolboxPublicUrl(String value, {bool httpsOnly = false}) {
  if (value.length > 8192) throw const ToolboxException('链接过长');
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      !(httpsOnly
          ? uri.scheme == 'https'
          : const {'http', 'https'}.contains(uri.scheme)) ||
      (uri.hasPort && uri.port != (uri.scheme == 'https' ? 443 : 80))) {
    throw const ToolboxException('请使用公开的网页链接');
  }
  final host = uri.host.toLowerCase().replaceAll(RegExp(r'\.$'), '');
  final address = InternetAddress.tryParse(host);
  if ((address == null && !host.contains('.')) ||
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal') ||
      (address != null && !toolboxPublicAddress(address))) {
    throw const ToolboxException('不支持本机或内网地址');
  }
  return uri.removeFragment();
}

bool toolboxPublicAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (bytes.length == 4) {
    return !(bytes[0] == 0 ||
        bytes[0] == 10 ||
        bytes[0] == 127 ||
        bytes[0] >= 224 ||
        (bytes[0] == 169 && bytes[1] == 254) ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127) ||
        (bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19)));
  }
  // 只接受全球单播 IPv6；拒绝映射 IPv4、链路本地、组播和未指定地址。
  return bytes[0] & 0xe0 == 0x20;
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
