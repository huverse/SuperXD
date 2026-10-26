import 'dart:async';

import 'package:flutter/services.dart';

import 'package:superxd/domain/app_shortcut.dart';

// 快捷入口的系统实现：经通道 superxd/app_shortcuts 交给原生 AppShortcuts.kt（ShortcutManager 的动态快捷方式与桌面快捷方式）。
// 应用在后台时点了入口，原生侧调 launch 带回入口 id。
class ChannelAppShortcuts implements AppShortcutPort {
  ChannelAppShortcuts() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'launch') _launches.add(call.arguments as String);
    });
  }

  static const _channel = MethodChannel('superxd/app_shortcuts');
  final _launches = StreamController<String>.broadcast();

  Map<String, Object> _encode(AppShortcut shortcut) => {'id': shortcut.id, 'label': shortcut.label, 'icon': shortcut.icon};

  @override
  Future<void> publish(List<AppShortcut> shortcuts) => _channel.invokeMethod<void>('publish', {'shortcuts': [for (final shortcut in shortcuts) _encode(shortcut)]});

  @override
  Future<bool> pin(AppShortcut shortcut) async => await _channel.invokeMethod<bool>('pin', _encode(shortcut)) ?? false;

  @override
  Future<String?> takeLaunch() => _channel.invokeMethod<String>('takeLaunch');

  @override
  Stream<String> get launches => _launches.stream;
}
