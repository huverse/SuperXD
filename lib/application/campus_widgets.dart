import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/course_widget.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/week.dart';

// 桌面小组件编排：读本机的当前学期、课表与作息，展开今天起 7 天的课程实例，交给小组件端口。
// 只读本地数据，从不联网；串行执行，内容与上次相同时不重复发布。未登录时发布空快照，小组件不显示上一个账号的课。
class CampusWidgets {
  CampusWidgets({required this.gateway, required this.port, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final CampusGateway gateway;
  final CourseWidgetPort port;
  final DateTime Function() _clock;
  final _lock = Lock();
  String? _published;

  Future<void> refresh({required bool signedIn}) => _lock.synchronized(() async {
    if (!signedIn) return _publish(WidgetSnapshot.signedOut);
    final terms = await gateway.listTerms();
    final term = terms.ok ? terms.data?.firstOrNull : null;
    if (term == null) return _publish(const WidgetSnapshot(status: WidgetStatus.noTerm));
    final schedule = await gateway.readSchedule(ScheduleScope.term(term));
    final bells = await gateway.readBells(term);
    final today = parseIsoDate(formatCampusDate(campusInstant(_clock().toUtc())));
    final occurrences = courseOccurrences(
      courses: schedule.data?.courses ?? const [],
      termStartDate: schedule.data?.termStartDate,
      bells: bells.data?.periods ?? const [],
      from: formatIsoDate(today),
      to: formatIsoDate(today.add(const Duration(days: widgetWindowDays - 1))),
    );
    await _publish(widgetSnapshot(occurrences, until: campusMoment(formatIsoDate(today.add(const Duration(days: widgetWindowDays))), 0)));
  });

  Future<void> _publish(WidgetSnapshot snapshot) async {
    final signature = [
      snapshot.status.name,
      snapshot.until?.toIso8601String(),
      for (final item in snapshot.items) '${item.key}|${item.start.toIso8601String()}|${item.end.toIso8601String()}|${item.course.courseName}|${item.meeting.place}',
    ].join('\n');
    if (signature == _published) return;
    await port.publish(snapshot);
    _published = signature;
  }
}
