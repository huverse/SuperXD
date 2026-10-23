import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/domain/app_shortcut.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/toolbox/toolbox_module.dart';

// 快捷入口的接线（人工决策见 toolbox/express/express_page.dart 的 _openIdentity）：百宝箱注册表里登记的入口（ToolboxShortcut）
// 画好图标交给系统（长按应用图标的菜单、添加到桌面）；点了入口要去的页面先记在 pending，由账号应用等会话恢复好再推入（openShortcut）。
// 入口 id 是「工具 id.入口 id」，页面是 /toolbox/工具 id/入口 id。
class AppShortcuts {
  AppShortcuts({required this.port, required this.tools, required this.pixelRatio});
  final AppShortcutPort port;
  final List<ToolboxModule> tools;
  final double pixelRatio;
  final pending = ValueNotifier<String?>(null);
  final _icons = <String, Uint8List>{};
  StreamSubscription<String>? _launches;

  Iterable<({String id, ToolboxShortcut shortcut, String location})> get _entries sync* {
    for (final tool in tools) {
      for (final shortcut in tool.shortcuts) {
        yield (id: '${tool.id}.${shortcut.id}', shortcut: shortcut, location: '/toolbox/${tool.id}/${shortcut.id}');
      }
    }
  }

  // 点了入口：记下要去的页面。认不出的 id（以后删掉了的入口还留在桌面上）照常打开应用。
  void open(String id) {
    final location = _entries.where((entry) => entry.id == id).firstOrNull?.location;
    if (location == null) {
      campusLog('[Shortcuts] action=launch errorType=unknown_shortcut');
      return;
    }
    pending.value = location;
  }

  // 发布到长按应用图标的菜单，并接住应用在后台时点的入口；图标由组合根在首帧之后再画，不和启动抢主线程。
  Future<void> start() async {
    _launches ??= port.launches.listen(open);
    await port.publish([for (final entry in _entries) await _shortcut(entry)]);
  }

  // 把工具的一个入口放到桌面：桌面弹窗请用户确认，不支持时返回 false。
  Future<bool> pin(String toolId, String shortcutId) async {
    final entry = _entries.where((entry) => entry.id == '$toolId.$shortcutId').first;
    return port.pin(await _shortcut(entry));
  }

  Future<AppShortcut> _shortcut(({String id, ToolboxShortcut shortcut, String location}) entry) async =>
      AppShortcut(id: entry.id, label: entry.shortcut.label, icon: _icons[entry.id] ??= await shortcutIcon(entry.shortcut.icon, pixelRatio));

  void dispose() {
    _launches?.cancel();
    pending.dispose();
  }
}

// 快捷入口的图标：自适应图标的规格（108dp 见方，内容在中间 72dp 的安全区里），默认配色的浅底上画激活色的图标（同启动窗口底色），
// 桌面再按自己的形状裁切。
Future<Uint8List> shortcutIcon(IconData icon, double pixelRatio) async {
  final palette = CampusPalette.byId(DisplaySettings.defaultPaletteId);
  final side = (108 * pixelRatio).round();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..drawColor(palette.backgroundTop, BlendMode.src);
  final glyph = TextPainter(
    text: TextSpan(text: String.fromCharCode(icon.codePoint), style: TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: 46 * pixelRatio, color: palette.accent)),
    textDirection: TextDirection.ltr,
  )..layout();
  glyph.paint(canvas, Offset((side - glyph.width) / 2, (side - glyph.height) / 2));
  glyph.dispose();
  final image = await recorder.endRecording().toImage(side, side);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

// 账号应用里推入快捷入口要去的页面：等会话恢复好（离开启动页）、先回到首页（今天或登录页，返回就回到那里，也不和已经开着的同一个工具叠两份），
// 再推入；已经停在首页才推，所以路由每次变化都要再调一次。
void openShortcut(GoRouter router, ValueNotifier<String?> pending, {required String home}) {
  final location = pending.value;
  final path = router.routerDelegate.currentConfiguration.uri.path;
  if (location == null || path == '/boot' || path.isEmpty) return;
  if (path != home) {
    router.go(home);
    return;
  }
  pending.value = null;
  router.push(location);
}
