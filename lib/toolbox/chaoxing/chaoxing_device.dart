import 'dart:convert';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_crypto.dart';

// 设备信息里没装学习通客户端时补的默认值：与 UA 里的 6.7.5（10941）对齐，签名是官方客户端证书的摘要。
const chaoxingDefaultAppVersion = '6.7.5';
const chaoxingDefaultVersionCode = '10941';
const chaoxingDefaultSignature = '1e27068798b6697821abbeb44a17da5483c4fb7fad7b9ce7890465ed04d0cbe0';

// 取不到 OAID 时有的系统给全 0 占位，不能拿来算设备码。
final _placeholderOaid = RegExp(r'^0{16,64}$');

class ChaoxingDeviceFacts {
  const ChaoxingDeviceFacts({
    required this.androidId,
    required this.fingerprint,
    required this.mediaDrmId,
    required this.osVersion,
    required this.language,
    required this.brand,
    required this.board,
    required this.hardware,
    required this.model,
    required this.abis,
    required this.width,
    required this.height,
    required this.density,
    this.appVersionName,
    this.appVersionCode,
    this.signatures,
  });
  final String androidId;
  final String fingerprint;
  final String mediaDrmId;
  final String osVersion;
  final String language;
  final String brand;
  final String board;
  final String hardware;
  final String model;
  final String abis;
  final int width;
  final int height;
  final String density;
  final String? appVersionName;
  final String? appVersionCode;
  final String? signatures;

  // 原生通道交回来的是平台数据，按外部输入逐项取。
  factory ChaoxingDeviceFacts.fromMap(Map<Object?, Object?> map) {
    String text(String key) => '${map[key] ?? ''}';
    String? optional(String key) => map[key] == null ? null : '${map[key]}';
    int number(String key) => map[key] is int ? map[key]! as int : int.tryParse(text(key)) ?? 0;
    return ChaoxingDeviceFacts(
      androidId: text('androidId'),
      fingerprint: text('fingerprint'),
      mediaDrmId: text('mediaDrmId'),
      osVersion: text('osVersion'),
      language: text('language'),
      brand: text('brand'),
      board: text('board'),
      hardware: text('hardware'),
      model: text('model'),
      abis: text('abis'),
      width: number('width'),
      height: number('height'),
      density: text('density'),
      appVersionName: optional('appVersionName'),
      appVersionCode: optional('appVersionCode'),
      signatures: optional('signatures'),
    );
  }
}

// 设备能力端口：真机走原生通道，测试注入假的或不注入（不注入时用户信息照旧 GET、设备码用固定随机）。
abstract interface class ChaoxingDeviceProbe {
  Future<ChaoxingDeviceFacts> facts(String packageName);

  // 取不到返回空串。
  Future<String> oaid();
}

// 学习通用户信息接口要的设备信息，字段与顺序照学习通客户端：设备唯一号由「客户端包名:ANDROID_ID:系统指纹」做 sha256。
// app_name 报的是被模拟的学习通客户端包名，与 UA、签名摘要是同一个身份。
Map<String, Object?> chaoxingDeviceInfo(ChaoxingDeviceFacts facts, {required String packageName, required DateTime now}) {
  final deviceUniqueId = chaoxingSha256Hex('$packageName:${facts.androidId}:${facts.fingerprint}');
  return {
    'deviceUniqueId': deviceUniqueId,
    'cdid': deviceUniqueId,
    'device_id': deviceUniqueId,
    'android_id': facts.androidId,
    'mediaDrmId': facts.mediaDrmId,
    'oaid': '',
    'platform': 'android',
    'os_name': 'android',
    'os_ver': facts.osVersion,
    'os_lang': facts.language,
    'brand': facts.brand,
    'board': facts.board,
    'hardware': facts.hardware,
    'model': facts.model,
    'cpu_ar': facts.abis,
    'app_name': packageName,
    'app_ver': facts.appVersionName ?? chaoxingDefaultAppVersion,
    'versionCode': facts.appVersionCode ?? chaoxingDefaultVersionCode,
    'signatures': facts.signatures ?? chaoxingDefaultSignature,
    'resolution': '${facts.width}*${facts.height}',
    'dpi': facts.density,
    'time_stamp': now.millisecondsSinceEpoch,
  };
}

// 上传给用户信息接口的 data 参数；取不到设备信息时返回空，调用方退回不带参数的 GET。
Future<String?> chaoxingEncryptedDeviceInfo(ChaoxingDeviceProbe? probe, String packageName) async {
  if (probe == null) return null;
  try {
    final facts = await probe.facts(packageName);
    return chaoxingRsaEncrypt(utf8.encode(jsonEncode(chaoxingDeviceInfo(facts, packageName: packageName, now: DateTime.now()))));
  } catch (error, stack) {
    campusLog('[Chaoxing] action=device_info errorType=${error.runtimeType}\n$stack');
    return null;
  }
}

// 本机设备码：与学习通客户端同算法（AES-ECB 加密 OAID），这样本人在官方客户端签过到也不会被标「更换设备」。
// 取不到 OAID（模拟器、没有厂商标识服务的系统）时返回空，由调用方退回固定随机设备码。
Future<String> chaoxingLocalDeviceCode(ChaoxingDeviceProbe? probe) async {
  if (probe == null) return '';
  try {
    final oaid = (await probe.oaid()).trim();
    if (oaid.isEmpty || _placeholderOaid.hasMatch(oaid.replaceAll('-', ''))) return '';
    return chaoxingDeviceCodeFromOaid(oaid);
  } catch (error, stack) {
    campusLog('[Chaoxing] action=oaid errorType=${error.runtimeType}\n$stack');
    return '';
  }
}
