import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_map_page.dart';

// 老师按地址设点的位置签到：详情不给坐标，只给 locationText（人工决策见 chaoxing_map_page.dart）。
// 把这段地址文字交给高德地理编码换成坐标，供画范围圈与「签到点附近」用。高德返回 GCJ-02；复用地图那把 app key，
// 运行时经原生侧 ServiceSettings.setApiKey 设进搜索 SDK（搜索类已随 3dmap-location-search 打包），不另申请 key、不改清单。
// 只在原生侧联网换坐标，不在本机存地址与结果，日志只记有没有换到、能不能用。

const _channel = MethodChannel('superxd/chaoxing_geocode');

// 和地图同一个门槛：带了 key、又是能加载高德原生库的安卓 arm 设备才有。iOS 现在没有高德，这里恒为假，退回手动选点与上次位置。
bool get chaoxingGeocodeAvailable => chaoxingMapAvailable;

// 测试注入：设了就用它取代原生通道（本机测试跑不到 arm 门槛）。
@visibleForTesting
Future<ChaoxingLocation?> Function(String address)? chaoxingGeocodeOverrideForTests;

// 取点入口：有注入用注入，否则不满足门槛直接空，满足就调原生。
Future<ChaoxingLocation?> chaoxingResolveTeacherGeocode(String address) {
  final override = chaoxingGeocodeOverrideForTests;
  if (override != null) return override(address.trim());
  if (!chaoxingGeocodeAvailable) return Future.value(null);
  return chaoxingGeocodeTeacherPoint(address);
}

// 调高德地理编码：换不到、超时、不在国内范围的一律当没有（退回其余默认位置）。channel 可注入给单测。
Future<ChaoxingLocation?> chaoxingGeocodeTeacherPoint(String address, {MethodChannel channel = _channel}) async {
  final query = address.trim();
  if (query.isEmpty) return null;
  try {
    final result = await channel.invokeMapMethod<String, Object?>('geocode', {
      'key': chaoxingAmapKey,
      'address': query,
    }).timeout(const Duration(seconds: 8));
    final latitude = (result?['latitude'] as num?)?.toDouble();
    final longitude = (result?['longitude'] as num?)?.toDouble();
    final usable = chaoxingUsablePoint(latitude, longitude);
    if (campusDiagnostics) campusLog('[Chaoxing] action=geocode found=${latitude != null} usable=$usable');
    if (!usable) return null;
    // 高德地理编码直接给 GCJ-02；提交口径的换算照旧在 chaoxing_location.dart 里做。
    return ChaoxingLocation(latitude: latitude!, longitude: longitude!, address: query, system: ChaoxingCoordinateSystem.gcj02);
  } catch (error, stack) {
    campusLog('[Chaoxing] action=geocode errorType=${error.runtimeType}\n$stack');
    return null;
  }
}
