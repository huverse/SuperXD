import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/local/display_settings.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/native_glass.dart';

// iOS 上的玻璃换成系统组件（[人工决策] 见 lib/theme/native_glass.dart）：Dart 侧把对的东西交给原生；原生侧长什么样只能在 iPhone 上看。
final _ios = TargetPlatformVariant.only(TargetPlatform.iOS);
const _nativeUi = MethodChannel('superxd/native_ui');
const _codec = StandardMethodCodec();

void main() {
  final calls = <MethodCall>[];
  final views = <String, int>{};
  Object? reply;

  setUp(() {
    calls.clear();
    views.clear();
    reply = null;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_nativeUi, (call) async {
      calls.add(call);
      return reply;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      if (call.method == 'create') {
        final arguments = call.arguments as Map;
        views[arguments['viewType'] as String] = arguments['id'] as int;
      }
      return null;
    });
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_nativeUi, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  Future<BuildContext> pumpPage(WidgetTester tester, [Widget? child]) async {
    late BuildContext page;
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: Scaffold(body: Builder(builder: (context) {
      page = context;
      return child ?? const SizedBox.expand();
    }))));
    return page;
  }

  testWidgets('确认与提示是系统弹窗：取消在系统位置，破坏性的确认为警示红，点第二个才算确认', (tester) async {
    final page = await pumpPage(tester);
    reply = 1;
    expect(await showCampusConfirm(page, title: '删除这门课？', message: '可以在历史版本里恢复。', action: '删除', destructive: true), isTrue);
    expect(calls.single.method, 'alert');
    expect((calls.single.arguments as Map)['actions'], [
      {'title': '取消', 'style': 'cancel', 'preferred': false},
      {'title': '删除', 'style': 'destructive', 'preferred': false},
    ]);
    reply = 0;
    expect(await showCampusConfirm(page, title: '开始同步？', message: '同步所选学年。', action: '开始同步'), isFalse);
    expect(((calls.last.arguments as Map)['actions'] as List).last, {'title': '开始同步', 'style': 'default', 'preferred': true});
    await showCampusNotice(page, '已经是最新版本。');
    expect((calls.last.arguments as Map)['actions'], [{'title': '知道了', 'style': 'default', 'preferred': true}]);
    expect(find.byType(CampusGlassDialog), findsNothing);
  }, variant: _ios);

  testWidgets('⋯ 菜单是从按钮处弹出的系统菜单：图标换成 SF Symbols，选中项带勾，点空白为空', (tester) async {
    late BuildContext anchor;
    await pumpPage(tester, Center(child: Builder(builder: (context) {
      anchor = context;
      return const SizedBox(width: 44, height: 44);
    })));
    reply = 1;
    final picked = await showCampusMenu<String>(anchor, selected: 'b', items: const [
      CampusMenuItem(value: 'a', label: '编辑', icon: CampusIcons.edit),
      CampusMenuItem(value: 'b', label: '删除', icon: CampusIcons.delete, destructive: true),
    ]);
    expect(picked, 'b');
    final arguments = calls.single.arguments as Map;
    final rect = tester.getRect(find.byWidgetPredicate((widget) => widget is SizedBox && widget.width == 44));
    expect(arguments['rect'], [rect.left, rect.top, rect.width, rect.height]);
    expect(arguments['items'], [
      {'title': '编辑', 'symbol': 'pencil', 'destructive': false, 'checked': false},
      {'title': '删除', 'symbol': 'trash', 'destructive': true, 'checked': true},
    ]);
    reply = null;
    expect(await showCampusMenu<String>(anchor, items: const [CampusMenuItem(value: 'a', label: '编辑')]), isNull);
  }, variant: _ios);

  // [人工决策] 见 lib/theme/native_glass.dart 文件头（10-27）：除底栏外不再有平台视图，开关、滑杆用 Flutter 的 iOS 样式控件，顶栏圆钮与面板画磨砂。
  testWidgets('iOS 的开关、滑杆是 iOS 样式控件，顶栏圆钮画磨砂，一个平台视图也不建', (tester) async {
    var value = false;
    var pressed = 0;
    late CampusGlassTier tier;
    await pumpPage(tester, Column(children: [
      StatefulBuilder(builder: (context, setState) => CampusSwitchTile(title: const Text('课前提醒'), value: value, onChanged: (next) => setState(() => value = next))),
      CampusSlider(value: .3, label: '模糊', onChanged: (_) {}),
      CampusGlassCircleButton(label: '更多操作', onPressed: () => pressed++, icon: const CampusIcon(CampusIcons.manage)),
      Builder(builder: (context) {
        tier = CampusGlassScope.tierOf(context, ready: true);
        return const SizedBox();
      }),
    ]));
    await tester.pump();
    expect(views, isEmpty);
    expect(find.byType(CupertinoSwitch), findsOneWidget);
    expect(find.byType(CupertinoSlider), findsOneWidget);
    expect(tier, CampusGlassTier.minimal);
    await tester.tap(find.byType(ListTile));
    await tester.pump();
    expect(value, isTrue);
    await tester.tap(find.byTooltip('更多操作'));
    expect(pressed, 1);
    // 读屏：开关行整行报开关状态，开关本身不再单独成一个节点。
    expect(tester.getSemantics(find.byType(ListTile)), isSemantics(label: '课前提醒', hasToggledState: true, isToggled: true, hasTapAction: true));
  }, variant: _ios);

  // 系统底栏挂在 Flutter 视图上（不是平台视图）：Dart 逐帧交给原生的位置要同页面推入一致，浮层盖住或开屏没走完时收起。
  testWidgets('iOS 系统底栏：推入页面时跟着壳页左移、只露出新页面左边缘以左，浮层与开屏时收起，原生的选择与高度交回', (tester) async {
    final calls = <MethodCall>[];
    const tabBar = MethodChannel('superxd/tab_bar');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(tabBar, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(tabBar, null));
    Map<Object?, Object?> geometry() => calls.lastWhere((call) => call.method == 'geometry').arguments as Map;
    final navigator = GlobalKey<NavigatorState>();
    final revealed = ValueNotifier(false);
    addTearDown(revealed.dispose);
    var selected = 0;
    double? height;
    await tester.pumpWidget(MaterialApp(
      theme: campusTheme(),
      navigatorKey: navigator,
      home: Scaffold(body: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(height: 83, child: StatefulBuilder(builder: (context, setState) => NativeTabBar(
          selected: selected,
          revealed: revealed,
          items: const [
            NativeTabItem(title: '今天', icon: CampusIcons.today, selectedIcon: CampusIcons.todaySelected),
            NativeTabItem(title: '消息', icon: CampusIcons.messages, selectedIcon: CampusIcons.messagesSelected, badge: 3, accessibilityValue: '3 条未读'),
          ],
          onSelected: (index) => setState(() => selected = index),
          onHeight: (value) => height = value,
        ))),
      )),
    ));
    final width = tester.getSize(find.byType(MaterialApp)).width;
    final show = calls.firstWhere((call) => call.method == 'show').arguments as Map;
    expect(show['selected'], 0);
    expect((show['items'] as List).last, containsPair('badge', 3));
    expect(geometry(), {'shift': 0.0, 'cover': width, 'visible': false, 'interactive': true});
    revealed.value = true;
    await tester.pump();
    expect(geometry()['visible'], isTrue);
    // 原生点了第二项：Dart 切过去后把选中发回去。
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage('superxd/tab_bar', _codec.encodeMethodCall(const MethodCall('select', 1)), (_) {});
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage('superxd/tab_bar', _codec.encodeMethodCall(const MethodCall('height', 83.0)), (_) {});
    await tester.pump();
    expect(selected, 1);
    expect(height, 83);
    expect((calls.lastWhere((call) => call.method == 'show').arguments as Map)['selected'], 1);
    // 读屏读 Flutter 这一排按钮（系统底栏对读屏隐藏）。
    expect(tester.getSemantics(find.bySemanticsLabel('消息')), isSemantics(label: '消息', value: '3 条未读', isButton: true, isSelected: true, hasSelectedState: true, hasTapAction: true));
    // 推入页面：转场中跟着壳页左移，只露出新页面左边缘以左；停稳后整个被盖住。
    navigator.currentState!.push(CampusPageRoute<void>(builder: (context) => const SizedBox.expand(child: Text('新页面'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final moving = geometry();
    expect(moving['shift'] as double, inExclusiveRange(-width / 3, 0));
    expect(moving['cover'] as double, inExclusiveRange(0, width));
    expect(moving['cover'], closeTo(tester.getTopLeft(find.text('新页面')).dx, .5));
    expect(moving['interactive'], isFalse);
    await tester.pumpAndSettle();
    expect(geometry(), {'shift': -width / 3, 'cover': 0.0, 'visible': true, 'interactive': false});
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(geometry(), {'shift': 0.0, 'cover': width, 'visible': true, 'interactive': true});
    // 浮层（不是页面推入）盖住时收起。
    unawaited(showCampusDialog<void>(context: navigator.currentContext!, builder: (context) => const Text('弹窗')));
    await tester.pumpAndSettle();
    expect(geometry()['visible'], isFalse);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(geometry()['visible'], isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(calls.last.method, 'hide');
  }, variant: _ios);

  // [人工决策] 见 local/display_settings.dart 的 systemFont（10-27 起 iOS 默认改回 Maple）。
  test('系统字体：iOS 新装默认 Maple、可选系统字体，安卓没有这一项', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final settings = DisplaySettings.memory();
      expect(settings.fontId, 'maple');
      expect(DisplaySettings.knownFont(DisplaySettings.systemFont), isTrue);
      await settings.setFont(DisplaySettings.systemFont);
      expect(settings.fontFamily, isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    expect(DisplaySettings.memory().fontId, 'maple');
    expect(DisplaySettings.knownFont(DisplaySettings.systemFont), isFalse);
    expect(campusIos, isFalse);
  });
}
