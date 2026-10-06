import 'dart:convert';

import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

const chaoxingCourseListUri = 'https://mooc1-api.chaoxing.com/mycourse/backclazzdata?view=json&rss=1';
const chaoxingActiveListUri = 'https://mobilelearn.chaoxing.com/v2/apis/active/student/activelist';
const chaoxingActiveInfoUri = 'https://mobilelearn.chaoxing.com/v2/apis/active/getPPTActiveInfo';

// 签到类活动的活动类型；其余类型（作业、讨论等）不在这里处理。
const chaoxingSignActivityTypes = {2, 74};

Future<List<ChaoxingCourse>> chaoxingCourses(ChaoxingClient client) async {
  final response = await client.http.get(Uri.parse(chaoxingCourseListUri));
  final result = chaoxingJson(response.body);
  chaoxingCheckSession(result);
  final channelList = result['channelList'];
  if (channelList is! List) {
    throw const ChaoxingFailure(ChaoxingFailureCode.invalidResponse, '课程列表解析失败');
  }
  final courses = <ChaoxingCourse>[];
  for (final channel in channelList) {
    if (channel is! Map) continue;
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
      ),
    );
  }
  return courses;
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
  final activities = <ChaoxingActivity>[];
  for (final item in activeList) {
    if (item is! Map) continue;
    final activity = chaoxingActivity(item.cast<String, Object?>(), course);
    if (activity != null) activities.add(activity);
  }
  activities.sort((first, second) => second.startTime.compareTo(first.startTime));
  return activities;
}

// 认不出的签到类型直接不入列，界面不会出现点不动的条目。
ChaoxingActivity? chaoxingActivity(Map<String, Object?> json, ChaoxingCourse course) {
  if (!chaoxingSignActivityTypes.contains(chaoxingInt(json['type']))) return null;
  final signType = ChaoxingSignType.fromCode(chaoxingString(json['otherId']));
  final activeId = chaoxingInt(json['id']);
  if (signType == null || activeId == 0) return null;
  return ChaoxingActivity(
    activeId: activeId,
    courseId: course.courseId,
    classId: course.classId,
    title: chaoxingString(json['nameOne'], fallback: signType.label),
    // 标题行用课程名：真实数据里 nameFour 是「09-23 14:22」这样的时间串，直接当标题会跟下面的
    // 结束时间重复，也看不出是哪门课；nameFour 只在拿不到课程名时兜底。
    subtitle: course.name.isNotEmpty ? course.name : chaoxingString(json['nameFour']),
    signType: signType,
    startTime: chaoxingTimestamp(json['startTime']) ?? DateTime.now().toUtc(),
    endTime: chaoxingTimestamp(json['endTime']),
    status: chaoxingInt(json['status']),
    userStatus: chaoxingInt(json['userStatus']),
    ext: chaoxingExtText(json['ext']),
  );
}

// 活动的扩展字段要原样回传给 preSign；服务端有时给对象，有时给字符串。
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
    throw const ChaoxingFailure(ChaoxingFailureCode.sessionExpired, '登录已过期，请重新登录');
  }
}

DateTime? chaoxingTimestamp(Object? value, {Set<int> none = const {}}) {
  final millis = chaoxingInt(value);
  if (millis <= 0 || none.contains(millis)) return null;
  // 服务端给的是秒级时间戳时按秒还原。
  return DateTime.fromMillisecondsSinceEpoch(millis < 100000000000 ? millis * 1000 : millis, isUtc: true);
}
