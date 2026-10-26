import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/local/display_settings.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
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

  // 模拟原生视图发回一次调用（点按、拨动开关）。
  Future<void> nativeSends(WidgetTester tester, String kind, String method, [Object? arguments]) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage('superxd/$kind/${views['superxd/$kind']}', _codec.encodeMethodCall(MethodCall(method, arguments)), (_) {});
    await tester.pump();
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

  testWidgets('开关、滑杆与顶栏圆钮是系统组件，原生的拨动与点按交回 Dart', (tester) async {
    var value = false;
    var pressed = 0;
    double? ended;
    await pumpPage(tester, Column(children: [
      StatefulBuilder(builder: (context, setState) => CampusSwitchTile(title: const Text('课前提醒'), value: value, onChanged: (next) => setState(() => value = next))),
      CampusSlider(value: .3, label: '模糊', onChanged: (_) {}, onChangeEnd: (next) => ended = next),
      CampusGlassCircleButton(label: '更多操作', onPressed: () => pressed++, icon: const CampusIcon(CampusIcons.manage)),
    ]));
    await tester.pump();
    expect(views.keys, containsAll(['superxd/switch', 'superxd/slider', 'superxd/glass_button']));
    await nativeSends(tester, 'switch', 'changed', true);
    expect(value, isTrue);
    await nativeSends(tester, 'slider', 'ended', .6);
    expect(ended, .6);
    await nativeSends(tester, 'glass_button', 'tap');
    expect(pressed, 1);
    // 读屏：开关行整行报开关状态，原生开关本身不再单独成一个节点。
    expect(tester.getSemantics(find.byType(ListTile)), isSemantics(label: '课前提醒', hasToggledState: true, isToggled: true, hasTapAction: true));
  }, variant: _ios);

  test('系统字体：iOS 新装默认系统字体、可选，安卓没有这一项', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final settings = DisplaySettings.memory();
      expect(settings.fontId, DisplaySettings.systemFont);
      expect(settings.fontFamily, isNull);
      expect(DisplaySettings.knownFont(DisplaySettings.systemFont), isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    expect(DisplaySettings.memory().fontId, 'maple');
    expect(DisplaySettings.knownFont(DisplaySettings.systemFont), isFalse);
    expect(campusNativeGlass, isFalse);
  });
}
