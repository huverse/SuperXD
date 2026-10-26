import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_symbols.dart';

// [人工决策-2026-10-26 21:47:04] iOS 上的液态玻璃全部换成苹果官方组件（用户选定「换成系统组件」，原生侧见 ios/Runner/NativeDialogs.swift 与 NativeGlassViews.swift）：
// 底栏是系统 UITabBar，顶栏圆钮是系统玻璃按钮，⋯ 菜单是系统 UIMenu，确认与提示是系统弹窗，开关、滑杆是系统控件，
// 自定义内容的弹窗、弹层与提示条垫系统玻璃（UIGlassEffect）；玻璃的清透或着色、降低透明度等都跟随系统设置，应用里不再有玻璃档位。
// 这一条取代 iOS 上的 10-02、10-14 玻璃档位与限档、09-27 与 09-29 底栏拖动、10-04 与 10-19 弹窗按钮排布（安卓照旧）。
// 测试默认按安卓跑；要测 iOS 分支时设 debugDefaultTargetPlatformOverride。
bool get campusNativeGlass => defaultTargetPlatform == TargetPlatform.iOS;

const _nativeUi = MethodChannel('superxd/native_ui');

int? _argb(Color? color) => color?.toARGB32();

// 系统弹窗的一个按钮：cancel 是取消（系统放在固定位置），destructive 是警示红，preferred 是主操作（加粗）。
class NativeAlertAction {
  const NativeAlertAction(this.title, {this.cancel = false, this.destructive = false, this.preferred = false});
  final String title;
  final bool cancel;
  final bool destructive;
  final bool preferred;
}

// 弹系统弹窗，返回点的是第几个按钮；系统弹窗点空白关不掉，只能点按钮。
Future<int?> showNativeAlert({String? title, String? message, required List<NativeAlertAction> actions}) async {
  try {
    return await _nativeUi.invokeMethod<int>('alert', {
      'title': title,
      'message': message,
      'actions': [
        for (final action in actions) {'title': action.title, 'style': action.cancel ? 'cancel' : action.destructive ? 'destructive' : 'default', 'preferred': action.preferred},
      ],
    });
  } catch (error, stack) {
    campusLog('[NativeUi] action=alert errorType=${error.runtimeType}\n$stack');
    return null;
  }
}

// 系统菜单的一项。
class NativeMenuEntry {
  const NativeMenuEntry(this.title, {this.icon, this.destructive = false, this.checked = false});
  final String title;
  final IconData? icon;
  final bool destructive;
  final bool checked;
}

// 从 rect（全局逻辑坐标）处弹系统菜单，返回点的是第几项，点空白关掉为空。
Future<int?> showNativeMenu(Rect rect, List<NativeMenuEntry> entries) async {
  try {
    return await _nativeUi.invokeMethod<int>('menu', {
      'rect': [rect.left, rect.top, rect.width, rect.height],
      'items': [
        for (final entry in entries) {'title': entry.title, 'symbol': campusSymbol(entry.icon), 'destructive': entry.destructive, 'checked': entry.checked},
      ],
    });
  } catch (error, stack) {
    campusLog('[NativeUi] action=menu errorType=${error.runtimeType}\n$stack');
    return null;
  }
}

// 让系统组件（弹窗、菜单、玻璃、分享面板）跟应用的深浅色与控件激活色走，而不是跟系统：应用可以固定浅色或深色。
// 组合根套在 MaterialApp.builder 里，配色或深浅色一变就同步一次。
class NativeAppearanceSync extends StatefulWidget {
  const NativeAppearanceSync({super.key, required this.child});
  final Widget child;

  @override
  State<NativeAppearanceSync> createState() => _NativeAppearanceSyncState();
}

class _NativeAppearanceSyncState extends State<NativeAppearanceSync> {
  (bool, int)? _sent;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!campusNativeGlass) return;
    final palette = CampusPalette.of(context);
    final look = (palette.isDark, palette.accent.toARGB32());
    if (look == _sent) return;
    _sent = look;
    _nativeUi.invokeMethod<void>('appearance', {'dark': look.$1, 'tint': look.$2}).catchError((Object error, StackTrace stack) {
      campusLog('[NativeUi] action=appearance errorType=${error.runtimeType}\n$stack');
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// 一个系统组件平台视图：参数变了就经视图自己的通道 update；原生发回的调用交给 onCall。
// interactive 为真时点按交给原生（按钮、开关、底栏），否则透明命中，点按落到上面的 Flutter 内容。
class _NativeView extends StatefulWidget {
  const _NativeView({required this.kind, required this.params, this.onCall, this.interactive = false});
  final String kind;
  final Map<String, Object?> params;
  final ValueChanged<MethodCall>? onCall;
  final bool interactive;

  @override
  State<_NativeView> createState() => _NativeViewState();
}

class _NativeViewState extends State<_NativeView> {
  MethodChannel? _channel;
  // 原生侧现在用的参数（建视图时带过去的那份，之后是最近一次 update 的）。
  late String _applied;

  @override
  void initState() {
    super.initState();
    _applied = jsonEncode(widget.params);
  }

  void _sync() {
    final channel = _channel;
    final params = jsonEncode(widget.params);
    if (channel == null || params == _applied) return;
    _applied = params;
    channel.invokeMethod<void>('update', widget.params).catchError((Object error, StackTrace stack) {
      campusLog('[NativeUi] action=update kind=${widget.kind} errorType=${error.runtimeType}\n$stack');
    });
  }

  @override
  void didUpdateWidget(_NativeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UiKitView(
    viewType: 'superxd/${widget.kind}',
    creationParams: widget.params,
    creationParamsCodec: const StandardMessageCodec(),
    hitTestBehavior: widget.interactive ? PlatformViewHitTestBehavior.opaque : PlatformViewHitTestBehavior.transparent,
    gestureRecognizers: widget.interactive ? {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)} : const {},
    onPlatformViewCreated: (id) {
      _channel = MethodChannel('superxd/${widget.kind}/$id')
        ..setMethodCallHandler((call) async {
          if (mounted) widget.onCall?.call(call);
        });
      _sync();
    },
  );
}

// 系统玻璃底，垫在 Flutter 内容下面；radius 大于等于 1000 是胶囊，tint 是着色（强调按钮）。不接点按。
class NativeGlassBackground extends StatelessWidget {
  const NativeGlassBackground({super.key, required this.radius, this.tint});
  final double radius;
  final Color? tint;

  @override
  Widget build(BuildContext context) => _NativeView(kind: 'glass_view', params: {'radius': radius, 'tint': _argb(tint)});
}

// 系统圆形玻璃按钮（顶栏操作、悬浮按钮）：SF Symbols 图标，按下有系统的玻璃形变；onPressed 为空时禁用。读屏标签是 label。
class NativeGlassButton extends StatelessWidget {
  const NativeGlassButton({super.key, required this.icon, required this.label, required this.onPressed, this.size = 52, this.prominent = false, this.tint});
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final double size;
  final bool prominent;
  final Color? tint;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: _NativeView(
      kind: 'glass_button',
      interactive: true,
      params: {'symbol': campusSymbol(icon), 'label': label, 'enabled': onPressed != null, 'prominent': prominent, 'tint': _argb(tint), 'iconSize': size * .36},
      onCall: (call) {
        if (call.method == 'tap') onPressed?.call();
      },
    ),
  );
}

// 系统开关，大小由系统定（51 × 31）。
class NativeSwitch extends StatelessWidget {
  const NativeSwitch({super.key, required this.value, required this.onChanged, this.label, this.tint});
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;
  final Color? tint;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 51,
    height: 31,
    child: _NativeView(
      kind: 'switch',
      interactive: true,
      params: {'value': value, 'enabled': onChanged != null, 'label': label, 'tint': _argb(tint)},
      onCall: (call) {
        if (call.method == 'changed') onChanged?.call(call.arguments as bool);
      },
    ),
  );
}

// 系统滑杆，值域 0–1：拖动中连续 onChanged，松手与系统取消都 onChangeEnd。
class NativeSlider extends StatelessWidget {
  const NativeSlider({super.key, required this.value, required this.onChanged, this.onChangeEnd, this.label, this.tint});
  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final String? label;
  final Color? tint;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: _NativeView(
      kind: 'slider',
      interactive: true,
      params: {'value': value, 'enabled': onChanged != null, 'label': label, 'tint': _argb(tint)},
      onCall: (call) {
        final value = (call.arguments as num).toDouble();
        if (call.method == 'changed') onChanged?.call(value);
        if (call.method == 'ended') onChangeEnd?.call(value);
      },
    ),
  );
}

// 系统底栏的一项。
class NativeTabItem {
  const NativeTabItem({required this.title, required this.icon, required this.selectedIcon, this.badge = 0, this.dot = false, this.accessibilityValue});
  final String title;
  final IconData icon;
  final IconData selectedIcon;
  final int badge;
  final bool dot;
  final String? accessibilityValue;
}

// 系统底栏：选中由 Dart 决定（点了先回 onSelected，Dart 切分支后 selected 跟着变）；onHeight 报系统给的底栏高度。
class NativeTabBar extends StatelessWidget {
  const NativeTabBar({super.key, required this.items, required this.selected, required this.onSelected, required this.onHeight, this.tint});
  final List<NativeTabItem> items;
  final int selected;
  final ValueChanged<int> onSelected;
  final ValueChanged<double> onHeight;
  final Color? tint;

  @override
  Widget build(BuildContext context) => _NativeView(
    kind: 'tab_bar',
    interactive: true,
    params: {
      'selected': selected,
      'tint': _argb(tint),
      'items': [
        for (final item in items)
          {'title': item.title, 'symbol': campusSymbol(item.icon), 'selectedSymbol': campusSymbol(item.selectedIcon), 'badge': item.badge, 'dot': item.dot, 'accessibilityValue': item.accessibilityValue},
      ],
    },
    onCall: (call) {
      if (call.method == 'select') onSelected(call.arguments as int);
      if (call.method == 'height') onHeight((call.arguments as num).toDouble());
    },
  );
}
