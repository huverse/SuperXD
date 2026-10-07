import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

const chaoxingPreSignUri = 'https://mobilelearn.chaoxing.com/newsign/preSign';
const chaoxingSignUri = 'https://mobilelearn.chaoxing.com/pptSign/stuSignajax';
const chaoxingCheckSignCodeUri =
    'https://mobilelearn.chaoxing.com/widget/sign/pcStuSignController/checkSignCode';
const chaoxingAnalysisUri = 'https://mobilelearn.chaoxing.com/pptSign/analysis?vs=1&DB_STRATEGY=RANDOM';
const chaoxingAnalysis2Uri = 'https://mobilelearn.chaoxing.com/pptSign/analysis2?DB_STRATEGY=RANDOM';

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
  const ChaoxingSignSucceeded();
}

class ChaoxingSignNeedsCaptcha extends ChaoxingSignOutcome {
  const ChaoxingSignNeedsCaptcha(this.enc2);
  final String enc2;
}

// preSign 返回的是网页，签到状态只能从页面里认。
final _primaryAttendPattern = RegExp(r'"primaryAttend"\s*:\s*\{[^{}]*?"status"\s*:\s*(\d+)');
final _signStatusPattern = RegExp(r'signstatus\s*=\s*(\d+)');
const _signedStatuses = {1, 2, 3, 9};

// analysis 页面里内嵌的一段 code，要原样交给 analysis2。
final _analysisCodePattern = RegExp(r"code='\+'([a-f0-9]+)'");

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
// success2 是「迟到或签到已结束」，学习通客户端按失败处理，这里一致；迟到与否另按活动截止时间判断。
ChaoxingSignOutcome chaoxingSignOutcome(String body) {
  final text = body.trim();
  if (text.startsWith('[face]')) {
    throw ChaoxingFailure(ChaoxingFailureCode.faceRequired, '人脸识别未通过', payload: text.substring('[face]'.length));
  }
  if (text == 'success2') {
    throw const ChaoxingFailure(ChaoxingFailureCode.expired, '迟到或签到已结束');
  }
  if (text == '签到失败，请重新扫描。') {
    throw const ChaoxingFailure(ChaoxingFailureCode.qrCodeExpired, '二维码已过期，请重新扫码');
  }
  if (text.startsWith('checkFace_')) {
    throw ChaoxingFailure(ChaoxingFailureCode.faceRequired, '这次签到需要人脸识别', payload: text.substring('checkFace_'.length));
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
  if (text == '您已签到过了') {
    throw const ChaoxingFailure(ChaoxingFailureCode.alreadySigned, '已经签到过了');
  }
  if (text.startsWith('validate')) {
    const prefix = 'validate_';
    return ChaoxingSignNeedsCaptcha(text.startsWith(prefix) ? text.substring(prefix.length) : '');
  }
  if (text == 'success') return const ChaoxingSignSucceeded();
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

// 各类型的提交参数逐项照学习通客户端（参数名、取值与顺序）：
// - 签到码/手势：坐标给了就带 latitude/longitude 与 location、locationResult，没给是 -1；
// - 位置：带 address、ifTiJiao=1、vp 两项与 locationResult，可叠加人脸；
// - 拍照：坐标固定 -1，带 useragent 空串与云盘 objectId（纯点击签到不带）；
// - 二维码：坐标固定 -1，位置只放在 location/locationResult 里，带 vp 两项，可叠加人脸。
Uri chaoxingSignRequestUri({
  required ChaoxingAccount account,
  required ChaoxingSignSubmission submission,
}) {
  final activity = submission.activity;
  final query = switch (activity.signType) {
    ChaoxingSignType.password || ChaoxingSignType.gesture => _codeParameters(account, submission),
    ChaoxingSignType.location => _locationParameters(account, submission),
    ChaoxingSignType.photo => _photoParameters(account, submission),
    ChaoxingSignType.qrCode => _qrCodeParameters(account, submission),
  };
  return Uri.parse(chaoxingSignUri).replace(queryParameters: query);
}

Map<String, String> _codeParameters(ChaoxingAccount account, ChaoxingSignSubmission submission) {
  final position = _submitted(submission);
  return {
    'activeId': '${submission.activity.activeId}',
    'courseId': '${submission.activity.courseId}',
    'uid': '${account.puid}',
    'clientip': '',
    'latitude': position?.formattedLatitude ?? '-1',
    'longitude': position?.formattedLongitude ?? '-1',
    'appType': '15',
    'fid': '${account.fid}',
    'name': account.name,
    'signCode': submission.signCode ?? _fail('请先填写签到码'),
    'deviceCode': account.deviceCode,
    if (position != null) 'location': position.payload(mock: false),
    if (position != null) 'locationResult': position.payload(mock: true),
    ..._enc2AndValidate(submission),
  };
}

Map<String, String> _locationParameters(ChaoxingAccount account, ChaoxingSignSubmission submission) {
  final position = _submitted(submission) ?? _fail('位置签到需要先选签到位置');
  return {
    'name': account.name,
    'address': position.address,
    'activeId': '${submission.activity.activeId}',
    'courseId': '${submission.activity.courseId}',
    'uid': '${account.puid}',
    'clientip': '',
    'latitude': '${position.latitude}',
    'longitude': '${position.longitude}',
    'fid': '${account.fid}',
    'appType': '15',
    'ifTiJiao': '1',
    if (_present(submission.captchaValidate)) 'validate': submission.captchaValidate!,
    'deviceCode': account.deviceCode,
    'vpProbability': '-1',
    'vpStrategy': '',
    if (_present(submission.enc2)) 'enc2': submission.enc2!,
    'locationResult': position.payload(mock: true),
    ..._faceParameters(submission),
  };
}

Map<String, String> _photoParameters(ChaoxingAccount account, ChaoxingSignSubmission submission) => {
  'activeId': '${submission.activity.activeId}',
  'courseId': '${submission.activity.courseId}',
  'uid': '${account.puid}',
  'clientip': '',
  'useragent': '',
  'latitude': '-1',
  'longitude': '-1',
  'appType': '15',
  'fid': '${account.fid}',
  if (_present(submission.objectId)) 'objectId': submission.objectId!,
  'name': account.name,
  if (_present(submission.captchaValidate)) 'validate': submission.captchaValidate!,
  'deviceCode': account.deviceCode,
  if (_present(submission.enc2)) 'enc2': submission.enc2!,
};

Map<String, String> _qrCodeParameters(ChaoxingAccount account, ChaoxingSignSubmission submission) {
  final position = _submitted(submission);
  return {
    'enc': submission.enc ?? _fail('请先扫描签到二维码'),
    'name': account.name,
    'activeId': '${submission.activeId ?? submission.activity.activeId}',
    'uid': '${account.puid}',
    'clientip': '',
    if (position != null) 'location': position.payload(mock: false),
    'latitude': '-1',
    'longitude': '-1',
    'fid': '${account.fid}',
    'appType': '15',
    'deviceCode': account.deviceCode,
    'vpProbability': '-1',
    'vpStrategy': '',
    'courseId': '${submission.activity.courseId}',
    ..._enc2AndValidate(submission),
    if (position != null) 'locationResult': position.payload(mock: true),
    ..._faceParameters(submission),
  };
}

Map<String, String> _enc2AndValidate(ChaoxingSignSubmission submission) => {
  if (_present(submission.enc2)) 'enc2': submission.enc2!,
  if (_present(submission.captchaValidate)) 'validate': submission.captchaValidate!,
};

// 人脸参数只有位置与二维码签到会带（学习通客户端只在这两类上做人脸）。
Map<String, String> _faceParameters(ChaoxingSignSubmission submission) => _present(submission.faceObjectId)
    ? {
        'currentFaceId': submission.faceObjectId!,
        'ifCFP': '0',
        'faceEnc': submission.faceEnc ?? '',
        'faceCode': '',
        'faceEncAid': '',
      }
    : const {};

bool _present(String? value) => value != null && value.isNotEmpty;

// 提交时的坐标一律先换算成 BD-09 再按小范围随机偏移；地图给的是 GCJ-02，收藏里几种都可能存着。
ChaoxingLocation? _submitted(ChaoxingSignSubmission submission) => submission.location?.randomized(
  range: submission.tightenLocation ? chaoxingLocationTightRange : chaoxingLocationRange,
);

Never _fail(String message) => throw ChaoxingFailure(ChaoxingFailureCode.invalidInput, message);

// preSign 之后紧跟 analysis → analysis2（学习通客户端打开签到页时的必经请求），再判断签到状态。
// 返回 302 或「校验失败」说明这个账号不在该班级。
Future<ChaoxingPreSignStatus> chaoxingPreSign(ChaoxingClient client, ChaoxingActivity activity) async {
  final response = await client.http.postForm(
    chaoxingPreSignRequestUri(activity: activity, account: client.account!),
    chaoxingFormBody({'ext': activity.ext}),
  );
  if (response.statusCode == 302) {
    throw const ChaoxingFailure(ChaoxingFailureCode.noPermission, '你的账号不在该班级里');
  }
  final status = chaoxingPreSignStatus(response.body);
  await chaoxingAnalysis(client, activity.activeId);
  return status;
}

// analysis 页面里抠不到 code 时只记日志不拦签到：这两步不返回业务结果，学习通改版换了页面也不该让签到整体失败。
Future<void> chaoxingAnalysis(ChaoxingClient client, int activeId) async {
  final page = await client.http.get(Uri.parse(chaoxingAnalysisUri).replace(
    queryParameters: {...Uri.parse(chaoxingAnalysisUri).queryParameters, 'aid': '$activeId'},
  ));
  final code = _analysisCodePattern.firstMatch(page.body)?.group(1);
  if (code == null) {
    campusLog('[Chaoxing] action=analysis errorType=code_missing');
    return;
  }
  await client.http.get(Uri.parse(chaoxingAnalysis2Uri).replace(
    queryParameters: {...Uri.parse(chaoxingAnalysis2Uri).queryParameters, 'code': code},
  ));
}

// 迟到按活动截止时间判断：截止之后才提交成功的就是迟到。
Future<ChaoxingSignResult> chaoxingSubmit(ChaoxingClient client, ChaoxingSignSubmission submission) async {
  final response = await client.http.get(
    chaoxingSignRequestUri(account: client.account!, submission: submission),
    timeout: const Duration(seconds: 25),
  );
  return switch (chaoxingSignOutcome(response.body)) {
    ChaoxingSignSucceeded() => ChaoxingSignResult(late: submission.activity.endedAt(DateTime.now().toUtc())),
    ChaoxingSignNeedsCaptcha(:final enc2) => throw ChaoxingFailure(
      ChaoxingFailureCode.captchaRequired,
      '这次签到需要先完成安全验证',
      payload: enc2,
    ),
  };
}

// 签到码与手势码先校验一次，省掉必然失败的提交。
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
