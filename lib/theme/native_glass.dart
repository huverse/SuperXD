import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_symbols.dart';

// [人工决策-2026-10-26 21:47:04] iOS 上的液态玻璃全部换成苹果官方组件（用户选定「换成系统组件」，原生侧见 ios/Runner/NativeDialogs.swift 与 NativeGlassViews.swift）：
// 底栏是系统 UITabBar，⋯ 菜单是系统 UIMenu，确认与提示是系统弹窗；玻璃的清透或着色、降低透明度等都跟随系统设置，应用里不再有玻璃档位。
// 这一条取代 iOS 上的 10-02、10-14 玻璃档位与限档、09-27 与 09-29 底栏拖动、10-04 与 10-19 弹窗按钮排布（安卓照旧）。
// [人工决策-2026-10-27 00:26:51] 真机上平台视图里的系统玻璃取不到 Flutter 画出的背景、每帧多合成一层、转场时跟着挪位置掉帧，改为（用户选定「底栏真玻璃，其余自绘」）：
// 系统组件只留底栏（直接挂在 Flutter 视图上，见 NativeTabBar）与系统弹出的弹窗、菜单、日期选择、分享面板；
// 顶栏圆钮、弹窗与弹层的底、提示条由 Flutter 画磨砂（campus_glass_tier.dart 在 iOS 上固定磨砂档），开关、滑杆用 Flutter 的 iOS 样式控件（campus_glass_controls.dart）。
// 上一条里顶栏系统玻璃按钮、系统开关滑杆、垫系统玻璃的做法就此取消；iOS 上仍没有玻璃档位。
// 测试默认按安卓跑；要测 iOS 分支时设 debugDefaultTargetPlatformOverride。
bool get campusIos => defaultTargetPlatform == TargetPlatform.iOS;

const _nativeUi = MethodChannel('superxd/native_ui');

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

String _isoDay(DateTime day) => '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

// 系统日期选择：从底部弹出的系统面板里是系统日历（UIDatePicker 的 inline 样式），导航栏左边「取消」、右边 confirm。
// 只取年月日：按 timeZone（IANA 名）的公历换算，日历里标的「今天」也按它；返回选中那天（本地零点，同 Material 日期选择），取消为空。
Future<DateTime?> showNativeDatePicker({required String title, required String confirm, required DateTime initial, required DateTime first, required DateTime last, required String timeZone}) async {
  try {
    final picked = await _nativeUi.invokeMethod<String>('date', {
      'title': title,
      'confirm': confirm,
      'initial': _isoDay(initial),
      'first': _isoDay(first),
      'last': _isoDay(last),
      'timeZone': timeZone,
    });
    return picked == null ? null : DateTime.parse(picked);
  } catch (error, stack) {
    campusLog('[NativeUi] action=date errorType=${error.runtimeType}\n$stack');
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
    if (!campusIos) return;
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

// 低电量模式（iOS 的低电量模式、安卓的省电模式）：开着时装饰动效停下（见 campus_motion.dart 的 CampusMotion，同苹果建议低电量时减少动画）。
// 原生在开关时发 lowPower 过来；当前状态由组合根启动时经 watchNativeLowPower 要一次（测试里不向原生要）。
final ValueNotifier<bool> _lowPower = () {
  final lowPower = ValueNotifier(false);
  _nativeUi.setMethodCallHandler((call) async {
    if (call.method == 'lowPower') lowPower.value = call.arguments == true;
  });
  return lowPower;
}();

ValueListenable<bool> get nativeLowPower => _lowPower;

Future<void> watchNativeLowPower() async {
  try {
    _lowPower.value = await _nativeUi.invokeMethod<bool>('lowPower') == true;
  } catch (error, stack) {
    campusLog('[NativeUi] action=lowPower errorType=${error.runtimeType}\n$stack');
  }
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

// 系统底栏（[人工决策] 见文件头）：原生 UITabBar 直接挂在 Flutter 视图之上（ios/Runner/NativeGlassViews.swift），不是平台视图。
// 它总在 Flutter 内容之上，所以本组件逐帧把底栏该在的样子交给原生：
// - 壳页被推入的页面盖住时，按 iOS 推入的同一条曲线跟着左移三分之一，只露出新页面左边缘以左的部分（同系统推入时新页面盖住底栏）；
// - 壳页上面开着弹窗、弹层这类浮层，或开屏还没走完（revealed）时淡出；只有完全露出时才接点按。
// 本组件放在底栏壳的底部、高度同系统底栏：不画东西，只给读屏一排同样的按钮（系统底栏对读屏隐藏，免得读两遍）。
// 选中由 Dart 决定（点了先回 onSelected，切分支后 selected 跟着变）；onHeight 报系统排好的底栏总高（含底部安全区）。
class NativeTabBar extends StatefulWidget {
  const NativeTabBar({super.key, required this.items, required this.selected, required this.onSelected, required this.onHeight, this.tint, this.revealed});
  final List<NativeTabItem> items;
  final int selected;
  final ValueChanged<int> onSelected;
  final ValueChanged<double> onHeight;
  final Color? tint;
  final ValueListenable<bool>? revealed;

  // 推入页面时新页面与旧页面的曲线，同 Flutter 的 CupertinoPageTransition（campus_transitions.dart 的 iOS 转场也用这两个）。
  static CurvedAnimation enterCurve(Animation<double> parent) => CurvedAnimation(parent: parent, curve: Curves.fastEaseInToSlowEaseOut, reverseCurve: Curves.fastEaseInToSlowEaseOut.flipped);
  static CurvedAnimation leaveCurve(Animation<double> parent) => CurvedAnimation(parent: parent, curve: Curves.linearToEaseOut, reverseCurve: Curves.easeInToLinear);

  @override
  State<NativeTabBar> createState() => _NativeTabBarState();
}

class _NativeTabBarState extends State<NativeTabBar> {
  static const _channel = MethodChannel('superxd/tab_bar');
  // 同一时刻只有一个底栏壳拥有原生底栏：切换账号时新壳先建、旧壳后拆，旧壳不能把新壳的底栏收起。
  static _NativeTabBarState? _owner;
  ModalRoute<Object?>? _route;
  ValueListenable<bool>? _gesture;
  CurvedAnimation? _enter, _leave;
  bool _current = true;
  double _width = 0;
  String? _sentLook;
  Map<String, Object>? _sentGeometry;

  @override
  void initState() {
    super.initState();
    _owner = this;
    _channel.setMethodCallHandler((call) async {
      if (!mounted || _owner != this) return;
      if (call.method == 'select') widget.onSelected(call.arguments as int);
      if (call.method == 'height') widget.onHeight((call.arguments as num).toDouble());
    });
    widget.revealed?.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _width = MediaQuery.sizeOf(context).width;
    _current = ModalRoute.isCurrentOf(context) ?? true;
    final route = ModalRoute.of(context);
    if (route != _route) {
      _unbind();
      _route = route;
      final secondary = route?.secondaryAnimation;
      if (secondary != null) {
        secondary.addListener(_sync);
        secondary.addStatusListener(_status);
        _enter = NativeTabBar.enterCurve(secondary);
        _leave = NativeTabBar.leaveCurve(secondary);
      }
      _gesture = route?.navigator?.userGestureInProgressNotifier;
      _gesture?.addListener(_sync);
    }
    _show();
    _sync();
  }

  @override
  void didUpdateWidget(NativeTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revealed != widget.revealed) {
      oldWidget.revealed?.removeListener(_sync);
      widget.revealed?.addListener(_sync);
    }
    _show();
    _sync();
  }

  void _unbind() {
    _route?.secondaryAnimation?.removeListener(_sync);
    _route?.secondaryAnimation?.removeStatusListener(_status);
    _gesture?.removeListener(_sync);
    _enter?.dispose();
    _leave?.dispose();
    _enter = _leave = null;
  }

  @override
  void dispose() {
    _unbind();
    widget.revealed?.removeListener(_sync);
    if (_owner == this) {
      _owner = null;
      _channel.setMethodCallHandler(null);
      _invoke('hide');
    }
    super.dispose();
  }

  void _status(AnimationStatus _) => _sync();

  void _invoke(String method, [Object? arguments]) => _channel.invokeMethod<void>(method, arguments).catchError((Object error, StackTrace stack) {
    campusLog('[NativeTabBar] action=$method errorType=${error.runtimeType}\n$stack');
  });

  void _show() {
    if (_owner != this) return;
    final look = {
      'selected': widget.selected,
      'tint': widget.tint?.toARGB32(),
      'items': [
        for (final item in widget.items) {'title': item.title, 'symbol': campusSymbol(item.icon), 'selectedSymbol': campusSymbol(item.selectedIcon), 'badge': item.badge, 'dot': item.dot},
      ],
    };
    final encoded = jsonEncode(look);
    if (encoded == _sentLook) return;
    _sentLook = encoded;
    _invoke('show', look);
  }

  // 被推入的页面盖住时按推入的进度算位置（跟手返回时同页面一样按进度线性跟手）；盖在上面的不是页面（弹窗、弹层、浮层）时淡出。
  void _sync() {
    if (!mounted || _owner != this) return;
    final secondary = _route?.secondaryAnimation;
    final pushed = secondary != null && !secondary.isDismissed;
    final following = _gesture?.value ?? false;
    final enter = !pushed ? 0.0 : following ? secondary.value : _enter!.value;
    final leave = !pushed ? 0.0 : following ? secondary.value : _leave!.value;
    final visible = (widget.revealed?.value ?? true) && (_current || pushed);
    final geometry = <String, Object>{'shift': -_width * leave / 3, 'cover': _width * (1 - enter), 'visible': visible, 'interactive': !pushed && _current};
    if (mapEquals(geometry, _sentGeometry)) return;
    _sentGeometry = geometry;
    _invoke('geometry', geometry);
  }

  @override
  Widget build(BuildContext context) => Row(children: [
    for (final (index, item) in widget.items.indexed)
      Expanded(
        child: Semantics(
          button: true,
          selected: index == widget.selected,
          label: item.title,
          value: item.accessibilityValue,
          onTap: () => widget.onSelected(index),
          child: const SizedBox.expand(),
        ),
      ),
  ]);
}
