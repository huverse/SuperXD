import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphnext/morphnext.dart';

import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/curve_geometry.dart';

Widget host(Widget child, {bool reduced = false, bool ticker = true}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: CampusMotion(
          child: TickerMode(
            enabled: ticker,
            child: Scaffold(body: child),
          ),
        ),
      ),
    );

void main() {
  test('三种曲线预采样有界、闭合，循环查表不越界', () {
    for (final curve in CampusCurve.values) {
      final geometry = CurveGeometry.of(curve);
      expect(geometry.points, hasLength(193));
      expect(geometry.points.first, geometry.points.last);
      for (final point in geometry.points) {
        expect(point.dx.isFinite && point.dy.isFinite, isTrue);
        expect(point.distance, lessThan(1.5));
      }
      expect((geometry.at(.999999) - geometry.at(0)).distance, lessThan(.001));
      expect(geometry.at(-.2), geometry.at(.8));
      expect(identical(geometry, CurveGeometry.of(curve)), isTrue);
    }
  });
  testWidgets('真实Lucide打包字体产生矢量MorphPainter而非静态回退', (tester) async {
    configureCampusIcons();
    await tester.pumpWidget(
      host(
        const MorphIcon(
          from: CampusIcons.services,
          to: CampusIcons.servicesSelected,
          progress: AlwaysStoppedAnimation(.5),
          size: 48,
        ),
      ),
    );
    await tester.runAsync(() async {
      await rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf');
      await Future<void>.delayed(const Duration(milliseconds: 350));
    });
    await tester.pumpAndSettle();
    final paints = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .where(
          (paint) => paint.painter.runtimeType.toString() == 'MorphPainter',
        );
    expect(paints, hasLength(1));
    expect(MorphCache.currentMorphs, greaterThan(0));
    expect(MorphCache.currentBytes, lessThanOrEqualTo(4 * 1024 * 1024));
    expect(tester.takeException(), isNull);
  });
  testWidgets('加载器短等待不闪现，持续等待局部绘制，移除清理ticker', (tester) async {
    await tester.pumpWidget(host(const CampusLoader()));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .where((paint) => paint.painter is CurveLoaderPainter),
      isEmpty,
    );
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .where((paint) => paint.painter is CurveLoaderPainter),
      hasLength(1),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets('减少动画、TickerMode和后台停止循环，恢复再运行', (tester) async {
    for (final settings in [
      (reduced: true, ticker: true),
      (reduced: false, ticker: false),
    ]) {
      await tester.pumpWidget(
        host(
          const CampusLoader(delay: Duration.zero),
          reduced: settings.reduced,
          ticker: settings.ticker,
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
    }
    await tester.pumpWidget(host(const CampusLoader(delay: Duration.zero)));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('图标快速反向最终状态正确，减少动画立即切换', (tester) async {
    var selected = false;
    late StateSetter update;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return CampusMorphIcon(
              from: CampusIcons.today,
              to: CampusIcons.todaySelected,
              selected: selected,
            );
          },
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    update(() => selected = true);
    await tester.pump(const Duration(milliseconds: 90));
    update(() => selected = false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      host(
        const CampusMorphIcon(
          from: CampusIcons.today,
          to: CampusIcons.todaySelected,
          selected: true,
        ),
        reduced: true,
      ),
    );
    expect(find.byIcon(CampusIcons.todaySelected), findsOneWidget);
    expect(find.byType(MorphIcon), findsNothing);
  });
  testWidgets('等待弹窗短任务不出现、长任务真实完成后移除且不重复调用', (tester) async {
    final task = Completer<int>();
    var calls = 0;
    int? result;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showCampusWaiting(
                context,
                label: '测试保存',
                operation: () {
                  calls++;
                  return task.future;
                },
              );
            },
            child: const Text('开始'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(calls, 1);
    task.complete(42);
    await tester.pumpAndSettle();
    expect(result, 42);
    expect(find.byType(AlertDialog), findsNothing);
  });
  testWidgets('不透明新路由覆盖后旧页面曲线停止，返回后恢复', (tester) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => Column(
            children: [
              const CampusLoader(delay: Duration.zero),
              TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (context) => const Scaffold(body: Text('覆盖页')),
                  ),
                ),
                child: const Text('打开'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('长等待是说明不是假失败，文案变化重置计时', (tester) async {
    await tester.pumpWidget(
      host(const CampusLoading(label: '读取教务', network: true), reduced: true),
    );
    await tester.pump(const Duration(seconds: 9));
    expect(find.textContaining('仍在等待教务响应'), findsOneWidget);
    await tester.pumpWidget(
      host(
        const CampusLoading(label: '等待确认', network: true, animating: false),
        reduced: true,
      ),
    );
    await tester.pump();
    expect(find.textContaining('仍在等待教务响应'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
