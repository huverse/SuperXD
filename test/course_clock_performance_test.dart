import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/gateway/campus_gateway.dart';
import 'package:superxd/local/campus_clock.dart';
import 'package:superxd/local/period_spans.dart';
import 'package:superxd/local/schedule_store.dart';
import 'package:superxd/page/course_cards.dart';
import 'package:superxd/page/live_clock.dart';
import 'package:superxd/theme/campus_theme.dart';

void main() {
  testWidgets('隐藏课程不订阅分钟时钟，重新激活即恢复，释放不残留监听', (tester) async {
    final active = ValueNotifier(true);
    ValueNotifier<DateTime>? clock;
    final course = CourseRecord(courseCode: 'C1', courseName: '课程', sectionId: 'S1', credit: 1, teacherName: '教师', meetings: [CourseMeeting(weekday: 5, periodStart: 1, periodEnd: 2, place: '教室', weeks: [1])]);
    final spans = periodSpans([course]);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: LiveClock(child: Builder(builder: (context) {
      clock = LiveClock.maybeOf(context);
      return ValueListenableBuilder(valueListenable: active, child: Scaffold(body: CourseDayCards(spans: spans, bells: const <BellPeriod>[], date: campusToday())), builder: (context, enabled, child) => TickerMode(enabled: enabled, child: child!));
    }))));
    await tester.pumpAndSettle();
    // 测试仅观察监听生命周期，不访问或修改监听列表。
    // ignore: invalid_use_of_protected_member
    expect(clock!.hasListeners, isTrue);
    active.value = false;
    await tester.pump();
    // 测试仅观察监听生命周期，不访问或修改监听列表。
    // ignore: invalid_use_of_protected_member
    expect(clock!.hasListeners, isFalse);
    clock!.value = clock!.value.add(const Duration(minutes: 1));
    await tester.pump();
    active.value = true;
    await tester.pump();
    // 测试仅观察监听生命周期，不访问或修改监听列表。
    // ignore: invalid_use_of_protected_member
    expect(clock!.hasListeners, isTrue);
    expect(find.text('课程'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    active.dispose();
    expect(tester.takeException(), isNull);
  });
}
