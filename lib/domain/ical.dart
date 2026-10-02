import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/schedule_store.dart';

// 单次导出上限；一学期 500 门课的极端情况也远低于此。
const icalEventLimit = 5000;

// 导出学期课表为 iCalendar（RFC 5545 最小子集）。pub 上的候选库采用度都很低，按复用阶梯第四级手写。
// - 每次上课一个 VEVENT，时间一律 UTC（…Z），不写 VTIMEZONE。
// - 文本转义反斜杠、分号、逗号与换行；CRLF 换行；超过 75 个八位组折行，不切断多字节字符。
// - UID 由学期、课程、日期、节次哈希而来：重复导入时日历更新同一事件而不是重复添加；不含账号信息。
String buildIcal({required TermRef term, required List<CourseOccurrence> occurrences, required DateTime stamp}) {
  if (occurrences.length > icalEventLimit) throw ArgumentError.value(occurrences.length, 'occurrences', '超过 $icalEventLimit 个事件');
  final lines = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//SuperXD//Course Schedule//ZH',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    'X-WR-CALNAME:${_text('SuperXD ${term.label.isEmpty ? term.key : term.label}')}',
  ];
  for (final occurrence in occurrences) {
    final meeting = occurrence.meeting, course = occurrence.course;
    final periods = meeting.periodStart == meeting.periodEnd ? '第${meeting.periodStart}节' : '第${meeting.periodStart}–${meeting.periodEnd}节';
    lines.addAll([
      'BEGIN:VEVENT',
      'UID:${sha256.convert(utf8.encode('${term.key}|${occurrence.key}')).toString().substring(0, 32)}@superxd',
      'DTSTAMP:${_utc(stamp)}',
      'DTSTART:${_utc(occurrence.start)}',
      'DTEND:${_utc(occurrence.end)}',
      'SUMMARY:${_text(course.courseName)}',
      if (meeting.place.isNotEmpty) 'LOCATION:${_text(meeting.place)}',
      'DESCRIPTION:${_text([periods, if (course.teacherName.isNotEmpty) '教师：${course.teacherName}'].join(' · '))}',
      'END:VEVENT',
    ]);
  }
  lines.add('END:VCALENDAR');
  return '${lines.map(_fold).join('\r\n')}\r\n';
}

String _utc(DateTime value) {
  final utc = value.toUtc();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}${two(utc.day)}T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
}

String _text(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll(';', r'\;')
    .replaceAll(',', r'\,')
    .replaceAll(RegExp(r'\r\n|\r|\n'), r'\n');

// 每行最多 75 个八位组；续行以一个空格开头，空格也计入 75。按字符累加字节数，不在多字节字符中间切开。
String _fold(String line) {
  if (utf8.encode(line).length <= 75) return line;
  final segments = <String>[];
  final current = StringBuffer();
  var octets = 0;
  for (final rune in line.runes) {
    final character = String.fromCharCode(rune);
    final size = utf8.encode(character).length;
    final limit = segments.isEmpty ? 75 : 74;
    if (octets + size > limit) {
      segments.add(current.toString());
      current.clear();
      octets = 0;
    }
    current.write(character);
    octets += size;
  }
  segments.add(current.toString());
  return segments.join('\r\n ');
}
