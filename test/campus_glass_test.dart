import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/page/licenses_page.dart';
import 'package:superxd/theme/campus_background.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_surface.dart';

void main() {
  test('暖灰背景最坏明度下正文辅助与按钮对比度合格', () {
    double contrast(Color left, Color right) {
      final a = left.computeLuminance(), b = right.computeLuminance();
      return (a > b ? a + .05 : b + .05) / (a > b ? b + .05 : a + .05);
    }

    for (final background in [
      CampusPalette.values.first.backgroundTop,
      CampusPalette.values.first.backgroundBottom,
      CampusPalette.values.first.surface,
      CampusPalette.values.first.surfaceSelected,
      CampusPalette.values.first.glassFallback,
    ]) {
      expect(
        contrast(CampusPalette.values.first.onSurface, background),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(CampusPalette.values.first.onSurfaceVariant, background),
        greaterThanOrEqualTo(4.5),
      );
    }
    expect(
      contrast(CampusPalette.values.first.primary, CampusPalette.values.first.onPrimary),
      greaterThanOrEqualTo(4.5),
    );
  });
  testWidgets('背景单层循环在减少动画和后台停帧，固定相位可验收', (tester) async {
    Widget host({bool reduced = false, double? phase}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: CampusMotion(
          child: CampusAtmosphere(
            phase: phase,
            child: const Scaffold(body: Text('页面')),
          ),
        ),
      ),
    );
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.binding.hasScheduledFrame, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(host(reduced: true));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(host(phase: .5));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
  testWidgets('许可页精确两行署名并保留多个包及原始许可正文', (tester) async {
    final entry = LicenseEntryWithLineBreaks([
      'flutter-test-package',
      'second-package',
    ], 'Copyright Test Owner\n\nFull original license content.');
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        home: CampusLicensesPage(licenses: Stream.value(entry)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Powered&Design By Galaxyous'), findsOneWidget);
    expect(find.text('基于Flutter框架'), findsOneWidget);
    expect(find.text('Powered by Flutter'), findsNothing);
    expect(find.text('second-package'), findsOneWidget);
    await tester.tap(find.text('flutter-test-package'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Copyright Test Owner'), findsOneWidget);
    expect(
      find.textContaining('Full original license content.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('细磨砂卡在窄屏大字号保持可点击且不添加背景滤镜', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var clicked = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
          child: Scaffold(
            body: CampusSurface(
              onTap: () => clicked = true,
              child: const Text('完整课程名称与成绩信息，不折射业务文字'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.textContaining('完整课程名称'));
    expect(clicked, isTrue);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
