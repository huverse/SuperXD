import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/schedule_store.dart';

class MeetingTime {
  const MeetingTime(this.startMinute, this.endMinute, this.startLabel, this.endLabel);
  final int startMinute;
  final int endMinute;
  final String startLabel;
  final String endLabel;
  String get label => '$startLabel–$endLabel';
}

MeetingTime? meetingTime(List<BellPeriod> bells, CourseMeeting meeting) => periodTime(bells, meeting.periodStart, meeting.periodEnd);

MeetingTime? periodTime(List<BellPeriod> bells, int periodStart, int periodEnd) {
  final first = bells.where((bell) => bell.period == periodStart).firstOrNull;
  final last = bells.where((bell) => bell.period == periodEnd).firstOrNull;
  if (first == null || last == null) return null;
  final start = clockMinutes(first.start);
  final end = clockMinutes(last.end);
  if (start == null || end == null || end <= start) return null;
  return MeetingTime(start, end, first.start, last.end);
}
