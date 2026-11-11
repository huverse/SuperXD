import 'dart:async';

import 'package:flutter/material.dart';
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
import 'text_fit_support.dart';
import 'toolbox_test_support.dart';

// 主要页面在窄屏大字号、宋体加系统「粗体文本」与宽屏标准三种条件下排版不出错：不裁字、不剩一行标点，课程与提示不留孤字。
// 10-27 用户真机截图（iPhone 系统字体下「09:40」缺半个 0，360dp 安卓学期视图课名一两个字一行、同意行换行留大空行）后加。
// 这一屏的问题（只算错的种类）；orphan 只在 checkOrphans 时算（今天页的「此刻」卡随真实时刻变，不查孤字）。
List<String> _problems(WidgetTester tester, {bool checkOrphans = true}) => [
  for (final issue in scanTexts(tester))
    if (issue.kind != 'truncate' && (checkOrphans || issue.kind != 'orphan')) '$issue',
];

void main() {
  for (final (font, width, system, app, bold) in [
    ('maple', 360.0, 1.3, 1.0, false),
    ('maple', 360.0, 1.0, 1.3, false),
    ('serif', 360.0, 1.0, 1.4, true),
    ('maple', 411.0, 1.0, 1.0, false),
    ('maple', 360.0, 1.0, 1.0, false),
    ('maple', 360.0, 1.0, .8, false),
  ]) {
    testWidgets('排版：$font ${width.toInt()}dp 系统×$system 应用×$app${bold ? ' 粗体文本' : ''}：不裁字、不剩一行标点、课名与提示不留孤字', (tester) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = Size(width * 3, 800 * 3);
      tester.platformDispatcher.textScaleFactorTestValue = system;
      if (bold) tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(boldText: true);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      addTearDown(tester.view.reset);
      await loadCampusFonts(tester);
      final fixture = ToolboxFixture();
      await tester.runAsync(fixture.initialize);
      final fixtures = pageFixtures();
      final inner = FixtureCampusGateway(readText: (name) async => fixtures[name]!);
      // 开学日取八周前的周一，今天总在学期中间。
      final today = parseIsoDate(campusToday());
      await inner.setTermStart(pageTerm, formatIsoDate(today.subtract(Duration(days: today.weekday - 1 + 56))));
      final display = DisplaySettings.memory();
      await display.setFont(font);
      // 应用字号是实际显示大小：标准时跟随系统（系统字号照常生效），其余直接给大小（人工决策见 display_settings.dart 的 textSizeMin）。
      await display.setTextSize(app == 1 ? null : app);
      // 学期视图左侧栏按最宽的一项定宽，Maple 标准字号在 360dp 上放得下（人工决策见 schedule_page.dart 的 semesterRailFits），再大就收成横条。
      // 跟随系统时最多到推荐上限，也就是左侧栏放得下的最大字号（人工决策见 display_settings.dart 的 textSizeMin），系统 130% 也照样是左侧栏；
      // 自己选的大字号才收成横条。
      final rail = app <= 1;

      final loggedOut = AppSession(FixtureAccounts(inner, signedIn: false));
      await loggedOut.restore();
      await tester.pumpWidget(SuperXdApp(session: loggedOut, display: display, toolbox: fixture.runtime, backgroundPhase: .18));
      await tester.pumpAndSettle();
      expect(_problems(tester), isEmpty, reason: '登录页');
      // 同意行：「用户协议 和 隐私政策」整组在同一行，换行后行距按文字排，不按 48 的按钮触区撑开。
      expect(tester.getTopLeft(find.text('隐私政策')).dy, closeTo(tester.getTopLeft(find.text('用户协议')).dy, 1));
      expect(tester.getTopLeft(find.text('用户协议')).dy - tester.getTopLeft(find.text('我已阅读并同意')).dy, lessThan(40 * system * app));
      // 登录按钮的图标紧挨着文字（以前按「正在登录」占位，图标与「登录」之间空出两个字宽）。
      final icon = find.descendant(of: find.byType(FilledButton), matching: find.byType(Icon)).first;
      expect(tester.getTopLeft(find.text('登录')).dx - tester.getCenter(icon).dx, closeTo(12 + 8, 1));
      await tester.pumpWidget(const SizedBox());
      loggedOut.dispose();

      final session = AppSession(FixtureAccounts(inner, signedIn: true));
      await session.restore();
      await tester.pumpWidget(SuperXdApp(session: session, display: display, toolbox: fixture.runtime, backgroundPhase: .18));
      await tester.pumpAndSettle();
      expect(_problems(tester, checkOrphans: false), isEmpty, reason: '今天');
      final router = GoRouter.of(tester.element(find.byType(ShellPage)));
      unawaited(router.push('/schedule'));
      await tester.pumpAndSettle();
      expect(_problems(tester), isEmpty, reason: '课表·天');
      await tester.tap(find.text('学期'));
      await tester.pumpAndSettle();
      expect(_problems(tester), isEmpty, reason: '课表·学期');
      // [人工决策] 见 lib/page/schedule_page.dart 的 semesterRailFits：窄屏大字号下月份周次收成卡片上方的一行横条，宽屏照旧竖栏。
      expect(find.textContaining(RegExp(r'^第\d+周 \d+/\d+ · 本周$')), rail ? findsNothing : findsOneWidget);
      expect(find.textContaining(RegExp(r'^第\d+周\n\d+/\d+\n本周$')), rail ? findsOneWidget : findsNothing);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      unawaited(router.push('/grades'));
      await tester.pumpAndSettle();
      expect(_problems(tester), isEmpty, reason: '成绩');
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      await tester.runAsync(fixture.close);
    });
  }
}
