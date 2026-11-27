import 'dart:math';

// 国内坐标系换算（公开的 GCJ-02 算法）：手机系统定位给的是 WGS-84，国内地图与服务（高德、胖乖生活这类）按 GCJ-02 算距离。
// 学习通位置签到与胖乖生活的附近门店、下单坐标共用这一份（11-27 从 toolbox/chaoxing/chaoxing_location.dart 搬来）。

const _pi = 3.1415926535897932384626;
const _a = 6378245.0;
const _ee = 0.00669342162296594323;

// 不在国内范围的坐标不做偏移（GCJ-02 只对国内有定义）。
bool outsideChina(double latitude, double longitude) => !(longitude > 73.66 && longitude < 135.05 && latitude > 3.86 && latitude < 53.55);

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
  if (outsideChina(latitude, longitude)) return (latitude: latitude, longitude: longitude);
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
  if (outsideChina(latitude, longitude)) return (latitude: latitude, longitude: longitude);
  final converted = wgs84ToGcj02(latitude, longitude);
  return (latitude: latitude * 2 - converted.latitude, longitude: longitude * 2 - converted.longitude);
}
