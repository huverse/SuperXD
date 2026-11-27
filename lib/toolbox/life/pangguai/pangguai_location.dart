import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/china_coordinates.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_client.dart';

enum PangguaiLocateFailure { off, denied, unavailable }

class PangguaiLocateException implements Exception {
  const PangguaiLocateException(this.failure);
  final PangguaiLocateFailure failure;

  String get message => switch (failure) {
    PangguaiLocateFailure.off => '手机的定位没开',
    PangguaiLocateFailure.denied => '没有定位权限',
    PangguaiLocateFailure.unavailable => '暂时取不到位置，稍后再试',
  };
}

// 手机的位置（附近门店与下单带的经纬度，用户 11-27 选「加手机定位」）：系统给的 WGS-84 在本机换成 GCJ-02（国内服务的口径，见 domain/china_coordinates.dart）。
// ask 为真时没给过权限会弹系统授权（仅使用期间）；为假时没权限直接失败、不弹。测试注入假的。
abstract interface class PangguaiLocator {
  Future<PangguaiPosition> locate({required bool ask});
  // 去系统设置打开定位开关或给权限。
  Future<void> openSettings(PangguaiLocateFailure failure);
}

// geolocator 实现：只在用到时取一次（不持续定位、不在后台定位）；5 分钟内取过的直接用。
// 安卓强制走系统 LocationManager：国内不少手机没有谷歌服务，融合定位用不了；插件的「定位开关开没开」在有谷歌服务的手机上会去问谷歌服务，
// 所以安卓上不问它，开关关着时由现取抛出的 LocationServiceDisabledException 认出来。先看系统最近一次的位置（10 分钟内的就用），没有再现取，最多等 10 秒。
class GeolocatorPangguaiLocator implements PangguaiLocator {
  PangguaiPosition? _cached;
  DateTime? _cachedAt;

  static const _fresh = Duration(minutes: 5);
  static const _recent = Duration(minutes: 10);

  @override
  Future<PangguaiPosition> locate({required bool ask}) async {
    if (_cached case final cached? when DateTime.now().difference(_cachedAt!) < _fresh) return cached;
    final android = defaultTargetPlatform == TargetPlatform.android;
    if (!android && !await Geolocator.isLocationServiceEnabled()) throw const PangguaiLocateException(PangguaiLocateFailure.off);
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied && ask) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever || permission == LocationPermission.unableToDetermine) {
      throw const PangguaiLocateException(PangguaiLocateFailure.denied);
    }
    try {
      var position = await Geolocator.getLastKnownPosition(forceAndroidLocationManager: android);
      if (position == null || DateTime.now().difference(position.timestamp) > _recent) {
        position = await Geolocator.getCurrentPosition(
          locationSettings: android
              ? AndroidSettings(accuracy: LocationAccuracy.medium, forceLocationManager: true, timeLimit: const Duration(seconds: 10))
              : const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 10)),
        );
      }
      final converted = wgs84ToGcj02(position.latitude, position.longitude);
      _cachedAt = DateTime.now();
      return _cached = (latitude: converted.latitude, longitude: converted.longitude);
    } on TimeoutException catch (error, stack) {
      campusLog('[Pangguai] action=locate errorType=${error.runtimeType}\n$stack');
      throw const PangguaiLocateException(PangguaiLocateFailure.unavailable);
    } on LocationServiceDisabledException {
      throw const PangguaiLocateException(PangguaiLocateFailure.off);
    } on PermissionDeniedException {
      throw const PangguaiLocateException(PangguaiLocateFailure.denied);
    } catch (error, stack) {
      campusLog('[Pangguai] action=locate errorType=${error.runtimeType}\n$stack');
      throw const PangguaiLocateException(PangguaiLocateFailure.unavailable);
    }
  }

  @override
  Future<void> openSettings(PangguaiLocateFailure failure) async {
    try {
      await (failure == PangguaiLocateFailure.off ? Geolocator.openLocationSettings() : Geolocator.openAppSettings());
    } catch (error, stack) {
      campusLog('[Pangguai] action=open_settings errorType=${error.runtimeType}\n$stack');
    }
  }
}
