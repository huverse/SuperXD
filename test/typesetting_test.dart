import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/period_spans.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/page/course_cards.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/theme/dot_separated_text.dart';

import 'form_layout_support.dart';
import 'text_fit_support.dart';

const _serif = 'Noto Serif SC';

Widget _app(Widget child, {String font = _serif, double scale = 1, bool bold = false}) => MaterialApp(
  theme: campusTheme(fontFamily: font),
  locale: const Locale('zh', 'CN'),
  supportedLocales: const [Locale('zh', 'CN')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale), boldText: bold), child: child!),
  home: Scaffold(body: child),
);

void main() {
  // 10-27 iPhone 系统字体下课程卡的「09:40」缺半个 0：量宽度时没带主题默认的字距、没跟系统「粗体文本」加粗，量的比画的窄。
  testWidgets('测量口径同 Text：带上默认样式的字距与系统粗体文本', (tester) async {
    await loadCampusFonts(tester);
    late double measured;
    const style = TextStyle(fontSize: 20, fontWeight: FontWeight.w500);
    await tester.pumpWidget(_app(bold: true, Builder(builder: (context) {
      measured = campusTextWidth(context, '09:40', style: style);
      return const Center(child: Text('09:40', style: style));
    })));
    final paragraph = tester.renderObject<RenderParagraph>(find.text('09:40'));
    expect(measured, closeTo(paragraph.size.width, .01));
    expect(paragraph.text.style!.letterSpacing, isNot(0), reason: '主题默认样式带字距，测量要同样带上');
    expect(paragraph.text.style!.fontWeight, FontWeight.bold);
  });

  testWidgets('均衡换行：行数不变取最窄宽度，末行不剩一个字；外层 IntrinsicHeight 也能排', (tester) async {
    await loadCampusFonts(tester);
    const style = TextStyle(fontSize: 17);
    late double eight;
    await tester.pumpWidget(_app(Builder(builder: (context) {
      eight = campusTextWidth(context, '马克思主义基本', style: style) + 8;
      return Align(alignment: Alignment.topLeft, child: SizedBox(width: eight, child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Expanded(child: BalancedText('马克思主义基本原理', style: style)),
      ]))));
    })));
    final balanced = tester.renderObject<RenderParagraph>(find.text('马克思主义基本原理'));
    final single = campusTextWidth(tester.element(find.text('马克思主义基本原理')), '马克思主义基', style: style);
    expect(tester.takeException(), isNull);
    expect(balanced.size.width, lessThan(single), reason: '七加二排成五加四');
    expect(scanTexts(tester).where((issue) => issue.kind == 'orphan'), isEmpty);
    // 一行放得下就不动。
    await tester.pumpWidget(_app(const Align(alignment: Alignment.topLeft, child: BalancedText('形势与政策', style: style))));
    expect(tester.renderObject<RenderParagraph>(find.text('形势与政策')).size.height, lessThan(17 * 2));
  });

  testWidgets('说明行折行时「·」跟着前一项，不单独成一行', (tester) async {
    await loadCampusFonts(tester);
    late double width;
    await tester.pumpWidget(_app(Builder(builder: (context) {
      width = campusTextWidth(context, '第1–2节', style: const TextStyle(fontSize: 14)) + 4;
      return Align(alignment: Alignment.topLeft, child: SizedBox(width: width, child: const DotSeparatedText('第1–2节 · 合成教师甲', style: TextStyle(fontSize: 14))));
    })));
    expect(scanTexts(tester).where((issue) => issue.kind == 'lone-punct'), isEmpty);
  });

  // 同 iOS 分段控件的按内容分宽：等分放不下最长的文字时按文字分，宽屏照旧等分。
  testWidgets('分段控件：等分放不下时按文字分宽，不截成「跟随系…」；放得下照旧等分', (tester) async {
    await loadCampusFonts(tester);
    Widget segmented(double width) => _app(font: 'Maple Mono NF CN', scale: 1.4, Center(child: SizedBox(width: width, child: CampusSegmented<String>(values: const ['跟随系统', '浅色', '深色'], selected: '跟随系统', label: (value) => value, onSelected: (_) {}))));
    await tester.pumpWidget(segmented(328));
    expect(scanTexts(tester).where((issue) => issue.kind == 'truncate'), isEmpty);
    expect(tester.getSize(find.ancestor(of: find.text('跟随系统'), matching: find.byType(SizedBox)).first).width, greaterThan(tester.getSize(find.ancestor(of: find.text('浅色'), matching: find.byType(SizedBox)).first).width));
    await tester.pumpWidget(segmented(600));
    expect(tester.getSize(find.ancestor(of: find.text('跟随系统'), matching: find.byType(SizedBox)).first).width, closeTo(tester.getSize(find.ancestor(of: find.text('浅色'), matching: find.byType(SizedBox)).first).width, .5));
  });

  // 课程卡在学期视图那么窄（还开着粗体文本、宋体没有等宽数字）时：时刻不被裁，内容一栏放不下时时刻挪到第一行。
  testWidgets('课程卡：窄处改两栏、时刻写在第一行；宽处照旧三栏；都不裁字', (tester) async {
    await loadCampusFonts(tester);
    const bells = [
      BellPeriod(period: 1, dayPart: '', dayPartCode: '', start: '08:00', end: '08:45'),
      BellPeriod(period: 2, dayPart: '', dayPartCode: '', start: '08:55', end: '09:40'),
    ];
    final spans = periodSpans([
      CourseRecord(courseCode: 'C1', courseName: '马克思主义基本原理', sectionId: 'S1', credit: 3, teacherName: '合成教师乙', meetings: [CourseMeeting(weekday: 1, periodStart: 1, periodEnd: 2, place: '知行楼414室', weeks: [1])]),
    ]);
    for (final (width, stacked) in [(200.0, true), (380.0, false)]) {
      await tester.pumpWidget(_app(bold: true, scale: 1.3, Align(alignment: Alignment.topLeft, child: SizedBox(width: width, height: 600, child: CourseDayCards(spans: spans, bells: bells, date: '2026-09-07')))));
      await tester.pumpAndSettle();
      expect(find.text('08:00–09:40', findRichText: true), stacked ? findsOneWidget : findsNothing, reason: '${width}dp');
      expect(find.text('09:40'), stacked ? findsNothing : findsOneWidget, reason: '${width}dp');
      expect(scanTexts(tester).where((issue) => issue.kind != 'truncate'), isEmpty, reason: '${width}dp');
    }
  });
}
