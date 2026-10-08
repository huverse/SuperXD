// 学习通签到的模型与错误码。所有外部响应先在这里收口成类型，页面只按错误码分支。

enum ChaoxingFailureCode {
  invalidInput,
  login,
  sessionExpired,
  noPermission,
  expired,
  alreadySigned,
  wrongPosition,
  captchaRequired,
  faceRequired,
  // checkFace_ 前缀：人脸校验没完成但拿到了续传用的 enc2，带着它重发即可，不算人脸未通过。
  faceCheck,
  qrCodeExpired,
  unsupported,
  unavailable,
  packNotFound,
  rateLimited,
  timeout,
  network,
  server,
  cancelled,
  invalidResponse,
}

class ChaoxingFailure implements Exception {
  const ChaoxingFailure(this.code, this.message, {this.retryAfter, this.payload, this.predicted = false, this.locationTightened = false});
  final ChaoxingFailureCode code;
  final String message;
  final Duration? retryAfter;

  // 服务端附带的原始信息：位置超范围的距离、需要验证码的 enc2、人脸态等。
  final String? payload;

  // 是签到前的检查（preSign 页面、班级检查）推断出来的，不是提交后学习通退回的；这类可以强制签到。
  final bool predicted;

  // 位置出界失败时，这场签到是否已在收紧偏移档（对齐参考项目）：刚收紧的第一次出界不停队，
  // 后面的人接着用收紧档签；收紧档仍出界才把余下的人全停。
  final bool locationTightened;

  @override
  String toString() => message;
}

// 多处共用的提示文案，改一处即全处生效。
const chaoxingSessionExpiredMessage = '登录已过期，请重新登录';
const chaoxingSignRetryMessage = '签到没完成，请稍后重试';
const chaoxingUnsupportedTypeMessage = '这个活动的签到类型暂不支持';
const chaoxingPhotoRequiredMessage = '这场签到要照片，请先选一张';
const chaoxingPhotoUnreadableMessage = '照片读取失败，请重新选择';
const chaoxingCaptchaLoadFailedMessage = '验证码加载失败，请重试';
const chaoxingNotPackTicketMessage = '这不是学习通代签二维码';
const chaoxingScanCancelledMessage = '扫码已取消';

// 一个人签到成功后的提示（迟到按截止时间判断）。
String chaoxingSignedText({required bool late}) => late ? '签到成功，不过已经迟到' : '签到成功';

enum ChaoxingSignType {
  photo('0', '拍照签到'),
  qrCode('2', '二维码签到'),
  gesture('3', '手势签到'),
  location('4', '位置签到'),
  password('5', '签到码签到'),

  // 活动列表里认不出的 otherId：先保留展示，点开签到时详情里通常能认出来（认不出就提示不支持）。
  unknown('', '签到');

  const ChaoxingSignType(this.code, this.label);
  final String code;
  final String label;

  static ChaoxingSignType? fromCode(String? code) {
    for (final type in values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

// 学校单位：一个学习通账号可能挂在多个单位下（学校、培训机构等），课程列表与签到都按所选单位走。
class ChaoxingUnit {
  const ChaoxingUnit({required this.fid, required this.name});
  final int fid;
  final String name;

  Map<String, Object?> toJson() => {'fid': fid, 'name': name};

  @override
  bool operator ==(Object other) => other is ChaoxingUnit && other.fid == fid && other.name == name;

  @override
  int get hashCode => Object.hash(fid, name);
}

class ChaoxingAccount {
  const ChaoxingAccount({
    required this.phoneNumber,
    required this.uid,
    required this.puid,
    required this.fid,
    required this.name,
    required this.deviceCode,
    this.schoolName = '',
    this.photoUrl = '',
    this.imPassword = '',
    this.clientId,
    this.units = const [],
  });
  final String phoneNumber;
  final int uid;
  final int puid;

  // 当前所选的学校单位；默认是用户信息里的主单位。
  final int fid;
  final String name;
  final String deviceCode;
  final String schoolName;
  final String photoUrl;
  final String imPassword;
  final String? clientId;
  final List<ChaoxingUnit> units;

  ChaoxingAccount change({int? fid, String? deviceCode, String? schoolName}) => ChaoxingAccount(
    phoneNumber: phoneNumber,
    uid: uid,
    puid: puid,
    fid: fid ?? this.fid,
    name: name,
    deviceCode: deviceCode ?? this.deviceCode,
    schoolName: schoolName ?? this.schoolName,
    photoUrl: photoUrl,
    imPassword: imPassword,
    clientId: clientId,
    units: units,
  );
}

class ChaoxingActivity {
  const ChaoxingActivity({
    required this.activeId,
    required this.courseId,
    required this.classId,
    required this.title,
    required this.subtitle,
    required this.signType,
    required this.startTime,
    required this.status,
    required this.userStatus,
    required this.ext,
    this.endTime,
  });
  final int activeId;
  final int courseId;
  final int classId;
  final String title;
  final String subtitle;
  final ChaoxingSignType signType;

  // 发起时刻；上游没给时为空，如实当作未知（不拿「现在」顶替，否则会被当成刚发起的签到）。
  final DateTime? startTime;
  final DateTime? endTime;
  final int status;

  // 列表给的签到状态只作参考：是否已签到只认 preSign 返回的页面状态。
  final int userStatus;

  // 原样回传给 preSign 的活动扩展字段。
  final String ext;

  // 进行中只认活动列表的 status（1 进行中），与学习通客户端一致；截止时间到了但老师没结束的仍算进行中。
  bool get ongoing => status == 1;

  bool endedAt(DateTime now) => endTime != null && now.isAfter(endTime!);

  ChaoxingActivity change({int? classId, ChaoxingSignType? signType}) => ChaoxingActivity(
    activeId: activeId,
    courseId: courseId,
    classId: classId ?? this.classId,
    signType: signType ?? this.signType,
    title: title,
    subtitle: subtitle,
    startTime: startTime,
    status: status,
    userStatus: userStatus,
    ext: ext,
    endTime: endTime,
  );

  // [人工决策-2026-10-06 23:16:39] 活动名与签到类型名相同时只显示一个：真实数据里活动名常常
  // 就是「二维码签到」这类，和类型名叠一起会重复成「二维码签到 · 二维码签到」。
  String get displayTitle => title == signType.label ? title : '$title · ${signType.label}';
}

// 活动列表的顺序：发起时刻新的在前，不知道发起时刻的排在后面；同一时刻（含都未知）按活动号新的在前，顺序稳定。
int chaoxingNewestFirst(ChaoxingActivity first, ChaoxingActivity second) {
  final firstStart = first.startTime;
  final secondStart = second.startTime;
  if (firstStart != null && secondStart == null) return -1;
  if (firstStart == null && secondStart != null) return 1;
  final byStart = firstStart == null ? 0 : secondStart!.compareTo(firstStart);
  return byStart != 0 ? byStart : second.activeId.compareTo(first.activeId);
}

class ChaoxingCourse {
  const ChaoxingCourse({
    required this.courseId,
    required this.classId,
    required this.name,
    this.teacher = '',
    this.cover = '',
    this.schools = '',
  });
  final int courseId;
  final int classId;
  final String name;
  final String teacher;
  final String cover;
  final String schools;
}

// 没有签退活动时服务端在 signOutPublishTimeStamp 里用这个值占位。
const chaoxingNoSignOutTimestamp = 4999;

enum ChaoxingSignOutState {
  none,
  // 本活动就是签退活动，要回主签到活动。
  signOutActivity,
  signOutPublished,
  signOutPending,
}

class ChaoxingActiveInfo {
  const ChaoxingActiveInfo({
    this.signType,
    this.title = '',
    this.startTime,
    this.endTime,
    this.needCaptcha = false,
    this.needFace = false,
    this.needLocation = false,
    this.needPhoto = false,
    this.refreshQrCode = false,
    this.locationRange = 0,
    this.locationLatitude,
    this.locationLongitude,
    this.signInId,
    this.signOutId,
    this.signOutPublishTime,
    this.signCodeLength = 0,
  });

  // 详情里带的类型与时间：从签到码跳到关联的签退活动时，靠这几个字段组出那个活动。
  final ChaoxingSignType? signType;
  final String title;
  final DateTime? startTime;
  final DateTime? endTime;
  final bool needCaptcha;
  final bool needFace;
  final bool needLocation;
  final bool needPhoto;
  final bool refreshQrCode;
  final int locationRange;
  final double? locationLatitude;
  final double? locationLongitude;

  // 非空表示本活动是签退活动，指向它的主签到活动。
  final int? signInId;
  final int? signOutId;
  final DateTime? signOutPublishTime;
  final int signCodeLength;

  ChaoxingSignOutState get signOutState {
    if (signInId != null) return ChaoxingSignOutState.signOutActivity;
    if (signOutPublishTime == null) return ChaoxingSignOutState.none;
    return signOutId == null ? ChaoxingSignOutState.signOutPending : ChaoxingSignOutState.signOutPublished;
  }

  // 关联活动号：本活动是签退活动时指主签到，否则是已发布的签退活动。
  int? get relatedActiveId => switch (signOutState) {
    ChaoxingSignOutState.signOutActivity => signInId,
    ChaoxingSignOutState.signOutPublished => signOutId,
    _ => null,
  };
}

// 签到结果：迟到按活动的截止时间判断（截止之后才提交成功的算迟到），与学习通客户端一致。
class ChaoxingSignResult {
  const ChaoxingSignResult({this.late = false});
  final bool late;
}
