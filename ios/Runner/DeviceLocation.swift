import CoreLocation
import Flutter

// 取一次当前位置（通道 superxd/location），对应安卓 DeviceLocation.kt：胖乖生活找附近门店与下单用，Dart 侧 lib/toolbox/life/pangguai/pangguai_location.dart。
// 权限由 Dart 侧经 permission_handler 先问好（仅使用期间，用途说明在 Info.plist 的 NSLocationWhenInUseUsageDescription）；
// 两分钟内的最近位置直接用，没有就用 CoreLocation 的 requestLocation 取一次，最多等 timeoutMs，取不到回空。不持续、不在后台定位。
final class DeviceLocation: NSObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private var pending: FlutterResult?
  private var timer: Timer?

  func register(messenger: FlutterBinaryMessenger) {
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    FlutterMethodChannel(name: "superxd/location", binaryMessenger: messenger).setMethodCallHandler { [weak self] call, result in
      guard let self, call.method == "current" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let timeout = ((call.arguments as? [String: Any])?["timeoutMs"] as? Int) ?? 10000
      self.current(result: result, timeout: Double(max(1000, min(timeout, 30000))) / 1000)
    }
  }

  private func current(result: @escaping FlutterResult, timeout: TimeInterval) {
    if let recent = manager.location, -recent.timestamp.timeIntervalSinceNow < 120 {
      result(fields(recent))
      return
    }
    switch manager.authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways:
      break
    default:
      result(FlutterError(code: "denied", message: "location not authorized", details: nil))
      return
    }
    // 上一次还没回的当作没取到。
    finish(nil)
    pending = result
    timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in self?.finish(nil) }
    manager.requestLocation()
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    finish(locations.last)
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    NSLog("[DeviceLocation] action=current errorCode=%ld", (error as NSError).code)
    finish(nil)
  }

  private func finish(_ location: CLLocation?) {
    timer?.invalidate()
    timer = nil
    guard let result = pending else { return }
    pending = nil
    result(location.map(fields))
  }

  private func fields(_ location: CLLocation) -> [String: Double] {
    ["latitude": location.coordinate.latitude, "longitude": location.coordinate.longitude, "accuracy": location.horizontalAccuracy]
  }
}
