import 'dart:convert';
import 'dart:math';

// 位置签到的坐标。学习通按坐标系直接算距离，提交口径统一成 BD-09（参考项目的实测口径），
// 地图 SDK 拿到的 WGS-84 或 GCJ-02 先在这里转换。
enum ChaoxingCoordinateSystem { wgs84, gcj02, bd09 }

const _pi = 3.1415926535897932384626;
const _a = 6378245.0;
const _ee = 0.00669342162296594323;
const _xPi = 3.14159265358979324 * 3000.0 / 180.0;

bool _outOfChina(double latitude, double longitude) =>
    !(longitude > 73.66 && longitude < 135.05 && latitude > 3.86 && latitude < 53.55);

double _transformLatitude(double x, double y) {
  var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(x.abs());
  ret += (20.0 * sin(6.0 * x * _pi) + 20.0 * sin(2.0 * x * _pi)) * 2.0 / 3.0;
  ret += (20.0 * sin(y * _pi) + 40.0 * sin(y / 3.0 * _pi)) * 2.0 / 3.0;
  ret += (160.0 * sin(y / 12.0 * _pi) + 320.0 * sin(y * _pi / 30.0)) * 2.0 / 3.0;
  return ret;
}

double _transformLongitude(double x, double y) {
  var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(x.abs());
  ret += (20.0 * sin(6.0 * x * _pi) + 20.0 * sin(2.0 * x * _pi)) * 2.0 / 3.0;
  ret += (20.0 * sin(x * _pi) + 40.0 * sin(x / 3.0 * _pi)) * 2.0 / 3.0;
  ret += (150.0 * sin(x / 12.0 * _pi) + 300.0 * sin(x / 30.0 * _pi)) * 2.0 / 3.0;
  return ret;
}

({double latitude, double longitude}) wgs84ToGcj02(double latitude, double longitude) {
  if (_outOfChina(latitude, longitude)) return (latitude: latitude, longitude: longitude);
  final deltaLatitude = _transformLatitude(longitude - 105.0, latitude - 35.0);
  final deltaLongitude = _transformLongitude(longitude - 105.0, latitude - 35.0);
  final radian = latitude / 180.0 * _pi;
  var magic = sin(radian);
  magic = 1 - _ee * magic * magic;
  final sqrtMagic = sqrt(magic);
  return (
    latitude: latitude + (deltaLatitude * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * _pi),
    longitude: longitude + (deltaLongitude * 180.0) / (_a / sqrtMagic * cos(radian) * _pi),
  );
}

({double latitude, double longitude}) gcj02ToWgs84(double latitude, double longitude) {
  if (_outOfChina(latitude, longitude)) return (latitude: latitude, longitude: longitude);
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
