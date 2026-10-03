import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/application/campus_widgets.dart';
import 'package:superxd/device/home_widget_publisher.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/course_widget.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/main.dart';
import 'package:superxd/theme/campus_palette.dart';

import 'fixture_campus_gateway.dart';

const _term = TermRef(xn: '2026', xq: '0', label: '2026-2027学年第一学期');
const _bells = [
  BellPeriod(period: 1, dayPart: '', dayPartCode: '', start: '08:00', end: '08:45'),
  BellPeriod(period: 2, dayPart: '', dayPartCode: '', start: '08:55', end: '09:40'),
];

// 开学日 2026-09-07 为周一；每门课一个周几时段，第 1–3 周。
CourseRecord _course(String name, int weekday, {String place = '知敬楼405室'}) => CourseRecord(courseCode: name, courseName: name, sectionId: name, credit: 2, teacherName: '', meetings: [
  CourseMeeting(weekday: weekday, periodStart: 1, periodEnd: 2, place: place, weeks: const [1, 2, 3]),
]);

class _Gateway extends FixtureCampusGateway {
  _Gateway() : super(readText: (name) async => '');
  List<TermRef> terms = [_term];
  List<CourseRecord> courses = [];
  String? start = '2026-09-07';
  List<BellPeriod> bells = _bells;
  @override
  Future<GatewayResult<List<TermRef>>> listTerms() async => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: terms);
  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) async => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp',
    data: ScheduleView(term: _term, student: const SessionView(loginId: 'test', name: '', className: ''), termStartDate: start, revisionId: 'rev', courses: courses));
  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) async => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: BellsView(empty: bells.isEmpty, message: '', term: term, periods: bells));
}

class _Port implements CourseWidgetPort {
  final published = <WidgetSnapshot>[];
  final themes = <WidgetTheme>[];
  @override
  Future<void> publish(WidgetSnapshot snapshot) async => published.add(snapshot);
  @override
  Future<void> applyTheme(WidgetTheme theme) async => themes.add(theme);
}

double _contrast(Color left, Color right) {
  final a = left.computeLuminance(), b = right.computeLuminance();
  return (math.max(a, b) + .05) / (math.min(a, b) + .05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('快照：缺开学日或作息不给课程；今天已下课的保留，最多 200 次', () {
    final until = DateTime.utc(2026, 9, 13, 16);
    expect(widgetSnapshot(const CourseOccurrences([], gap: OccurrenceGap.termStart), until: until).status, WidgetStatus.noTermStart);
    expect(widgetSnapshot(const CourseOccurrences([], gap: OccurrenceGap.bells), until: until).status, WidgetStatus.noBells);
    final many = courseOccurrences(courses: [for (var day = 1; day <= 7; day++) for (var index = 0; index < 40; index++) _course('课$day-$index', day)], termStartDate: '2026-09-07', bells: _bells, from: '2026-09-07', to: '2026-09-13');
    final snapshot = widgetSnapshot(many, until: until);
    expect(snapshot.status, WidgetStatus.ready);
    expect(snapshot.until, until);
    expect(snapshot.items, hasLength(widgetItemLimit));
    expect(snapshot.items.first.date, '2026-09-07');
  });

  test('编排：未登录、无学期、缺作息分别给状态；只取今天起 7 天，内容不变不重发', () async {
    final gateway = _Gateway(), port = _Port();
    // 2026-09-08 周二 12:00（校园时间），当天上午的课已结束。
    final widgets = CampusWidgets(gateway: gateway, port: port, clock: () => DateTime.utc(2026, 9, 8, 4));
    await widgets.refresh(signedIn: false);
    expect(port.published.single.status, WidgetStatus.signedOut);
    gateway.terms = [];
    await widgets.refresh(signedIn: true);
    expect(port.published.last.status, WidgetStatus.noTerm);
    gateway.terms = [_term];
    gateway.bells = [];
    await widgets.refresh(signedIn: true);
    expect(port.published.last.status, WidgetStatus.noBells);
    gateway.bells = _bells;
    gateway.courses = [_course('周一课', 1), _course('周二课', 2), _course('周三课', 3, place: '')];
    await widgets.refresh(signedIn: true);
    final ready = port.published.last;
    expect(ready.status, WidgetStatus.ready);
    // 窗口 9/8–9/14：今天（已下课）的周二课、9/9 周三课、9/14 周一课；9/15 起超出窗口。
    expect(ready.items.map((item) => '${item.date} ${item.course.courseName}'), ['2026-09-08 周二课', '2026-09-09 周三课', '2026-09-14 周一课']);
    expect(ready.until, DateTime.utc(2026, 9, 14, 16));
    final count = port.published.length;
    await widgets.refresh(signedIn: true);
    expect(port.published, hasLength(count));
    await widgets.refresh(signedIn: false);
    expect(port.published.last.items, isEmpty);
  });

  test('适配器：钟点与日期按校园时区算好再交给原生侧，配色为 ARGB 整数', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('superxd/course_widget'), (call) async {
      calls.add(call);
      return null;
    });
    final items = courseOccurrences(courses: [_course('高等数学', 1)], termStartDate: '2026-09-07', bells: _bells, from: '2026-09-07', to: '2026-09-07').items;
    await HomeWidgetPublisher().publish(WidgetSnapshot(status: WidgetStatus.ready, items: items, until: DateTime.utc(2026, 9, 13, 16)));
    final snapshot = jsonDecode(calls.single.arguments['snapshot'] as String) as Map<String, dynamic>;
    expect(snapshot['status'], 'ready');
    expect(snapshot['timeZone'], 'Asia/Shanghai');
    expect(snapshot['until'], DateTime.utc(2026, 9, 13, 16).millisecondsSinceEpoch);
    expect(snapshot['items'], [
      {'start': DateTime.utc(2026, 9, 7).millisecondsSinceEpoch, 'end': DateTime.utc(2026, 9, 7, 1, 40).millisecondsSinceEpoch, 'date': '2026-09-07', 'startText': '08:00', 'endText': '09:40', 'name': '高等数学', 'place': '知敬楼405室'},
    ]);
    await HomeWidgetPublisher().applyTheme(const WidgetTheme(light: WidgetPalette(background: 0xEBF9F8F5, text: 0xFF292B2A, secondary: 0xFF565B57), dark: WidgetPalette(background: 1, text: 2, secondary: 3), mode: 'system'));
    expect(jsonDecode(calls.last.arguments['theme'] as String), {
      'mode': 'system',
      'light': {'background': 0xEBF9F8F5, 'text': 0xFF292B2A, 'secondary': 0xFF565B57},
      'dark': {'background': 1, 'text': 2, 'secondary': 3},
    });
  });

  test('小组件配色：每套配色浅深两色，叠在纯黑或纯白壁纸上正文与次要文字都不低于 4.5:1', () {
    final display = DisplaySettings.memory();
    for (final palette in CampusPalette.values) {
      display.setPalette(palette.id);
      final theme = widgetThemeOf(display);
      for (final colors in [theme.light, theme.dark]) {
        final background = Color(colors.background);
        for (final wallpaper in [Colors.black, Colors.white]) {
          final composite = Color.alphaBlend(background, wallpaper);
          expect(_contrast(Color(colors.text), composite), greaterThanOrEqualTo(4.5), reason: '${palette.id} text');
          expect(_contrast(Color(colors.secondary), composite), greaterThanOrEqualTo(4.5), reason: '${palette.id} secondary');
        }
      }
    }
  });

  test('配色只在配色方案或深浅色变化时重发', () async {
    final display = DisplaySettings.memory(), port = _Port();
    watchWidgetTheme(display, port);
    expect(port.themes.single.mode, 'system');
    await display.setScale(1.25);
    expect(port.themes, hasLength(1));
    await display.setThemeMode(ThemeMode.dark);
    expect(port.themes.last.mode, 'dark');
    await display.setPalette(CampusPalette.values.last.id);
    expect(port.themes, hasLength(3));
    expect(port.themes.last.light.text, CampusPalette.values.last.onSurface.toARGB32());
  });
}
