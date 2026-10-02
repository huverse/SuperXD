import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/course_widget.dart';

// 桌面小组件的系统实现：快照与配色交给原生侧保存（CourseWidgets.kt），原生小组件按系统时间挑当前与下一节，在课程边界自行刷新。
// 钟点与日期在这里按校园时区算好，原生侧只用 campusTimeZone 判断“今天”。
class HomeWidgetPublisher implements CourseWidgetPort {
  static const _channel = MethodChannel('superxd/course_widget');

  @override
  Future<void> publish(WidgetSnapshot snapshot) => _channel.invokeMethod<void>('publish', {
    'snapshot': jsonEncode({
      'status': snapshot.status.name,
      'timeZone': campusTimeZone,
      'until': snapshot.until?.millisecondsSinceEpoch,
      'items': [
        for (final item in snapshot.items)
          {
            'start': item.start.millisecondsSinceEpoch,
            'end': item.end.millisecondsSinceEpoch,
            'date': item.date,
            'startText': formatCampusClock(item.start),
            'endText': formatCampusClock(item.end),
            'name': item.course.courseName,
            'place': item.meeting.place,
          },
      ],
    }),
  });

  @override
  Future<void> applyTheme(WidgetTheme theme) => _channel.invokeMethod<void>('theme', {
    'theme': jsonEncode({
      'mode': theme.mode,
      for (final (name, palette) in [('light', theme.light), ('dark', theme.dark)])
        name: {'background': palette.background, 'text': palette.text, 'secondary': palette.secondary},
    }),
  });
}
