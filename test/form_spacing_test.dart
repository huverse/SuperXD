import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/gateway/campus_gateway.dart';
import 'package:superxd/local/schedule_store.dart';
import 'package:superxd/page/course_editor_page.dart';
import 'package:superxd/theme/campus_theme.dart';

import 'form_layout_support.dart';

final _courses = [
  CourseRecord(courseCode: 'C1', courseName: '合成课程', sectionId: 'S1', credit: 2, teacherName: '合成教师甲', meetings: [
    CourseMeeting(weekday: 3, periodStart: 1, periodEnd: 2, place: '合成楼101室', weeks: [for (var week = 1; week <= 18; week++) week]),
  ]),
  CourseRecord(courseCode: 'C2', courseName: '合成课程二', sectionId: 'S2', credit: 1, teacherName: '合成教师乙', meetings: [
    CourseMeeting(weekday: 1, periodStart: 3, periodEnd: 4, place: '合成楼202室', weeks: [1, 2, 3]),
  ]),
];
const _bells = [
  BellPeriod(period: 1, dayPart: '', dayPartCode: '', start: '08:00', end: '08:45'),
  BellPeriod(period: 2, dayPart: '', dayPartCode: '', start: '08:55', end: '09:40'),
];

Widget _editor(String font, double scale) => MaterialApp(
  theme: campusTheme(fontFamily: font),
  locale: const Locale('zh', 'CN'),
  supportedLocales: const [Locale('zh', 'CN')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
  home: CourseEditorPage(course: _courses.first, courses: _courses, bells: _bells, onSave: (_) async => null),
);

void main() {
  // 1.4为应用特大档，2.8近似系统200%叠加特大档（线性上限）。
  for (final font in ['Maple Mono NF CN', 'Noto Serif SC']) {
    for (final scale in [1.0, 1.4, 2.8]) {
      testWidgets('课程表单与上课时段弹窗 $font ×$scale：标签不压控件，选择标签不裁切', (tester) async {
        await tester.binding.setSurfaceSize(const Size(412, 2400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await loadCampusFonts(tester);
        await tester.pumpWidget(_editor(font, scale));
        await tester.pumpAndSettle();
        expectFieldLabelsClear(tester, ['课程名称', '教师（选填）', '学分（选填）'], '课程表单');
        expectChipLabelsUnclipped(tester, '课程表单');
        await tester.ensureVisible(find.text('添加时段'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('添加时段'));
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        expectFieldLabelsClear(tester, ['开始节次', '结束节次', '地点（选填）'], '上课时段弹窗', scope: dialog);
        expectChipLabelsUnclipped(tester, '上课时段弹窗', scope: dialog);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
