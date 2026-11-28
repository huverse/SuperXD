import 'dart:convert';
import 'dart:math';

import 'package:superxd/domain/china_coordinates.dart';

// 位置签到的坐标。学习通按坐标系直接算距离，提交口径统一成 BD-09（参考项目的实测口径），
// 地图 SDK 拿到的 WGS-84 或 GCJ-02 先在这里转换。
enum ChaoxingCoordinateSystem { wgs84, gcj02, bd09 }

const _xPi = 3.14159265358979324 * 3000.0 / 180.0;

// 学习通给的老师签到点能不能用：没签时网页与详情里是 -1 这类占位值，落在国内范围外的一律当没有（学习通只在国内用）。
bool chaoxingUsablePoint(double? latitude, double? longitude) =>
    latitude != null && longitude != null && !chinaOutOfRange(latitude, longitude);

// 服务端判出界时给的距离（米，可能是 1.2583E7 这样的科学计数法）写成人看的：一公里以内写米，再远写公里。
String chaoxingDistanceLabel(String meters) {
  final value = double.tryParse(meters);
  if (value == null) return '$meters 米';
  if (value < 1000) return '${value.round()} 米';
  return '${(value / 1000).toStringAsFixed(value < 10000 ? 1 : 0)} 公里';
}

({double latitude, double longitude}) gcj02ToWgs84(double latitude, double longitude) {
  if (chinaOutOfRange(latitude, longitude)) return (latitude: latitude, longitude: longitude);
  final converted = wgs84ToGcj02(latitude, longitude);
  return (latitude: latitude * 2 - converted.latitude, longitude: longitude * 2 - converted.longitude);
}

({double latitude, double longitude}) gcj02ToBd09(double latitude, double longitude) {
  final z = sqrt(longitude * longitude + latitude * latitude) + 0.00002 * sin(latitude * _xPi);
  final theta = atan2(latitude, longitude) + 0.000003 * cos(longitude * _xPi);
  return (latitude: z * sin(theta) + 0.006, longitude: z * cos(theta) + 0.0065);
}

({double latitude, double longitude}) bd09ToGcj02(double latitude, double longitude) {
  final x = longitude - 0.0065;
  final y = latitude - 0.006;
  final z = sqrt(x * x + y * y) - 0.00002 * sin(y * _xPi);
  final theta = atan2(y, x) - 0.000003 * cos(x * _xPi);
  return (latitude: z * sin(theta), longitude: z * cos(theta));
}

({double latitude, double longitude}) toGcj02(
  double latitude,
  double longitude,
  ChaoxingCoordinateSystem system,
) {
  switch (system) {
    case ChaoxingCoordinateSystem.gcj02:
      return (latitude: latitude, longitude: longitude);
    case ChaoxingCoordinateSystem.bd09:
      return bd09ToGcj02(latitude, longitude);
    case ChaoxingCoordinateSystem.wgs84:
      return wgs84ToGcj02(latitude, longitude);
  }
}

({double latitude, double longitude}) toBd09(
  double latitude,
  double longitude,
  ChaoxingCoordinateSystem system,
) {
  switch (system) {
    case ChaoxingCoordinateSystem.bd09:
      return (latitude: latitude, longitude: longitude);
    case ChaoxingCoordinateSystem.gcj02:
      return gcj02ToBd09(latitude, longitude);
    case ChaoxingCoordinateSystem.wgs84:
      final gcj02 = wgs84ToGcj02(latitude, longitude);
      return gcj02ToBd09(gcj02.latitude, gcj02.longitude);
  }
}

// 提交前的随机偏移幅度；被判超范围后收紧到 0.00001（约 1.1 米）。
const chaoxingLocationRange = 0.00005;
const chaoxingLocationTightRange = 0.00001;

class ChaoxingLocation {
  const ChaoxingLocation({
    required this.latitude,
    required this.longitude,
    required this.address,
    this.system = ChaoxingCoordinateSystem.bd09,
  });
  final double latitude;
  final double longitude;
  final String address;
  final ChaoxingCoordinateSystem system;

  // 每 0.00001 度约 1.1 米。
  ChaoxingLocation randomized({double range = chaoxingLocationRange, Random? random}) {
    final source = random ?? Random();
    final bd09 = toBd09(latitude, longitude, system);
    return ChaoxingLocation(
      latitude: bd09.latitude + (source.nextDouble() * 2 - 1) * range,
      longitude: bd09.longitude + (source.nextDouble() * 2 - 1) * range,
      address: address,
    );
  }

  String get formattedLatitude => latitude.toStringAsFixed(6);
  String get formattedLongitude => longitude.toStringAsFixed(6);

  @override
  bool operator ==(Object other) =>
      other is ChaoxingLocation &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.address == address &&
      other.system == system;

  @override
  int get hashCode => Object.hash(latitude, longitude, address, system);

  String payload({required bool mock}) => jsonEncode({
    'result': 1,
    'latitude': double.parse(formattedLatitude),
    'longitude': double.parse(formattedLongitude),
    'address': address,
    if (mock) 'mockData': jsonEncode({'strategy': 0, 'probability': -1}),
  });
}

// 两个位置在地面上的直线距离（米）：先统一到同一坐标系再算，收藏提示「这次的位置离某个收藏很近」用。
double chaoxingDistanceMeters(ChaoxingLocation first, ChaoxingLocation second) {
  final a = toGcj02(first.latitude, first.longitude, first.system);
  final b = toGcj02(second.latitude, second.longitude, second.system);
  const earthRadius = 6371000.0;
  final latRad = (a.latitude - b.latitude) * pi / 180;
  final lngRad = (a.longitude - b.longitude) * pi / 180;
  final sinLat = sin(latRad / 2);
  final sinLng = sin(lngRad / 2);
  final h = sinLat * sinLat + cos(a.latitude * pi / 180) * cos(b.latitude * pi / 180) * sinLng * sinLng;
  return 2 * earthRadius * asin(sqrt(h));
}
