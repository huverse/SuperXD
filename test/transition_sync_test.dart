import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/page/date_rail.dart';

void main() {
  testWidgets('模糊遮罩弹窗共享进度，正反向都无骤变且可点击遮罩取消', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(children: [
              TextButton(
                onPressed: () => showCampusDialog<void>(
                  context: context,
                  builder: (context) => const CampusGlassDialog(content: Text('旧库提示')),
                ),
                child: const Text('打开'),
              ),
              TextButton(
                onPressed: () => showCampusDialog<void>(
                  context: context,
                  glassPanel: false,
                  builder: (context) => const AlertDialog(content: Text('选择开学日')),
                ),
                child: const Text('日期'),
              ),
            ]),
          ),
        ),
      ),
    );
    // 面板显隐与模糊取同一条路由进度：玻璃面板由面板自己淡入（此处玻璃未就绪，走实色淡入），系统弹窗整体改不透明度。
    Future<void> expectShared(String text, double Function() panelOpacity) async {
      final route = ModalRoute.of(tester.element(find.text(text)))!;
      expect(route.animation!.value, 0);
      for (final elapsed in [75, 75, 75]) {
        await tester.pump(Duration(milliseconds: elapsed));
        final t = Curves.easeInOutCubic.transform(route.animation!.value);
        final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
        expect(filter.filter, ui.ImageFilter.blur(sigmaX: 5 * t, sigmaY: 5 * t));
        expect(panelOpacity(), closeTo(t, .0001));
      }
    }
    await tester.tap(find.text('日期'));
    await tester.pump();
    await expectShared('选择开学日', () => tester.widgetList<Opacity>(find.ancestor(of: find.text('选择开学日'), matching: find.byType(Opacity))).first.opacity);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开'));
    await tester.pump();
    final route = ModalRoute.of(tester.element(find.text('旧库提示')))!;
    await expectShared('旧库提示', () => tester.widgetList<FadeTransition>(find.ancestor(of: find.text('旧库提示'), matching: find.byType(FadeTransition))).first.opacity.value);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(route.animation!.value, lessThan(1));
    expect(route.animation!.value, greaterThan(0));
    await tester.pumpAndSettle();
    expect(find.text('旧库提示'), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
  });
  testWidgets('旧页在新页面超过半程时仍连续退场而非提前清空', (tester) async {
    final first = AnimationController(vsync: tester, value: 1),
        next = AnimationController(vsync: tester, value: .6);
    addTearDown(first.dispose);
    addTearDown(next.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) =>
              campusPageTransition(context, first, next, const Text('旧页面')),
        ),
      ),
    );
    // 旧页随新页同一进度整屏推出，仍在屏内，且不靠淡出（玻璃在半透明图层下取不到背景）。
    final width = tester.getSize(find.byType(MaterialApp)).width;
    final left = tester.getTopLeft(find.text('旧页面')).dx;
    expect(left, closeTo(-width * campusSpringCurve.transform(.6), .5));
    expectUnfaded(find.text('旧页面'));
  });
  testWidgets('页面推入与返回：新旧页整屏并排平移不重叠，全程不淡入淡出', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      theme: campusTheme(),
      navigatorKey: navigator,
      home: const SizedBox.expand(child: Text('旧页面')),
    ));
    final width = tester.getSize(find.byType(MaterialApp)).width;
    navigator.currentState!.push(MaterialPageRoute<void>(builder: (context) => const SizedBox.expand(child: Text('新页面'))));
    await tester.pump();
    for (final elapsed in [90, 90, 90]) {
      await tester.pump(Duration(milliseconds: elapsed));
      final previous = tester.getTopLeft(find.text('旧页面')).dx, next = tester.getTopLeft(find.text('新页面')).dx;
      expect(previous, lessThan(0));
      expect(next, closeTo(previous + width, .5));
      expectUnfaded(find.text('旧页面'));
      expectUnfaded(find.text('新页面'));
    }
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final previous = tester.getTopLeft(find.text('旧页面')).dx, next = tester.getTopLeft(find.text('新页面')).dx;
    expect(next, inExclusiveRange(0, width));
    expect(next, closeTo(previous + width, .5));
    expectUnfaded(find.text('新页面'));
    await tester.pumpAndSettle();
    expect(find.text('新页面'), findsNothing);
  });
  testWidgets('日期与星期同显，周日跨年正确且文学字体大字不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(fontFamily: 'Noto Serif SC'),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: DateRail(
                first: '2026-12-28',
                last: '2027-01-04',
                selected: '2027-01-03',
                onSelect: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1/3').hitTestable(), findsOneWidget);
    expect(find.text('周日').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

// 玻璃在半透明 Opacity、FadeTransition 下取不到背景，转场期间内容之上不得有它们。
void expectUnfaded(Finder finder) {
  finder.evaluate().single.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is Opacity) expect(widget.opacity, 1);
    if (widget is FadeTransition) expect(widget.opacity.value, 1);
    return true;
  });
}
