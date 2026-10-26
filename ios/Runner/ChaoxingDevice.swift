import Flutter
import UIKit

// 学习通签到要的设备信息，对应安卓 ChaoxingDevice.kt（通道 superxd/chaoxing_device）。只在用户使用学习通签到时由 Dart 侧按需取，原样交回，不在原生侧保存。
// [人工决策-2026-10-26 20:29:44] iOS 上报 iPhone 的真实机型与系统，按学习通安卓客户端的字段填（用户选定，没选「不报、走退回」）：
// android_id 位置填本应用的 identifierForVendor（卸载重装会变），fingerprint 由机型与系统拼成，iOS 没有 MediaDrm 与 OAID，都给空（设备码按 Dart 侧退回固定随机码）。
// 学习通认不认这份信息没有实测过。
enum ChaoxingDevice {
  static func register(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "superxd/chaoxing_device", binaryMessenger: messenger).setMethodCallHandler { call, result in
      switch call.method {
      case "deviceInfo":
        result(deviceInfo())
      case "oaid":
        result("")
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func deviceInfo() -> [String: Any?] {
    let device = UIDevice.current
    let machine = machineName()
    let screen = UIScreen.main
    return [
      "androidId": device.identifierForVendor?.uuidString.replacingOccurrences(of: "-", with: "").lowercased() ?? "",
      "fingerprint": "Apple/\(machine)/iOS \(device.systemVersion)",
      "mediaDrmId": "",
      "osVersion": device.systemVersion,
      "language": Locale.preferredLanguages.first ?? Locale.current.identifier,
      "brand": "Apple",
      "board": machine,
      "hardware": machine,
      "model": machine,
      "abis": "arm64",
      "width": Int(screen.nativeBounds.width),
      "height": Int(screen.nativeBounds.height),
      "density": String(describing: screen.scale),
      // iOS 读不到别的应用的版本与签名，由 Dart 侧补默认值。
      "appVersionName": nil,
      "appVersionCode": nil,
      "signatures": nil,
    ]
  }

  // 机型标识（如 iPhone15,2），不是给人看的营销名。
  private static func machineName() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
  }
}
