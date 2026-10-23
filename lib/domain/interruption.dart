import 'package:superxd/domain/course_occurrence.dart';

// [人工决策-2026-10-23 23:25:34] 打扰时机（用户要求：临近上课、下课时用户最需要的是信息而不是惊喜，节日动画、新信这类不是用户要的内容这时不出现，
// 等合适的时候再出现，不迫切时立即出现）。上课前后、下课前后的安静期取助手提出的默认值（用户未提异议）：
// 开课前 20 分钟到开课后 5 分钟（找教室、赶路、刚坐下），下课前 5 分钟到下课后 10 分钟（收拾、看下一节在哪），课间相连的并成一段。
// 其余条件（只在底栏四个根页、没有弹窗、开屏走完、快捷入口进来的这次不出现、每次回到前台最多一次）见 application/app_moments.dart。
const quietBeforeStart = Duration(minutes: 20);
const quietAfterStart = Duration(minutes: 5);
const quietBeforeEnd = Duration(minutes: 5);
const quietAfterEnd = Duration(minutes: 10);

// 现在落在今天某节课的安静期里：返回这段安静期（相连、重叠的合成一段）结束的时刻；不在就返回 null。
DateTime? classQuietUntil(DateTime now, Iterable<CourseOccurrence> classes) {
  final windows = [
    for (final item in classes) ...[
      (from: item.start.subtract(quietBeforeStart), to: item.start.add(quietAfterStart)),
      (from: item.end.subtract(quietBeforeEnd), to: item.end.add(quietAfterEnd)),
    ],
  ]..sort((a, b) => a.from.compareTo(b.from));
  DateTime? from, to;
  for (final window in windows) {
    if (to != null && !window.from.isAfter(to)) {
      if (window.to.isAfter(to)) to = window.to;
      continue;
    }
    if (from != null && !now.isBefore(from) && now.isBefore(to!)) return to;
    (from, to) = (window.from, window.to);
  }
  return from != null && !now.isBefore(from) && now.isBefore(to!) ? to : null;
}
