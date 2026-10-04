import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/week.dart';

// 功能性私信的分享卡片：每种卡片有类型名与版本号，收到不认识的类型或更高版本时显示“请更新应用”，不崩溃。
// 卡片来自好友设备，属于外部输入：解码一律走 decodeShareCard 做边界校验，失败抛 ShareCardException。
// 新增卡片类型：在这里加子类与编解码，再在页面 share_card_view.dart 加渲染；旧客户端会落到 UnknownShare。

class ShareCardException implements Exception {
  const ShareCardException(this.message);
  final String message;
  @override
  String toString() => message;
}

sealed class ShareCard {
  const ShareCard();
  String get type;
  int get version;
  Map<String, Object?> toBody();
}

// 课表快照：发送时的某学期课表、开学日与作息。接收方只读查看，可与自己的课表对比共同空闲，不覆盖自己的课表。
class ScheduleShare extends ShareCard {
  const ScheduleShare({required this.term, required this.courses, required this.bells, this.termStartDate});
  static const typeName = 'schedule';
  final TermRef term;
  final String? termStartDate;
  final List<CourseRecord> courses;
  final List<BellPeriod> bells;
  @override
  String get type => typeName;
  @override
  int get version => 1;

  @override
  Map<String, Object?> toBody() => {
    'term': term.toJson(),
    'termStartDate': termStartDate,
    // localId 是随机 uuid，不含个人信息；自建课程靠它区分同名课，须一并发出，否则接收方校验报“课程标识重复”。
    'courses': [for (final course in courses) course.toJson()],
    'bells': [for (final bell in bells) {'period': bell.period, 'dayPart': bell.dayPart, 'dayPartCode': bell.dayPartCode, 'start': bell.start, 'end': bell.end}],
  };
}

// 界面配置：配色、字体、字号、深浅色、玻璃效果与壁纸模糊透明度；不含壁纸图片本身。取值是否受支持由接收方的显示设置判定。
class AppearanceShare extends ShareCard {
  const AppearanceShare({
    required this.paletteId,
    required this.fontId,
    required this.scale,
    required this.themeMode,
    required this.glassMode,
    required this.wallpaperBlur,
    required this.wallpaperFade,
  });
  static const typeName = 'appearance';
  final String paletteId;
  final String fontId;
  final double scale;
  final String themeMode;
  final String glassMode;
  final int wallpaperBlur;
  final int wallpaperFade;
  @override
  String get type => typeName;
  @override
  int get version => 1;

  @override
  Map<String, Object?> toBody() => {
    'paletteId': paletteId,
    'fontId': fontId,
    'scale': scale,
    'themeMode': themeMode,
    'glassMode': glassMode,
    'wallpaperBlur': wallpaperBlur,
    'wallpaperFade': wallpaperFade,
  };
}

// 短视频：只分享作品原链接与展示信息，不分享会过期的媒体直链；接收方打开时经自己同意的解析来源重新解析。
class VideoShare extends ShareCard {
  const VideoShare({required this.sourceUrl, required this.title, required this.author, required this.platform, required this.kind, this.coverUrl});
  static const typeName = 'video';
  final String sourceUrl;
  final String title;
  final String author;
  final String platform;
  // video 或 gallery。
  final String kind;
  final String? coverUrl;
  @override
  String get type => typeName;
  @override
  int get version => 1;

  @override
  Map<String, Object?> toBody() => {'sourceUrl': sourceUrl, 'title': title, 'author': author, 'platform': platform, 'kind': kind, 'coverUrl': coverUrl};
}

// 本版本不认识的卡片：原样保留类型与版本，界面提示更新应用。
class UnknownShare extends ShareCard {
  const UnknownShare({required this.type, required this.version});
  @override
  final String type;
  @override
  final int version;
  @override
  Map<String, Object?> toBody() => const {};
}

Map<String, Object?> encodeShareCard(ShareCard card) {
  if (card is UnknownShare) throw const ShareCardException('不能发送未知卡片');
  return {'type': card.type, 'version': card.version, 'body': card.toBody()};
}

ShareCard decodeShareCard(Object? json) {
  final map = _map(json, '卡片');
  final type = _text(map['type'], '卡片类型', max: 40);
  final version = _integer(map['version'], '卡片版本', min: 1, max: 1 << 30);
  final body = _map(map['body'], '卡片内容');
  return switch (type) {
    ScheduleShare.typeName when version == 1 => _schedule(body),
    AppearanceShare.typeName when version == 1 => _appearance(body),
    VideoShare.typeName when version == 1 => _video(body),
    _ => UnknownShare(type: type, version: version),
  };
}

// 消息列表里的一行预览。
String shareCardSummary(ShareCard card) => switch (card) {
  ScheduleShare(:final term) => '[课表] ${term.label.isEmpty ? term.key : term.label}',
  AppearanceShare() => '[界面配置]',
  VideoShare(:final title) => '[视频] ${title.isEmpty ? '作品分享' : title}',
  UnknownShare() => '[新版本消息] 请更新应用后查看',
};

ScheduleShare _schedule(Map<String, Object?> body) {
  final termJson = _map(body['term'], '学期');
  final term = TermRef(xn: _text(termJson['xn'], '学年', max: 40), xq: _text(termJson['xq'], '学期', max: 40), label: _text(termJson['label'], '学期名称', max: 100, allowEmpty: true));
  final start = body['termStartDate'];
  String? termStartDate;
  if (start != null) {
    termStartDate = _text(start, '开学日', max: 10);
    try {
      parseIsoDate(termStartDate);
    } on FormatException {
      throw const ShareCardException('开学日格式不正确');
    }
  }
  final courseList = _list(body['courses'], '课程', max: maxScheduleCourses);
  final List<CourseRecord> courses;
  try {
    courses = [
      for (final item in courseList) _course(_map(item, '课程')),
    ];
    validateSchedule(courses);
  } on ScheduleValidation catch (error) {
    throw ShareCardException(error.message);
  }
  final bellList = _list(body['bells'], '作息', max: maxSchedulePeriods);
  final bells = <BellPeriod>[];
  final periods = <int>{};
  for (final item in bellList) {
    final bell = _map(item, '作息');
    final period = _integer(bell['period'], '节次', min: 1, max: maxSchedulePeriods);
    final startText = _text(bell['start'], '开始时刻', max: 5), endText = _text(bell['end'], '结束时刻', max: 5);
    if (!periods.add(period) || clockMinutes(startText) == null || clockMinutes(endText) == null) throw const ShareCardException('作息格式不正确');
    bells.add(BellPeriod(period: period, dayPart: _text(bell['dayPart'], '时段', max: 20, allowEmpty: true), dayPartCode: _text(bell['dayPartCode'], '时段代码', max: 20, allowEmpty: true), start: startText, end: endText));
  }
  bells.sort((first, second) => first.period.compareTo(second.period));
  return ScheduleShare(term: term, termStartDate: termStartDate, courses: courses, bells: bells);
}

CourseRecord _course(Map<String, Object?> json) {
  final credit = json['credit'];
  if (credit != null && credit is! num) throw const ShareCardException('学分格式不正确');
  return CourseRecord(
    courseCode: _text(json['courseCode'], '课程代码', max: 100, allowEmpty: true),
    courseName: _text(json['courseName'], '课程名称', max: 200),
    sectionId: _text(json['sectionId'], '课程标识', max: 200, allowEmpty: true),
    credit: credit as num?,
    teacherName: _text(json['teacherName'], '教师', max: 200, allowEmpty: true),
    localId: json['localId'] == null ? null : _text(json['localId'], '课程标识', max: 64),
    meetings: [
      for (final item in _list(json['meetings'], '上课时段', max: maxCourseMeetings))
        _meeting(_map(item, '上课时段')),
    ],
  );
}

CourseMeeting _meeting(Map<String, Object?> json) => CourseMeeting(
  weekday: _integer(json['weekday'], '星期', min: 1, max: 7),
  periodStart: _integer(json['periodStart'], '开始节次', min: 1, max: maxSchedulePeriods),
  periodEnd: _integer(json['periodEnd'], '结束节次', min: 1, max: maxSchedulePeriods),
  place: _text(json['place'], '地点', max: 200, allowEmpty: true),
  weeks: [for (final week in _list(json['weeks'], '周次', max: maxScheduleWeeks)) _integer(week, '周次', min: 1, max: maxScheduleWeeks)],
  parity: 'all',
);

AppearanceShare _appearance(Map<String, Object?> body) {
  final scale = body['scale'];
  if (scale is! num || !scale.isFinite) throw const ShareCardException('字号格式不正确');
  return AppearanceShare(
    paletteId: _text(body['paletteId'], '配色', max: 32),
    fontId: _text(body['fontId'], '字体', max: 32),
    scale: scale.toDouble(),
    themeMode: _text(body['themeMode'], '深浅色', max: 32),
    glassMode: _text(body['glassMode'], '玻璃效果', max: 32),
    wallpaperBlur: _integer(body['wallpaperBlur'], '壁纸模糊', min: 0, max: 100),
    wallpaperFade: _integer(body['wallpaperFade'], '壁纸透明度', min: 0, max: 100),
  );
}

VideoShare _video(Map<String, Object?> body) {
  final sourceUrl = _text(body['sourceUrl'], '作品链接', max: 8192);
  final uri = Uri.tryParse(sourceUrl);
  if (uri == null || !uri.isScheme('https') && !uri.isScheme('http') || uri.host.isEmpty) throw const ShareCardException('作品链接不正确');
  final kind = _text(body['kind'], '作品类型', max: 20);
  if (kind != 'video' && kind != 'gallery') throw const ShareCardException('作品类型不正确');
  final cover = body['coverUrl'];
  String? coverUrl;
  if (cover != null) {
    coverUrl = _text(cover, '封面', max: 8192);
    // 封面只接受 https，其余忽略，不影响卡片。
    if (Uri.tryParse(coverUrl)?.isScheme('https') != true) coverUrl = null;
  }
  return VideoShare(
    sourceUrl: sourceUrl,
    title: _text(body['title'], '标题', max: 500, allowEmpty: true),
    author: _text(body['author'], '作者', max: 200, allowEmpty: true),
    platform: _text(body['platform'], '平台', max: 50, allowEmpty: true),
    kind: kind,
    coverUrl: coverUrl,
  );
}

Map<String, Object?> _map(Object? value, String name) {
  if (value is! Map) throw ShareCardException('$name格式不正确');
  return value.cast<String, Object?>();
}

List<Object?> _list(Object? value, String name, {required int max}) {
  if (value is! List) throw ShareCardException('$name格式不正确');
  if (value.length > max) throw ShareCardException('$name数量超过上限');
  return value;
}

String _text(Object? value, String name, {required int max, bool allowEmpty = false}) {
  if (value is! String || value.length > max || !allowEmpty && value.trim().isEmpty) throw ShareCardException('$name格式不正确');
  return value;
}

int _integer(Object? value, String name, {required int min, required int max}) {
  if (value is! int || value < min || value > max) throw ShareCardException('$name格式不正确');
  return value;
}
