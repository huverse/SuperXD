import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/ical.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/week.dart';
import 'package:superxd/page/schedule_calendar.dart';
import 'package:superxd/theme/campus_transitions.dart';

// 把一份日历文件交给日历应用；测试注入假实现。
typedef CalendarOpener = Future<void> Function(String fileName, String content);

const _channel = MethodChannel('superxd/calendar_export');

// 写进缓存下的固定文件夹，由原生侧以“打开”交给日历应用导入（日历的导入入口不接分享），没有可导入的应用时退回系统分享。
// 对方在启动后才读取文件，不能交出即删：每次导出前清空文件夹，本机只留最近一份。
Future<void> openCalendarFile(String fileName, String content) async {
  final folder = Directory(path.join((await getTemporaryDirectory()).path, 'calendar_export'));
  if (await folder.exists()) await folder.delete(recursive: true);
  await folder.create(recursive: true);
  final file = File(path.join(folder.path, fileName));
  await file.writeAsString(content, flush: true);
  final target = await _channel.invokeMethod<String>('open', {'path': file.path});
  campusLog('[CalendarExport] action=open target=$target');
}

// 导出一个学期的全部上课时段为 .ics 并交给日历。缺开学日、缺作息或没有可导出的时段时说明原因，不导出。
// 作息里找不到的节次不猜时刻；交出后用户已在日历应用里，所以导出前先说明有几个时段不会导出、由用户决定是否继续。
Future<void> exportTermCalendar(BuildContext context, {
  required TermRef term,
  required String? termStartDate,
  required List<BellPeriod> bells,
  required List<CourseRecord> courses,
  required CalendarOpener open,
}) async {
  Future<void> notice(String text) async {
    if (context.mounted) await showCampusNotice(context, text);
  }

  if (termStartDate == null) return notice('请先设置开学日。');
  if (courses.isEmpty) return notice('这个学期没有课程。');
  final result = courseOccurrences(
    courses: courses,
    termStartDate: termStartDate,
    bells: bells,
    from: weekRange(termStartDate, 1).start,
    to: weekRange(termStartDate, maxCourseWeek(courses)).end,
  );
  if (result.gap == OccurrenceGap.bells) return notice('缺少作息时间，同步作息后才能导出。');
  if (result.items.isEmpty) return notice('课程节次都不在作息时间里，无法导出。');
  if (result.items.length > icalEventLimit) return notice('上课次数超过 $icalEventLimit 次，无法导出。');
  if (result.unresolved > 0) {
    final proceed = await showCampusConfirm(context, title: '部分时段不会导出', message: '有 ${result.unresolved} 个时段的节次不在作息时间里，无法确定上课时间。', action: '继续导出');
    if (!proceed || !context.mounted) return;
  }
  final label = term.label.isEmpty ? term.key : term.label;
  final fileName = 'SuperXD_课表_${label.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_')}.ics';
  try {
    await open(fileName, buildIcal(term: term, occurrences: result.items, stamp: DateTime.now()));
  } catch (error, stack) {
    campusLog('[CalendarExport] action=open errorType=${error.runtimeType}\n$stack');
    return notice('无法打开日历，请稍后再试。');
  }
  campusLog('[CalendarExport] action=export events=${result.items.length} unresolved=${result.unresolved}');
}
