import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/period_spans.dart';

class PeriodDay extends StatelessWidget {
  const PeriodDay({super.key, required this.courses, required this.card, this.empty});
  final List<CourseRecord> courses;
  final Widget Function(CourseRecord course, CourseMeeting meeting) card;
  final Widget Function(PeriodSpan span)? empty;

  @override
  Widget build(BuildContext context) {
    final spans = periodSpans(courses);
    if (spans.isEmpty) {
      return Align(alignment: Alignment.topLeft, child: Text('这天没课', style: TextStyle(fontSize: 16, color: CampusPalette.of(context).onSurface)));
    }
    return ListView(
      physics: const ClampingScrollPhysics(),
      children: [
        for (final span in spans)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: span.empty ? (empty?.call(span) ?? _emptyCard(context, span)) : card(span.course!, span.meeting!),
          ),
      ],
    );
  }

  Widget _emptyCard(BuildContext context, PeriodSpan span) {
    final morning = span.start <= 2;
    final title = morning ? '早八没课哦~' : '这几节没课';
    final time = span.start == span.end ? '${span.start}节' : '${span.start}–${span.end}节';
    return CampusSurface(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(time, style: TextStyle(fontSize: 14, color: CampusPalette.of(context).onSurfaceVariant, height: 20 / 14)),
          Text(title, style: TextStyle(fontSize: 16, color: CampusPalette.of(context).onSurface, height: 24 / 16)),
        ],
      ),
    );
  }
}
