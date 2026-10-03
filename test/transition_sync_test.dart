import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/theme/campus_theme.dart';
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
    final fading = tester.widgetList<FadeTransition>(
      find.ancestor(
        of: find.text('旧页面'),
        matching: find.byType(FadeTransition),
      ),
    );
    expect(
      fading.any((fade) => fade.opacity.value > 0 && fade.opacity.value < .5),
      isTrue,
    );
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
