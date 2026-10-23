import 'dart:typed_data';

// 常用功能的快捷入口（同支付宝长按图标的「付钱」、付款码页的「添加到桌面」）：长按应用图标的菜单与桌面上的快捷方式都由这一份生成，
// 点了直达对应页面。id 要稳定（桌面上的快捷方式会一直留着，按 id 找回页面）；icon 是自适应图标规格的 PNG（108dp 见方，内容在中间 72dp 的安全区里）。
class AppShortcut {
  const AppShortcut({required this.id, required this.label, required this.icon});
  final String id;
  final String label;
  final Uint8List icon;
}

// 快捷入口的系统端口，由 device 层实现、组合根注入。
abstract class AppShortcutPort {
  // 整份替换长按应用图标的菜单；同 id 的桌面快捷方式跟着换名字与图标。
  Future<void> publish(List<AppShortcut> shortcuts);
  // 请求把一个入口放到桌面，由桌面弹窗请用户确认；桌面不支持时返回 false。
  Future<bool> pin(AppShortcut shortcut);
  // 这次冷启动是从哪个入口打开的（只取一次，不是从入口打开的为空）。
  Future<String?> takeLaunch();
  // 应用在后台时点了入口：带回入口 id。
  Stream<String> get launches;
}
