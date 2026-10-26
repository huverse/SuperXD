import Flutter
import UIKit

// 学习通签到的地图在系统定位关着时给「去打开」，对应安卓 LocationSettings.kt（通道 superxd/location_settings）。
// iOS 只允许跳到本应用自己的设置页（系统定位总开关在「隐私与安全性」里，应用跳不过去），回来由地图自己的定位图层接着定位。
enum LocationSettings {
  static func register(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "superxd/location_settings", binaryMessenger: messenger).setMethodCallHandler { call, result in
      guard call.method == "open", let settings = URL(string: UIApplication.openSettingsURLString) else {
        result(FlutterMethodNotImplemented)
        return
      }
      UIApplication.shared.open(settings) { opened in
        if opened {
          result(nil)
        } else {
          NSLog("[LocationSettings] action=open opened=false")
          result(FlutterError(code: "LOCATION_SETTINGS", message: "无法打开设置", details: nil))
        }
      }
    }
  }
}
