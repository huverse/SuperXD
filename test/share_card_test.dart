import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/share_card.dart';

ScheduleShare sampleSchedule() => ScheduleShare(
  term: const TermRef(xn: '2026', xq: '0', label: '2026-2027学年第一学期'),
  termStartDate: '2026-09-07',
  courses: [
    CourseRecord(courseCode: 'MA101', courseName: '高等数学', sectionId: 'A1', credit: 4, teacherName: '张老师', meetings: [CourseMeeting(weekday: 1, periodStart: 1, periodEnd: 2, place: 'A101', weeks: [1, 2, 3])]),
    // 自建课程没有代码与课序，靠 localId 区分同名课。
    CourseRecord(courseCode: '', courseName: '社团活动', sectionId: '', credit: null, teacherName: '', localId: 'local-1', meetings: [CourseMeeting(weekday: 3, periodStart: 5, periodEnd: 6, place: '', weeks: [2])]),
    CourseRecord(courseCode: '', courseName: '社团活动', sectionId: '', credit: null, teacherName: '', localId: 'local-2', meetings: [CourseMeeting(weekday: 5, periodStart: 5, periodEnd: 6, place: '', weeks: [2])]),
  ],
  bells: const [
    BellPeriod(period: 1, dayPart: '上午', dayPartCode: 'am', start: '08:00', end: '08:45'),
    BellPeriod(period: 2, dayPart: '上午', dayPartCode: 'am', start: '08:55', end: '09:40'),
  ],
);

// 模拟经网络传输：编码成 JSON 文本再解析，和真实收到的一样。
ShareCard roundTrip(ShareCard card) => decodeShareCard(jsonDecode(jsonEncode(encodeShareCard(card))));

void main() {
  test('课表卡片往返保留学期、开学日、课程（含自建课程 localId）与作息', () {
    final decoded = roundTrip(sampleSchedule()) as ScheduleShare;
    expect(decoded.term.label, '2026-2027学年第一学期');
    expect(decoded.termStartDate, '2026-09-07');
    expect(decoded.courses.map((course) => course.courseName), ['高等数学', '社团活动', '社团活动']);
    expect(decoded.courses[1].localId, 'local-1');
    expect(decoded.courses.first.meetings.single.weeks, [1, 2, 3]);
    expect(decoded.bells.map((bell) => bell.start), ['08:00', '08:55']);
  });

  test('界面与视频卡片往返', () {
    const appearance = AppearanceShare(paletteId: 'mist', fontId: 'serif', scale: 1.1, themeMode: 'dark', glassMode: 'auto', wallpaperBlur: 27, wallpaperFade: 40);
    final decodedAppearance = roundTrip(appearance) as AppearanceShare;
    expect([decodedAppearance.paletteId, decodedAppearance.fontId, decodedAppearance.scale, decodedAppearance.themeMode, decodedAppearance.wallpaperFade], ['mist', 'serif', 1.1, 'dark', 40]);
    const video = VideoShare(sourceUrl: 'https://v.douyin.com/abc/', title: '标题', author: '作者', platform: 'douyin', kind: 'video');
    final decodedVideo = roundTrip(video) as VideoShare;
    expect([decodedVideo.sourceUrl, decodedVideo.title, decodedVideo.author, decodedVideo.kind], ['https://v.douyin.com/abc/', '标题', '作者', 'video']);
  });

  test('不认识的类型或更高版本落到 UnknownShare，不抛错', () {
    expect(decodeShareCard({'type': 'timetable_vote', 'version': 1, 'body': {}}), isA<UnknownShare>());
    expect(decodeShareCard({'type': 'schedule', 'version': 2, 'body': {}}), isA<UnknownShare>());
    expect(shareCardSummary(const UnknownShare(type: 'x', version: 1)), contains('更新应用'));
  });

  test('外部输入边界：结构、范围、课表规则不符一律 ShareCardException', () {
    Map<String, Object?> schedule() => jsonDecode(jsonEncode(encodeShareCard(sampleSchedule()))) as Map<String, Object?>;
    Map<String, Object?> body(Map<String, Object?> card) => card['body'] as Map<String, Object?>;
    final cases = <String, Map<String, Object?>>{
      '不是对象': {'type': 'schedule', 'version': 1, 'body': 'x'},
      '开学日格式': schedule()..update('body', (value) => {...value as Map, 'termStartDate': '2026-13-40'}),
      '星期越界': () {
        final card = schedule();
        (((body(card)['courses'] as List).first as Map)['meetings'] as List).first['weekday'] = 8;
        return card;
      }(),
      '作息时刻': () {
        final card = schedule();
        ((body(card)['bells'] as List).first as Map)['start'] = '25:00';
        return card;
      }(),
      '作息节次重复': () {
        final card = schedule();
        ((body(card)['bells'] as List)[1] as Map)['period'] = 1;
        return card;
      }(),
      '课程名为空': () {
        final card = schedule();
        ((body(card)['courses'] as List).first as Map)['courseName'] = ' ';
        return card;
      }(),
      '课程过多': () {
        final card = schedule();
        body(card)['courses'] = List.filled(501, (body(card)['courses'] as List).first);
        return card;
      }(),
      '视频链接非 http': {'type': 'video', 'version': 1, 'body': {'sourceUrl': 'javascript:alert(1)', 'title': '', 'author': '', 'platform': '', 'kind': 'video'}},
      '视频类型未知': {'type': 'video', 'version': 1, 'body': {'sourceUrl': 'https://a.com/x', 'title': '', 'author': '', 'platform': '', 'kind': 'live'}},
      '壁纸透明度越界': {'type': 'appearance', 'version': 1, 'body': {'paletteId': 'mist', 'fontId': 'maple', 'scale': 1, 'themeMode': 'system', 'glassMode': 'auto', 'wallpaperBlur': 0, 'wallpaperFade': 101}},
    };
    for (final entry in cases.entries) {
      expect(() => decodeShareCard(entry.value), throwsA(isA<ShareCardException>()), reason: entry.key);
    }
  });

  test('多余字段（如旧版的封面）被忽略，卡片仍可用', () {
    final card = decodeShareCard({'type': 'video', 'version': 1, 'body': {'sourceUrl': 'https://a.com/x', 'title': 't', 'author': '', 'platform': '', 'kind': 'gallery', 'coverUrl': 'http://a.com/c.jpg'}}) as VideoShare;
    expect(card.kind, 'gallery');
    expect(card.toBody().containsKey('coverUrl'), isFalse);
  });

  test('列表预览文案', () {
    expect(shareCardSummary(sampleSchedule()), '[课表] 2026-2027学年第一学期');
    expect(shareCardSummary(const VideoShare(sourceUrl: 'https://a.com', title: '', author: '', platform: '', kind: 'video')), '[视频] 作品分享');
  });
}
