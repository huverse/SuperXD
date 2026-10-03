import 'package:superxd/domain/course_occurrence.dart';

// 桌面小组件快照覆盖未来 7 天、最多 200 次课；小组件按系统时间自己挑当前与下一节，应用不运行也会走时。
const widgetWindowDays = 7;
const widgetItemLimit = 200;

// 小组件显示什么：未登录、没有学期、缺开学日、缺作息，或课程列表（可能为空，即近期没课）。
enum WidgetStatus { signedOut, noTerm, noTermStart, noBells, ready }

class WidgetSnapshot {
  const WidgetSnapshot({required this.status, this.items = const [], this.until});
  final WidgetStatus status;
  final List<CourseOccurrence> items;
  // 快照覆盖到的时刻（UTC）；过了这个时刻小组件改为提示打开应用，不把过期快照当作“近期没课”。
  final DateTime? until;

  static const signedOut = WidgetSnapshot(status: WidgetStatus.signedOut);
}

// 缺开学日或作息时不给课程；按开始时刻取前 widgetItemLimit 次。今天已下课的也保留，供“今日课程”灰显，是否下课由小组件按当时时间判断。
WidgetSnapshot widgetSnapshot(CourseOccurrences occurrences, {required DateTime until}) => switch (occurrences.gap) {
  OccurrenceGap.termStart => const WidgetSnapshot(status: WidgetStatus.noTermStart),
  OccurrenceGap.bells => const WidgetSnapshot(status: WidgetStatus.noBells),
  null => WidgetSnapshot(status: WidgetStatus.ready, until: until, items: occurrences.items.take(widgetItemLimit).toList()),
};

// 小组件配色（ARGB）：衬底、正文、次要文字。
class WidgetPalette {
  const WidgetPalette({required this.background, required this.text, required this.secondary});
  final int background;
  final int text;
  final int secondary;
}

// 浅色、深色各一套；mode 为 system 时由小组件按系统深浅色挑选。
class WidgetTheme {
  const WidgetTheme({required this.light, required this.dark, required this.mode});
  final WidgetPalette light;
  final WidgetPalette dark;
  final String mode;
}

// 小组件系统端口，由 device 层实现：保存快照或配色并刷新所有已添加的小组件。
abstract class CourseWidgetPort {
  Future<void> publish(WidgetSnapshot snapshot);
  Future<void> applyTheme(WidgetTheme theme);
}
