import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;

import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_glass_press.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/theme/campus_transitions.dart';

void main() {
  tearDown(() => campusGlassReady.value = false);
  test('强调按钮：五套配色深浅两色白字对强调色与警示红实底不低于4.5:1', () {
    double contrast(Color color) => 1.05 / (color.computeLuminance() + .05);
    for (final palette in [...CampusPalette.values, ...CampusPalette.darkValues]) {
      expect(contrast(palette.accent), greaterThanOrEqualTo(4.5), reason: '${palette.id} ${palette.isDark}');
      expect(contrast(palette.dangerFill), greaterThanOrEqualTo(4.5), reason: '${palette.id} ${palette.isDark}');
    }
  });

  testWidgets('按钮层级：强调为实底白字、文字按钮为中性胶囊、链接不画胶囊，文字跟随应用字体', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: campusTheme(fontFamily: 'Noto Serif SC'), home: Scaffold(body: Column(children: [
      FilledButton(style: campusProminent, onPressed: () {}, child: const Text('解析')),
      FilledButton(style: campusProminent, onPressed: null, child: const Text('禁用强调')),
      TextButton(onPressed: () {}, child: const Text('重试')),
      TextButton(style: campusLink, onPressed: () {}, child: const Text('隐私政策')),
    ]))));
    final palette = CampusPalette.values.first;
    Color fill(String label) => (tester.widget<AnimatedContainer>(find.descendant(of: find.ancestor(of: find.text(label), matching: find.byType(FilledButton)), matching: find.byType(AnimatedContainer))).decoration! as ShapeDecoration).color!;
    expect(fill('解析'), palette.accent);
    expect(fill('禁用强调'), palette.accent.withValues(alpha: .4));
    Color text(String label) => tester.widget<RichText>(find.descendant(of: find.text(label), matching: find.byType(RichText))).text.style!.color!;
    expect(text('解析'), Colors.white);
    expect(find.descendant(of: find.widgetWithText(TextButton, '重试'), matching: find.byType(CampusTonalSurface)), findsOneWidget);
    expect(find.descendant(of: find.widgetWithText(TextButton, '隐私政策'), matching: find.byType(CampusGlassButtonSurface)), findsNothing);
    for (final label in ['解析', '重试']) {
      expect(tester.widget<RichText>(find.descendant(of: find.text(label), matching: find.byType(RichText))).text.style!.fontFamily, 'Noto Serif SC', reason: label);
    }
  });

  testWidgets('弹窗操作：两个等宽并排、主操作为强调色，破坏性为警示红；三个竖排且主操作在最上', (tester) async {
    late BuildContext page;
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: Scaffold(body: Builder(builder: (context) {
      page = context;
      return const SizedBox.expand();
    }))));
    final palette = CampusPalette.values.first;
    Color tint(String label) => tester.widget<CampusGlassButtonSurface>(find.descendant(of: find.widgetWithText(FilledButton, label), matching: find.byType(CampusGlassButtonSurface))).tint!;
    final confirm = showCampusConfirm(page, title: '开始同步？', message: '同步所选学年。', action: '开始同步');
    await tester.pumpAndSettle();
    final cancel = tester.getRect(find.widgetWithText(TextButton, '取消')), start = tester.getRect(find.widgetWithText(FilledButton, '开始同步'));
    expect(cancel.width, closeTo(start.width, .5));
    expect(cancel.center.dy, closeTo(start.center.dy, .5));
    expect(cancel.right, lessThan(start.left));
    expect(tint('开始同步'), palette.accent);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await confirm, isFalse);
    final remove = showCampusConfirm(page, title: '删除记录？', message: '只移除记录。', action: '删除', destructive: true);
    await tester.pumpAndSettle();
    expect(tint('删除'), palette.dangerFill);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await remove, isFalse);
    showCampusDialog<void>(context: page, builder: (context) => CampusGlassDialog(title: const Text('作息'), actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('暂不采用')),
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('看下一套')),
      FilledButton(onPressed: () => Navigator.pop(context), child: const Text('用这套')),
    ]));
    await tester.pumpAndSettle();
    final top = tester.getRect(find.widgetWithText(FilledButton, '用这套')), bottom = tester.getRect(find.widgetWithText(TextButton, '暂不采用'));
    expect(top.top, lessThan(bottom.top));
    expect(top.width, closeTo(bottom.width, .5));
    await tester.tap(find.text('暂不采用'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('全局主按钮保留原生点击禁用和键盘焦点，图文组合几何居中', (tester) async {
    var clicks = 0;
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: Scaffold(body: Center(child: FilledButton.icon(
      focusNode: focus, onPressed: () => clicks++, icon: const Icon(Icons.sync, key: ValueKey('icon')), label: const Text('同步', key: ValueKey('label')),
    )))));
    final button = find.byType(FilledButton);
    expect(find.byType(CampusGlassButtonSurface), findsOneWidget);
    final icon = tester.getRect(find.byKey(const ValueKey('icon'))), text = tester.getRect(find.byKey(const ValueKey('label')));
    final rect = tester.getRect(button);
    expect((icon.left + text.right) / 2, closeTo(rect.center.dx, .01));
    expect(icon.center.dy, closeTo(rect.center.dy, .01));
    expect(text.center.dy, closeTo(rect.center.dy, .01));
    await tester.tap(button); expect(clicks, 1);
    focus.requestFocus(); await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); await tester.pump(); expect(clicks, 2);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: Scaffold(body: FilledButton(onPressed: null, child: const Text('不可用')))));
    await tester.tap(find.text('不可用')); expect(clicks, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导航层玻璃胶囊更紧凑但48dp触区不缩小，按下连续鼓起、松手过冲回位，减少动画不形变', (tester) async {
    var clicks = 0;
    Future<void> mount(MediaQueryData media) => tester.pumpWidget(MaterialApp(theme: campusTheme(), home: MediaQuery(data: media, child: Scaffold(body: CampusChrome(child: Center(child: FilledButton(onPressed: () => clicks++, child: const Text('开始同步'))))))));
    await mount(const MediaQueryData());
    final button = find.byType(FilledButton);
    final surface = find.byType(CampusGlassButtonSurface);
    double scale() => tester.widget<Transform>(find.descendant(of: surface, matching: find.byType(Transform)).first).transform.entry(0, 0);
    expect(tester.getSize(surface).height, inInclusiveRange(36, 40));
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    final rect = tester.getRect(button);
    await tester.tapAt(Offset(rect.center.dx, rect.top + 1)); await tester.pumpAndSettle(); expect(clicks, 1);
    final gesture = await tester.startGesture(rect.center);await tester.pump(const Duration(milliseconds: 110));await tester.pump(const Duration(milliseconds: 16));
    final early = scale();
    await tester.pump(const Duration(milliseconds: 80));
    final pressed = scale();
    expect(early, inExclusiveRange(1, pressed));
    expect(pressed, inInclusiveRange(1.03, 1 + campusGlassSwell + .001));
    await gesture.up();
    var lowest = pressed;
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      lowest = math.min(lowest, scale());
    }
    expect(lowest, lessThan(1));
    await tester.pumpAndSettle();expect(scale(), closeTo(1, .0001));expect(clicks,2);
    await mount(const MediaQueryData(disableAnimations: true));
    final reduced = await tester.startGesture(tester.getCenter(button));await tester.pump(const Duration(milliseconds: 200));
    expect(scale(), 1);
    await reduced.up();await tester.pumpAndSettle();expect(clicks,3);
    expect(tester.takeException(),isNull);
  });

  testWidgets('等待按钮空闲文字居中，加载前后容器宽度稳定', (tester) async {
    var busy = false;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: Scaffold(body: Center(child: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return FilledButton(onPressed: () {}, child: CampusBusyContent(busy: busy, label: '登录', busyLabel: '正在登录'));
    })))));
    final button = find.byType(FilledButton);
    final width = tester.getSize(button).width;
    expect(tester.getCenter(find.text('登录')).dx, closeTo(tester.getCenter(button).dx, .01));
    update(() => busy = true);
    await tester.pump();
    expect(tester.getSize(button).width, width);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('内容区按钮与标签为不透明色调胶囊不取背景；导航层与玻璃面板里仍是玻璃', (tester) async {
    campusGlassReady.value = true;
    final palette = CampusPalette.values.first;
    Widget content() => Column(mainAxisSize: MainAxisSize.min, children: [
      FilledButton(onPressed: () {}, child: const Text('保存课程')),
      CampusGlassChip(label: '未选', selected: false, onSelected: (_) {}),
      CampusGlassChip(label: '已选', selected: true, onSelected: (_) {}),
    ]);
    Widget host(Widget child) => MaterialApp(theme: campusTheme(palette: palette), home: CampusGlassScope(mode: CampusGlassMode.full, capped: false, child: Scaffold(body: Center(child: child))));
    await tester.pumpWidget(host(content()));
    await tester.pumpAndSettle();
    expect(find.byType(liquid.AdaptiveGlass), findsNothing);
    expect(find.byType(CampusTonalSurface), findsNWidgets(3));
    Color fill(String text) => (tester.widget<AnimatedContainer>(find.descendant(of: find.ancestor(of: find.text(text), matching: find.byType(FilledButton)), matching: find.byType(AnimatedContainer))).decoration! as ShapeDecoration).color!;
    // 操作按钮着主色浅底；标签未选为中性浅底、选中为 surfaceSelected，三者一眼可分。
    expect(fill('保存课程'), palette.primary.withValues(alpha: .08));
    expect(fill('未选'), palette.onSurface.withValues(alpha: .07));
    expect(fill('已选'), palette.surfaceSelected);
    // 按下轻缩到 97%，不鼓起。
    final gesture = await tester.startGesture(tester.getCenter(find.text('保存课程')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<AnimatedScale>(find.descendant(of: find.ancestor(of: find.text('保存课程'), matching: find.byType(FilledButton)), matching: find.byType(AnimatedScale))).scale, .97);
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(CampusChrome(child: content())));
    await tester.pumpAndSettle();
    expect(find.byType(CampusTonalSurface), findsNothing);
    expect(find.byType(liquid.AdaptiveGlass), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('按压反馈同 iOS：卡片按下整块变暗、无扩散水波，松手淡出', (tester) async {
    for (final palette in [CampusPalette.values.first, CampusPalette.darkValues.first]) {
      await tester.pumpWidget(MaterialApp(theme: campusTheme(palette: palette), home: Scaffold(body: Center(child: CampusSurface(onTap: () {}, child: const Text('界面'))))));
      final gesture = await tester.startGesture(tester.getCenter(find.text('界面')));
      await tester.pump(const Duration(milliseconds: 300));
      final features = (Material.of(tester.element(find.text('界面'))) as dynamic).debugInkFeatures as List<InkFeature>;
      expect(features.whereType<InkHighlight>().single.color, palette.onSurface.withValues(alpha: palette.isDark ? .12 : .10));
      expect(features.where((feature) => feature is InkSplash || feature is InkRipple || feature is InkSparkle), isEmpty);
      await gesture.up();
      await tester.pumpAndSettle();
      expect((Material.of(tester.element(find.text('界面'))) as dynamic).debugInkFeatures as List<InkFeature>?, anyOf(isNull, isEmpty));
    }
  });

  testWidgets('父玻璃内按钮复用vibrancy，不添加第二个背景采样', (tester) async {
    campusGlassReady.value = true;
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: Scaffold(body: GlassPanelScope(opaque: false, child: Center(child: FilledButton(onPressed: () {}, child: const Text('同步')))))));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(liquid.AdaptiveGlass), findsNothing);
    expect(find.byType(CampusGlassButtonSurface), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('五主题长文大字号及无障碍不溢出，圆按钮等宽高且可读屏', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final palette in CampusPalette.values) {
      await tester.pumpWidget(MaterialApp(theme: campusTheme(palette: palette), home: MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(1.4), highContrast: true), child: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
        FilledButton(onPressed: () {}, child: const Text('确认属于我并导入')),
        CampusGlassCircleButton(icon: const CampusIcon(CampusIcons.arrowUp), label: '回今天', onPressed: () {}),
      ]))))));
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      final circle = tester.getSize(find.byType(CampusGlassCircleButton));
      expect(circle.width, circle.height);
      expect(circle.width, greaterThanOrEqualTo(48));
      expect(find.text('回今天'), findsNothing);
      final semantics = tester.ensureSemantics();
      // 只读一遍：标签落在可点的按钮节点上；提示框不得在外层另生成带同名 tooltip 的节点（安卓会把它当成第二个同名元素）。
      expect(find.bySemanticsLabel('回今天'), findsOneWidget);
      final node = tester.getSemantics(find.bySemanticsLabel('回今天'));
      expect(node, isSemantics(label: '回今天', isButton: true, hasTapAction: true));
      for (var ancestor = node.parent; ancestor != null; ancestor = ancestor.parent) {
        expect(ancestor.getSemanticsData().tooltip, isNot('回今天'));
      }
      semantics.dispose();
      expect(tester.takeException(), isNull, reason: palette.id);
    }
  });
}
