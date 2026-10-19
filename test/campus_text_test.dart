import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/grades.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

// 面向用户的几种文案的唯一写法：节次、学分、按远近写的时刻、不及格、打码的手机号。
void main() {
  test('节次：只有一节写「第3节」，几节写「第1–2节」', () {
    expect(periodLabel(3, 3), '第3节');
    expect(periodLabel(1, 2), '第1–2节');
  });

  test('学分：整数不带小数，其余照原样', () {
    expect(creditLabel(5.0), '5');
    expect(creditLabel(2.5), '2.5');
    expect(creditLabel(0), '0');
  });

  test('时刻按远近写到分钟：今天、昨天、明天、今年写月日、跨年带年份，日子按校园时区算', () {
    // 校园时区 UTC+8：2026-10-19 09:30 北京时间。
    final now = DateTime.utc(2026, 10, 19, 1, 30);
    expect(formatCampusRelative('2026-10-19T09:12:34Z', now: now), '今天 17:12');
    // UTC 前一天 16:30 已是北京时间今天 00:30。
    expect(formatCampusRelative('2026-10-18T16:30:00Z', now: now), '今天 00:30');
    expect(formatCampusRelative('2026-10-18T09:05:00Z', now: now), '昨天 17:05');
    expect(formatCampusRelative('2026-10-20T01:00:00Z', now: now), '明天 09:00');
    expect(formatCampusRelative('2026-03-02T02:00:00Z', now: now), '3月2日 10:00');
    expect(formatCampusRelative('2025-12-31T04:00:00Z', now: now), '2025年12月31日 12:00');
    expect(formatCampusRelative('不是时间', now: now), '不是时间');
  });

  test('不及格：低于 60 分，或教务写着不及格、不合格', () {
    expect(gradeFailing(59.5), isTrue);
    expect(gradeFailing('45'), isTrue);
    expect(gradeFailing(60), isFalse);
    expect(gradeFailing('不及格'), isTrue);
    expect(gradeFailing(' 不合格 '), isTrue);
    expect(gradeFailing('合格'), isFalse);
    expect(gradeFailing('优秀'), isFalse);
    expect(gradeFailing(null), isFalse);
  });

  test('学习通手机号打码：中间四位换成星号，太短的照原样', () {
    expect(chaoxingMaskedPhone('13800138000'), '138****8000');
    expect(chaoxingMaskedPhone('12345'), '12345');
  });
}
