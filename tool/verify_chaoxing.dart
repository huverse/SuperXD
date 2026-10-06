import 'dart:io';

import 'package:superxd/toolbox/chaoxing/chaoxing_activity.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_crypto.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_face.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_im.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_signer.dart';

// 学习通真实接口联调（手动，不进 CI），只在用户授权的账号上跑。
// 只做只读验证：登录、课程、活动、preSign 页面判定、活动详情、群聊与人物照片，都不改服务端状态。
// 凭据从参数给定的文件读入（phone=… 与 password=… 两行），不进命令行、不落库、不进仓库。
// 输出一律脱敏：不打印姓名、学号、课程名、群名与凭据。
// 运行：
//   dart run tool/verify_chaoxing.dart /path/to/secret [step]
// step 省略时跑全部；给了就只跑那一步（login 之后的步骤都要重新登录，登录端点慢，尽量一次跑完）。
Future<void> main(List<String> args) async {
  final secretPath = args.isEmpty ? '' : args.first;
  if (secretPath.isEmpty) {
    _log('failed reason=missing_secret_path usage=dart run tool/verify_chaoxing.dart <secret_file>');
    exitCode = 2;
    return;
  }
  final only = args.length > 1 ? args[1] : '';
  bool wants(String step) => only.isEmpty || only == step;

  final secret = <String, String>{};
  for (final line in File(secretPath).readAsLinesSync()) {
    final index = line.indexOf('=');
    if (index > 0) secret[line.substring(0, index).trim()] = line.substring(index + 1).trim();
  }
  final phone = secret['phone'] ?? '';
  final password = secret['password'] ?? '';
  if (phone.isEmpty || password.isEmpty) {
    _log('failed reason=secret_file_incomplete');
    exitCode = 2;
    return;
  }

  // 探针放宽超时：登录端点实测有过 30 秒才回，15 秒会误判成失败，那是超时策略问题不是协议问题。
  final http = ChaoxingHttp(timeout: const Duration(seconds: 60));
  try {
    _log('step=login');
    final watch = Stopwatch()..start();
    final client = await ChaoxingClient.signIn(http: http, phoneNumber: phone, password: password);
    final account = client.account!;
    _log(
      'login=ok ms=${watch.elapsedMilliseconds} uid=${_digits(account.uid)} puid=${_digits(account.puid)} '
      'fid=${account.fid} name=${_mask(account.name)} school=${_mask(account.schoolName)} '
      'clientId=${account.clientId == null ? 'none' : _mask(account.clientId!)} '
      'imPassword=${account.imPassword.isEmpty ? 'none' : 'len=${account.imPassword.length}'} '
      'cookies=${http.cookies.session.length}',
    );

    _log('step=sso');
    await _dumpSso(http);

    _log('step=cookies');
    for (final entry in http.cookies.session.entries) {
      _log('cookie ${entry.key}=len=${entry.value.length}');
    }

    if (wants('loginraw')) {
      _log('step=loginraw');
      final response = await http.postForm(
        Uri.parse(chaoxingLoginUri),
        chaoxingLoginBody(
          encryptedPhone: await chaoxingEncrypt(phone),
          encryptedPassword: await chaoxingEncrypt(password),
        ),
      );
      final json = chaoxingJson(response.body);
      _log('loginraw keys=${json.keys.join(',')}');
      for (final entry in json.entries) {
        _log('loginraw ${entry.key}=${_shape(entry.value)}');
      }
    }

    _log('step=courses');
    final courses = await chaoxingCourses(client);
    _log('courses=${courses.length}');
    for (final course in courses) {
      _log('course classId=${course.classId} name=${_mask(course.name)} teacher=${_mask(course.teacher)}');
    }

    _log('step=activities');
    final activities = <ChaoxingActivity>[];
    for (final course in courses) {
      try {
        activities.addAll(await chaoxingActivities(client, course));
      } on ChaoxingFailure catch (error) {
        _log('activities classId=${course.classId} failed code=${error.code.name} message=${error.message}');
      }
    }
    _log('activities_total=${activities.length} types=${_typeCounts(activities)}');

    // preSign 与详情都不改状态：对已结束的活动，preSign 只会回「下次早点哦」或已签到。
    if (wants('presign')) {
      _log('step=presign');
      for (final activity in activities.take(3)) {
        try {
          final status = await chaoxingPreSign(client, activity);
          _log('presign activeId=${activity.activeId} type=${activity.signType.code} status=${status.name}');
        } on ChaoxingFailure catch (error) {
          _log('presign activeId=${activity.activeId} failed code=${error.code.name} message=${error.message}');
        }
      }
    }

    if (wants('detail')) {
      _log('step=detail');
      for (final activity in activities.take(3)) {
        try {
          final info = await chaoxingActiveInfo(client, activity.activeId);
          _log(
            'detail activeId=${activity.activeId} signType=${info.signType?.code} needCaptcha=${info.needCaptcha} '
            'needFace=${info.needFace} needLocation=${info.needLocation} needPhoto=${info.needPhoto} '
            'range=${info.locationRange} lat=${_coordinate(info.locationLatitude)} lng=${_coordinate(info.locationLongitude)} '
            'signInId=${info.signInId == null ? 'none' : 'set'} signOutState=${info.signOutState.name} title=${_mask(info.title)}',
          );
        } on ChaoxingFailure catch (error) {
          _log('detail activeId=${activity.activeId} failed code=${error.code.name} message=${error.message}');
        }
      }
    }

    if (wants('face')) {
      _log('step=face');
      final clientId = account.clientId ?? '';
      final device = chaoxingDecryptClientId(clientId);
      _log(
        'face modulus=${chaoxingFaceModulus() == null ? 'none' : 'ok'} clientId=${clientId.isEmpty ? 'none' : 'len=${clientId.length}'} '
        'deviceKeys=${device == null ? 'none' : device.keys.join(',')} '
        'cid=${device == null ? 'none' : _mask(chaoxingString(device['cid']))} sc=${device == null ? 'none' : 'len=${chaoxingString(device['sc']).length}'}',
      );
      try {
        final objectId = await chaoxingProfileFaceObjectId(client);
        _log('face profileObjectId=${objectId == null ? 'none' : _mask(objectId)}');
      } on ChaoxingFailure catch (error) {
        _log('face profile failed code=${error.code.name} message=${error.message}');
      }
    }

    if (wants('im')) {
      _log('step=im');
      try {
        final config = await chaoxingImConfig(client);
        _log('im token=ok username=${_mask(config.username)}');
        final groups = await chaoxingImGroups(client, config);
        _log('im groups=${groups.length}');
        for (final group in groups) {
          final found = await chaoxingImGroupActivities(client, config: config, group: group);
          _log('im group name=${_mask(group.name)} activities=${found.length}');
          for (final item in found.take(3)) {
            _log('im activity activeId=${item.activeId} atypeName=${item.atypeName} title=${_mask(item.title)}');
          }
        }
      } on ChaoxingFailure catch (error, stack) {
        _log('im failed code=${error.code.name} message=${error.message}\n$stack');
      }
    }
  } on ChaoxingFailure catch (error, stack) {
    _log('failed code=${error.code.name} message=${error.message} payload=${error.payload}\n$stack');
    exitCode = 1;
  } finally {
    http.close();
  }
}

// 只看响应结构，不看值：用来确认字段名（例如 clientId 到底在哪一层）。
Future<void> _dumpSso(ChaoxingHttp http) async {
  try {
    final response = await http.get(Uri.parse(chaoxingUserInfoUri));
    final json = chaoxingJson(response.body);
    _log('sso keys=${json.keys.join(',')}');
    for (final entry in json.entries) {
      final value = entry.value;
      if (value is Map) {
        _log('sso ${entry.key}.keys=${value.keys.join(',')}');
        _describe('sso ${entry.key}', value.cast<String, Object?>());
      } else {
        _log('sso ${entry.key}=${_shape(value)}');
      }
    }
  } on ChaoxingFailure catch (error) {
    _log('sso failed code=${error.code.name} message=${error.message}');
  }
}

void _describe(String prefix, Map<String, Object?> map) {
  for (final entry in map.entries) {
    final value = entry.value;
    if (value is Map) {
      _log('$prefix.${entry.key}.keys=${value.keys.join(',')}');
      for (final nested in value.entries) {
        _log('$prefix.${entry.key}.${nested.key}=${_shape(nested.value)}');
      }
    } else {
      _log('$prefix.${entry.key}=${_shape(value)}');
    }
  }
}

String _shape(Object? value) => switch (value) {
  null => 'null',
  Map() => '<map keys=${value.keys.join(',')}>',
  List() => '<list len=${value.length}>',
  _ => '${value.runtimeType}:len=${'$value'.length}',
};

String _typeCounts(List<ChaoxingActivity> activities) {
  final counts = <String, int>{};
  for (final activity in activities) {
    counts[activity.signType.code] = (counts[activity.signType.code] ?? 0) + 1;
  }
  return counts.entries.map((entry) => '${entry.key}:${entry.value}').join(' ');
}

String _coordinate(double? value) => value == null ? 'none' : '${'${value.abs()}'.split('.').first}d';

void _log(String message) => stdout.writeln('[ChaoxingVerify] $message');

// 只留位数：uid 这类数字标识不进日志正文，够判断「拿到没拿到」。
String _digits(int value) => value <= 0 ? 'none' : '${'$value'.length}d';

// 姓名、校名、课程名、群名、id 一律只留长度与首字（按码点取，避免切坏中文）。
String _mask(String value) =>
    value.isEmpty ? 'empty' : '${String.fromCharCode(value.runes.first)}*${value.length}';
