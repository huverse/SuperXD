import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

const chaoxingPreSignUri = 'https://mobilelearn.chaoxing.com/newsign/preSign';
const chaoxingSignUri = 'https://mobilelearn.chaoxing.com/pptSign/stuSignajax';
const chaoxingCheckSignCodeUri =
    'https://mobilelearn.chaoxing.com/widget/sign/pcStuSignController/checkSignCode';

enum ChaoxingPreSignStatus { readyToSign, alreadySigned, expired }

class ChaoxingSignSubmission {
  const ChaoxingSignSubmission({
    required this.activity,
    this.activeId,
    this.signCode,
    this.location,
    this.enc,
    this.objectId,
    this.captchaValidate,
    this.enc2,
    this.faceObjectId,
    this.faceEnc,
    this.tightenLocation = false,
  });
  final ChaoxingActivity activity;

  // 二维码里带的活动号优先：老师当场刷新的码可能指向另一个活动。
  final int? activeId;

  // 签到码或手势序列码。
  final String? signCode;
  final ChaoxingLocation? location;

  // 二维码里的 enc。
  final String? enc;

  // 拍照签到上传后的云盘 objectId。
  final String? objectId;

  // 过了滑块验证码拿到的 validate，以及上一次提交要求带上的 enc2。
  final String? captchaValidate;
  final String? enc2;
  final String? faceObjectId;
  final String? faceEnc;

  // 位置第一次被判超范围时收紧随机偏移再试一次：偏移量本身可能刚好把人推出边界。
  final bool tightenLocation;

  ChaoxingSignSubmission change({
    ChaoxingLocation? location,
    String? captchaValidate,
    String? enc2,
    bool? tightenLocation,
  }) => ChaoxingSignSubmission(
    activity: activity,
    activeId: activeId,
    signCode: signCode,
    location: location ?? this.location,
    enc: enc,
    objectId: objectId,
    captchaValidate: captchaValidate ?? this.captchaValidate,
    enc2: enc2 ?? this.enc2,
    faceObjectId: faceObjectId,
    faceEnc: faceEnc,
    tightenLocation: tightenLocation ?? this.tightenLocation,
  );
}

sealed class ChaoxingSignOutcome {
  const ChaoxingSignOutcome();
}

class ChaoxingSignSucceeded extends ChaoxingSignOutcome {
  const ChaoxingSignSucceeded({this.late = false});
  final bool late;
}

class ChaoxingSignNeedsCaptcha extends ChaoxingSignOutcome {
  const ChaoxingSignNeedsCaptcha(this.enc2);
  final String enc2;
}

// preSign 返回的是网页，签到状态只能从页面里认。
final _primaryAttendPattern = RegExp(r'"primaryAttend"\s*:\s*\{[^{}]*?"status"\s*:\s*(\d+)');
final _signStatusPattern = RegExp(r'signstatus\s*=\s*(\d+)');
const _signedStatuses = {1, 2, 3, 9};

ChaoxingPreSignStatus chaoxingPreSignStatus(String html) {
  if (html.contains('校验失败，未查询到活动数据')) {
    throw const ChaoxingFailure(ChaoxingFailureCode.noPermission, '你的账号不在该班级里');
  }
  if (html.contains('下次早点哦')) return ChaoxingPreSignStatus.expired;
  final matched = _primaryAttendPattern.firstMatch(html) ?? _signStatusPattern.firstMatch(html);
  final status = int.tryParse(matched?.group(1) ?? '');
  return status != null && _signedStatuses.contains(status)
      ? ChaoxingPreSignStatus.alreadySigned
      : ChaoxingPreSignStatus.readyToSign;
}

// 提交结果是一段纯文本，按前缀分支；认不出的按服务端错误处理。
ChaoxingSignOutcome chaoxingSignOutcome(String body) {
  final text = body.trim();
  if (text == 'success2') return const ChaoxingSignSucceeded(late: true);
  if (text == 'success') return const ChaoxingSignSucceeded();
  if (text == '签到失败，请重新扫描。') {
    throw const ChaoxingFailure(ChaoxingFailureCode.qrCodeExpired, '二维码已过期，请重新扫码');
  }
  if (text == '您已签到过了') {
    throw const ChaoxingFailure(ChaoxingFailureCode.alreadySigned, '已经签到过了');
  }
  if (text.startsWith('validate')) {
    const prefix = 'validate_';
    return ChaoxingSignNeedsCaptcha(text.startsWith(prefix) ? text.substring(prefix.length) : '');
  }
  if (text.startsWith('checkFace_')) {
    throw ChaoxingFailure(ChaoxingFailureCode.faceRequired, '这次签到需要人脸识别', payload: text.substring('checkFace_'.length));
  }
  if (text.startsWith('[face]')) {
    throw ChaoxingFailure(ChaoxingFailureCode.faceRequired, '人脸识别未通过', payload: text.substring('[face]'.length));
  }
  if (text.startsWith('errorLocation')) {
    final parts = text.split('_');
    final distance = parts.length > 1 ? parts[1] : null;
    throw ChaoxingFailure(
      ChaoxingFailureCode.wrongPosition,
      distance == null ? '位置不在签到范围内' : '位置不在签到范围内，距离签到点约 $distance 米',
      payload: distance,
    );
  }
  throw ChaoxingFailure(ChaoxingFailureCode.server, text.isEmpty ? '签到失败，请稍后重试' : text);
}

Uri chaoxingPreSignRequestUri({required ChaoxingActivity activity, required ChaoxingAccount account}) =>
    Uri.parse(chaoxingPreSignUri).replace(
      queryParameters: {
        'courseId': '${activity.courseId}',
        'classId': '${activity.classId}',
        'activePrimaryId': '${activity.activeId}',
        'general': '1',
        'sys': '1',
        'ls': '1',
        'appType': '15',
        'uid': '${account.puid}',
        'isTeacherViewOpen': '0',
      },
    );

Uri chaoxingSignRequestUri({
  required ChaoxingAccount account,
  required ChaoxingSignSubmission submission,
}) {
  final activity = submission.activity;
  final query = <String, String>{
    'activeId': '${submission.activeId ?? activity.activeId}',
    'courseId': '${activity.courseId}',
    'uid': '${account.puid}',
    'name': account.name,
    'fid': '${account.fid}',
    'appType': '15',
    'clientip': '',
    'deviceCode': account.deviceCode,
    'vpProbability': '-1',
    'vpStrategy': '',
    ..._signTypeParameters(submission),
  };
  final enc2 = submission.enc2;
  if (enc2 != null && enc2.isNotEmpty) query['enc2'] = enc2;
  final captchaValidate = submission.captchaValidate;
  if (captchaValidate != null && captchaValidate.isNotEmpty) query['validate'] = captchaValidate;
  final faceObjectId = submission.faceObjectId;
  if (faceObjectId != null && faceObjectId.isNotEmpty) {
    query['currentFaceId'] = faceObjectId;
    query['ifCFP'] = '0';
    query['faceEnc'] = submission.faceEnc ?? '';
    query['faceCode'] = '';
    query['faceEncAid'] = '';
  }
  return Uri.parse(chaoxingSignUri).replace(queryParameters: query);
}

Map<String, String> _signTypeParameters(ChaoxingSignSubmission submission) {
  final location = submission.location;
  final position = location == null
      ? const <String, String>{'latitude': '-1', 'longitude': '-1'}
      : _positionParameters(location, submission.tightenLocation);
  return switch (submission.activity.signType) {
    ChaoxingSignType.location => _locationParameters(
      location ?? _fail('位置签到需要先选签到位置'),
      submission.tightenLocation,
    ),
    ChaoxingSignType.password || ChaoxingSignType.gesture => {
      ...position,
      'signCode': submission.signCode ?? _fail('请先填写签到码'),
    },
    ChaoxingSignType.qrCode => {...position, 'enc': submission.enc ?? _fail('请先扫描签到二维码')},
    ChaoxingSignType.photo => {
      'latitude': '-1',
      'longitude': '-1',
      'useragent': '',
      if (submission.objectId != null && submission.objectId!.isNotEmpty) 'objectId': submission.objectId!,
    },
  };
}

// 提交时的坐标一律先换算成 BD-09 再按小范围随机偏移；地图给的是 GCJ-02，收藏里两种都可能存着。
ChaoxingLocation _submittedLocation(ChaoxingLocation place, bool tighten) =>
    place.randomized(range: tighten ? chaoxingLocationTightRange : chaoxingLocationRange);

Map<String, String> _positionParameters(ChaoxingLocation place, bool tighten) {
  final position = _submittedLocation(place, tighten);
  return {
    'latitude': position.formattedLatitude,
    'longitude': position.formattedLongitude,
    'location': position.payload(mock: false),
    'locationResult': position.payload(mock: true),
  };
}

// 位置签到只带 locationResult（含 mockData），不重复带 location。
Map<String, String> _locationParameters(ChaoxingLocation place, bool tighten) {
  final position = _submittedLocation(place, tighten);
  return {
    'latitude': position.formattedLatitude,
    'longitude': position.formattedLongitude,
    'address': position.address,
    'ifTiJiao': '1',
    'locationResult': position.payload(mock: true),
  };
}

Never _fail(String message) => throw ChaoxingFailure(ChaoxingFailureCode.invalidInput, message);

Future<ChaoxingPreSignStatus> chaoxingPreSign(ChaoxingClient client, ChaoxingActivity activity) async {
  final response = await client.http.postForm(
    chaoxingPreSignRequestUri(activity: activity, account: client.account!),
    chaoxingFormBody({'ext': activity.ext}),
  );
  return chaoxingPreSignStatus(response.body);
}

Future<ChaoxingSignResult> chaoxingSubmit(ChaoxingClient client, ChaoxingSignSubmission submission) async {
  final response = await client.http.get(
    chaoxingSignRequestUri(account: client.account!, submission: submission),
    timeout: const Duration(seconds: 25),
  );
  return switch (chaoxingSignOutcome(response.body)) {
    ChaoxingSignSucceeded(:final late) => ChaoxingSignResult(late: late),
    ChaoxingSignNeedsCaptcha(:final enc2) => throw ChaoxingFailure(
      ChaoxingFailureCode.captchaRequired,
      '这次签到需要先完成安全验证',
      payload: enc2,
    ),
  };
}

// 签到码与手势码先本地校验一次，省掉必然失败的提交。
Future<bool> chaoxingCheckSignCode(
  ChaoxingClient client, {
  required int activeId,
  required String signCode,
}) async {
  final response = await client.http.get(
    Uri.parse(chaoxingCheckSignCodeUri).replace(
      queryParameters: {'activeId': '$activeId', 'signCode': signCode},
    ),
  );
  return chaoxingInt(chaoxingJson(response.body)['result']) == 1;
}
