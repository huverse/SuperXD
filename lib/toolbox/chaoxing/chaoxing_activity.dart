import 'dart:convert';

import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

const chaoxingCourseListUri = 'https://mooc1-api.chaoxing.com/mycourse/backclazzdata?view=json&rss=1';
const chaoxingActiveListUri = 'https://mobilelearn.chaoxing.com/v2/apis/active/student/activelist';
const chaoxingActiveInfoUri = 'https://mobilelearn.chaoxing.com/v2/apis/active/getPPTActiveInfo';

// 签到类活动的活动类型；其余类型（作业、讨论等）不在这里处理。
const chaoxingSignActivityTypes = {2, 74};

Future<List<ChaoxingCourse>> chaoxingCourses(ChaoxingClient client) async =>
    chaoxingCourseList(await _courseChannels(client));

Future<List<Object?>> _courseChannels(ChaoxingClient client) async {
  final response = await client.http.get(Uri.parse(chaoxingCourseListUri));
  final result = chaoxingJson(response.body);
  chaoxingCheckSession(result);
  final channelList = result['channelList'];
  if (channelList is! List) {
    throw const ChaoxingFailure(ChaoxingFailureCode.invalidResponse, '课程列表解析失败');
  }
  return channelList;
}

// 课程频道里只认带 cataName 的「课程」条目（文件夹等别的频道没有），与学习通客户端一致。
List<ChaoxingCourse> chaoxingCourseList(List<Object?> channelList) {
  final courses = <ChaoxingCourse>[];
  for (final channel in channelList) {
    if (channel is! Map || !channel.containsKey('cataName')) continue;
    final content = channel['content'];
    if (content is! Map) continue;
    final data = (content['course'] as Map?)?['data'];
    if (data is! List || data.isEmpty) continue;
    final course = data.first;
    if (course is! Map) continue;
    final courseId = chaoxingInt(course['id']);
    final classId = chaoxingInt(content['id']);
    if (courseId == 0 || classId == 0) continue;
    courses.add(
      ChaoxingCourse(
        courseId: courseId,
        classId: classId,
        name: chaoxingString(course['name']),
        teacher: chaoxingString(course['teacherfactor']),
        cover: chaoxingString(course['imageurl']),
        schools: chaoxingString(course['schools']),
      ),
    );
  }
  return courses;
}

// 签到前确认这个账号确实在该班级里：查不到课程列表（会话问题）时返回空，交给 preSign 去判断。
// 「在」的结论按会话缓存（同一场签到打开时查一次、提交时再查一次，多人时每人都查）；
// 「不在」不缓存，照样重拉一次，免得刚加进班级的人被旧结果拦下。
Future<bool?> chaoxingClassValid(ChaoxingClient client, int classId) async {
  if (client.classIds?.contains(classId) ?? false) return true;
  final response = await client.http.get(Uri.parse(chaoxingCourseListUri));
  final result = chaoxingJson(response.body);
  final channelList = result['channelList'];
  if (chaoxingInt(result['result']) == 0 || channelList is! List) return null;
  final classIds = {
    for (final channel in channelList)
      if (channel is Map && channel['content'] is Map) chaoxingInt((channel['content'] as Map)['id']),
  };
  client.classIds = classIds;
  return classIds.contains(classId);
}

// 强制签到给别的账号签时，按课程号找他自己所在的班级（同一门课可能分在不同班）；找不到返回空，沿用原班级。
Future<int?> chaoxingClassIdOfCourse(ChaoxingClient client, int courseId) async {
  final courses = chaoxingCourseList(await _courseChannels(client));
  return courses.where((course) => course.courseId == courseId).firstOrNull?.classId;
}

Future<List<ChaoxingActivity>> chaoxingActivities(ChaoxingClient client, ChaoxingCourse course) async {
  final response = await client.http.get(
    Uri.parse(chaoxingActiveListUri).replace(
      queryParameters: {
        'fid': '0',
        'showNotStartedActive': '0',
        'courseId': '${course.courseId}',
        'classId': '${course.classId}',
      },
    ),
  );
  final data = chaoxingData(response.body);
  final activeList = data['activeList'];
  if (activeList is! List) {
    throw const ChaoxingFailure(ChaoxingFailureCode.invalidResponse, '活动列表解析失败');
  }
  // preSign 要回传的 ext 是活动列表响应 data 级别的 ext（同一课程的全部活动共用），不是每条活动自己的字段。
  final ext = chaoxingExtText(data['ext']);
  final activities = <ChaoxingActivity>[];
  for (final item in activeList) {
    if (item is! Map) continue;
    final activity = chaoxingActivity(item.cast<String, Object?>(), course, ext: ext);
    if (activity != null) activities.add(activity);
  }
  activities.sort((first, second) => second.startTime.compareTo(first.startTime));
  return activities;
}

// 认不出的签到类型（otherId 不在已知的 0/2/3/4/5）也保留入列、标成 unknown（对齐参考项目）：
// 点开签到弹层时详情里通常能认出来（群聊那边就是这个路子），静默丢掉会让活动凭空消失。
ChaoxingActivity? chaoxingActivity(Map<String, Object?> json, ChaoxingCourse course, {required String ext}) {
  if (!chaoxingSignActivityTypes.contains(chaoxingInt(json['type']))) return null;
  final signType = ChaoxingSignType.fromCode(chaoxingString(json['otherId'])) ?? ChaoxingSignType.unknown;
  final activeId = chaoxingInt(json['id']);
  if (activeId == 0) return null;
  return ChaoxingActivity(
    activeId: activeId,
    courseId: course.courseId,
    classId: course.classId,
    title: chaoxingString(json['nameOne'], fallback: '签到'),
    // 标题行用课程名：真实数据里 nameFour 是「09-23 14:22」这样的时间串，直接当标题会跟下面的
    // 结束时间重复，也看不出是哪门课；nameFour 只在拿不到课程名时兜底。
    subtitle: course.name.isNotEmpty ? course.name : chaoxingString(json['nameFour']),
    signType: signType,
    startTime: chaoxingTimestamp(json['startTime']) ?? DateTime.now().toUtc(),
    endTime: chaoxingTimestamp(json['endTime']),
    status: chaoxingInt(json['status']),
    userStatus: chaoxingInt(json['userStatus']),
    ext: ext,
  );
}

// 扩展字段要原样回传给 preSign；服务端有时给对象，有时给字符串。
String chaoxingExtText(Object? value) => value is String ? value : jsonEncode(value ?? const <String, Object?>{});

Future<ChaoxingActiveInfo> chaoxingActiveInfo(ChaoxingClient client, int activeId) async {
  final response = await client.http.get(
    Uri.parse(chaoxingActiveInfoUri).replace(queryParameters: {'activeId': '$activeId'}),
  );
  final data = chaoxingData(response.body);
  return chaoxingActiveInfoFrom(data);
}

ChaoxingActiveInfo chaoxingActiveInfoFrom(Map<String, Object?> data) => ChaoxingActiveInfo(
  signType: ChaoxingSignType.fromCode(chaoxingString(data['otherId'])),
  title: chaoxingString(data['nameOne']),
  startTime: chaoxingTimestamp(data['starttime']),
  endTime: chaoxingTimestamp(data['endTime']),
  needCaptcha: chaoxingInt(data['ifNeedVCode']) == 1,
  needFace: chaoxingInt(data['openCheckFaceFlag']) == 1,
  needLocation: chaoxingInt(data['ifopenAddress']) == 1,
  needPhoto: chaoxingInt(data['ifphoto']) == 1,
  refreshQrCode: chaoxingInt(data['ifrefreshewm']) == 1,
  locationRange: chaoxingInt(data['locationRange']),
  locationLatitude: chaoxingDouble(data['locationLatitude']),
  locationLongitude: chaoxingDouble(data['locationLongitude']),
  signInId: chaoxingInt(data['signInId']) == 0 ? null : chaoxingInt(data['signInId']),
  signOutId: chaoxingInt(data['signOutId']) == 0 ? null : chaoxingInt(data['signOutId']),
  signOutPublishTime: chaoxingTimestamp(
    data['signOutPublishTimeStamp'],
    none: {chaoxingNoSignOutTimestamp, -1},
  ),
  signCodeLength: chaoxingInt(data['numberCount']),
);

// 课程与活动列表在会话失效时返回 result=0。
void chaoxingCheckSession(Map<String, Object?> json) {
  if (json.containsKey('result') && chaoxingInt(json['result']) == 0) {
    throw const ChaoxingFailure(ChaoxingFailureCode.sessionExpired, chaoxingSessionExpiredMessage);
  }
}

DateTime? chaoxingTimestamp(Object? value, {Set<int> none = const {}}) {
  final millis = chaoxingInt(value);
  if (millis <= 0 || none.contains(millis)) return null;
  // 服务端给的是秒级时间戳时按秒还原。
  return DateTime.fromMillisecondsSinceEpoch(millis < 100000000000 ? millis * 1000 : millis, isUtc: true);
}
