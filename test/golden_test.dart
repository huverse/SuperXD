import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/week.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/main.dart';
import 'package:superxd/page/shell_page.dart';

import 'fixture_campus_gateway.dart';
import 'form_layout_support.dart';
import 'page_fixture_support.dart';
import 'toolbox_test_support.dart';

// 关键页面的基准图（golden）：界面库（玻璃、滑动露出按钮、图标）、主题与排版改动前后逐像素比，差得多了就失败。
// 改了样子是有意的：看过 test/failures 里的差异图，确认是要的效果，再 flutter test --update-goldens test/golden_test.dart 重生成并一起提交。
// - 只在 Linux 上比（CI 的 Flutter 作业与本机都是 Linux、同一 Flutter 版本），别的平台跳过：字形光栅化跨平台不一致。
// - 用真实字体（Maple 三个字重、Lucide 图标），合成数据，背景云雾固定相位；只拍不随日期变的页面与内容（今天页、课表的日期每天都变，交给排版体检 text_layout_test.dart）。
//   成绩的同步时刻取当天零点，显示总是「今天 00:00」。
// - 容差：差异像素不超过 goldenTolerance（万分之一，这个尺寸下约 33 个像素）算通过，只吸收个别像素的抗锯齿差别；
//   换掉一个 16 像素的图标约差 136 个像素（0.04%），换色、挪位置更多，都会失败。
const goldenTolerance = 0.0001;

class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile);

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(imageBytes, await getGoldenBytes(golden));
    if (result.passed || result.diffPercent <= goldenTolerance) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

Future<void> _loadIconFonts(WidgetTester tester) => tester.runAsync(() async {
  await (FontLoader('packages/lucide_icons_flutter/Lucide')..addFont(rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'))).load();
  await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
});

// 成绩与课表的同步时刻改成今天零点（校园时区），按远近写出来总是「今天 00:00」。
Map<String, String> _stableFixtures() {
  final midnight = campusMoment(campusToday(), 0).toUtc().toIso8601String();
  return {
    for (final MapEntry(:key, :value) in pageFixtures().entries)
      key: jsonEncode({...(jsonDecode(value) as Map<String, Object?>), 'fetchedAt': midnight}),
  };
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  // 图片与字体在真实时间里解码，再出一帧。
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pumpAndSettle();
}

Future<void> _expectGolden(WidgetTester tester, String name) async {
  await _settle(tester);
  await expectLater(find.byType(SuperXdApp), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  final linux = Platform.isLinux;
  setUpAll(() {
    if (linux) goldenFileComparator = _TolerantComparator(Uri.parse('${(goldenFileComparator as LocalFileComparator).basedir}golden_test.dart'));
    // 调试包右上角的「DEBUG」斜条会盖住顶栏按钮，基准图里不要。
    WidgetsApp.debugAllowBannerOverride = false;
  });
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('基准图（${mode == ThemeMode.dark ? '深色' : '浅色'}）：登录、服务、我的、界面、成绩、百宝箱与左滑露出的按钮', skip: !linux, (tester) async {
      // 1 倍像素：图小（仓库公开、每次重生成都进历史），排版、配色、图标与玻璃的变化照样看得出。
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      await loadCampusFonts(tester);
      await _loadIconFonts(tester);
      final fixture = ToolboxFixture();
      await tester.runAsync(fixture.initialize);
      final fixtures = _stableFixtures();
      final inner = FixtureCampusGateway(readText: (name) async => fixtures[name]!);
      final today = parseIsoDate(campusToday());
      await inner.setTermStart(pageTerm, formatIsoDate(today.subtract(Duration(days: today.weekday - 1 + 56))));
      final display = DisplaySettings.memory();
      await display.setThemeMode(mode);
      final suffix = mode == ThemeMode.dark ? 'dark' : 'light';

      final loggedOut = AppSession(FixtureAccounts(inner, signedIn: false));
      await loggedOut.restore();
      await tester.pumpWidget(SuperXdApp(session: loggedOut, display: display, toolbox: fixture.runtime, backgroundPhase: .18));
      await _expectGolden(tester, 'login_$suffix');
      await tester.pumpWidget(const SizedBox());
      loggedOut.dispose();

      final session = AppSession(FixtureAccounts(inner, signedIn: true));
      await session.restore();
      await tester.pumpWidget(SuperXdApp(session: session, display: display, toolbox: fixture.runtime, backgroundPhase: .18));
      await tester.pumpAndSettle();
      final router = GoRouter.of(tester.element(find.byType(ShellPage)));
      router.go('/service');
      await _expectGolden(tester, 'service_$suffix');
      router.go('/mine');
      await _expectGolden(tester, 'mine_$suffix');
      await tester.tap(find.text('界面'));
      await _expectGolden(tester, 'appearance_$suffix');
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      unawaited(router.push('/grades'));
      await _expectGolden(tester, 'grades_$suffix');
      await tester.tap(find.byTooltip('返回服务'));
      await tester.pumpAndSettle();
      unawaited(router.push('/toolbox'));
      await _expectGolden(tester, 'toolbox_$suffix');
      // 卡片左滑露出「清除数据」等按钮（flutter_slidable）。
      await tester.drag(find.text('视频解析'), const Offset(-240, 0));
      await _expectGolden(tester, 'toolbox_swiped_$suffix');
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      await tester.runAsync(fixture.close);
    });
  }
}
