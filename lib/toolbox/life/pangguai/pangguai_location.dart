import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/china_coordinates.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';

enum PangguaiLocationProblem {
  // 没给定位权限（或这次没问、不弹框）。
  denied,
  // 系统定位总开关关着。
  disabled,
  // 开着也给了权限，但这一会儿没取到位置（室内、超时）。
  unavailable,
}

class PangguaiLocationException implements Exception {
  const PangguaiLocationException(this.problem);
  final PangguaiLocationProblem problem;

  String get message => switch (problem) {
    PangguaiLocationProblem.denied => '要允许使用位置',
    PangguaiLocationProblem.disabled => '要打开手机的定位',
    PangguaiLocationProblem.unavailable => '没取到位置，到窗边或室外再试',
  };
}

// 位置端口：找附近门店、打开设备页（已允许过位置时先读一次备用，11-28 起）与下单时取（下单请求头带经纬度与位置签名，胖乖按它核对人在不在设备旁），不持续、不在后台定位。
abstract interface class PangguaiLocator {
  // ask 为真时没给过权限就弹系统授权（仅使用期间）；为假时不弹，直接报 denied。
  Future<PangguaiPosition> current({required bool ask});
  // 去系统设置：没权限时到本应用的设置页，定位关着时到系统定位设置（iOS 只能到本应用的设置页）。
  Future<void> openSettings(PangguaiLocationProblem problem);
}

// 系统定位经通道 superxd/location（安卓 DeviceLocation.kt 用系统的 LocationManager，不带谷歌服务的闭源库；iOS DeviceLocation.swift 用 CoreLocation），
// 原生只管取一次位置、最多等 10 秒；权限由 permission_handler 问。5 分钟内取过的直接用。系统给的 WGS-84 在这里换成 GCJ-02，只发给胖乖。
class ChannelPangguaiLocator implements PangguaiLocator {
  static const _channel = MethodChannel('superxd/location');
  static const _settings = MethodChannel('superxd/location_settings');
  static const _fresh = Duration(minutes: 5);
  PangguaiPosition? _cached;
  DateTime? _cachedAt;

  @override
  Future<PangguaiPosition> current({required bool ask}) async {
    final cachedAt = _cachedAt, cached = _cached;
    if (cached != null && cachedAt != null && DateTime.now().difference(cachedAt) < _fresh) return cached;
    var status = await Permission.locationWhenInUse.status;
    if (!status.isGranted && ask) status = await Permission.locationWhenInUse.request();
    if (!status.isGranted) throw const PangguaiLocationException(PangguaiLocationProblem.denied);
    if (await Permission.locationWhenInUse.serviceStatus == ServiceStatus.disabled) throw const PangguaiLocationException(PangguaiLocationProblem.disabled);
    final Map<String, Object?>? raw;
    final watch = Stopwatch()..start();
    try {
      raw = await _channel.invokeMapMethod<String, Object?>('current', {'timeoutMs': 10000});
      // 下单前要等它：记下这次现取用了多久（11-28 诊断包里看不出定位占了多少）。
      campusLog('[Pangguai] action=locate ms=${watch.elapsedMilliseconds}');
    } on PlatformException catch (error, stack) {
      campusLog('[Pangguai] action=locate errorType=${error.code}\n$stack');
      throw PangguaiLocationException(error.code == 'disabled' ? PangguaiLocationProblem.disabled : error.code == 'denied' ? PangguaiLocationProblem.denied : PangguaiLocationProblem.unavailable);
    }
    final latitude = raw?['latitude'], longitude = raw?['longitude'];
    if (latitude is! double || longitude is! double || latitude.abs() > 90 || longitude.abs() > 180) {
      campusLog('[Pangguai] action=locate errorType=no_fix');
      throw const PangguaiLocationException(PangguaiLocationProblem.unavailable);
    }
    final converted = wgs84ToGcj02(latitude, longitude);
    _cachedAt = DateTime.now();
    return _cached = converted;
  }

  @override
  Future<void> openSettings(PangguaiLocationProblem problem) async {
    try {
      if (problem == PangguaiLocationProblem.denied) {
        await openAppSettings();
      } else {
        await _settings.invokeMethod<void>('open');
      }
    } catch (error, stack) {
      campusLog('[Pangguai] action=open_location_settings errorType=${error.runtimeType}\n$stack');
    }
  }
}
