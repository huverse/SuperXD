import Flutter
import Foundation
import Security

// 只属于这台设备、这次安装的数据，对应安卓的 data_extraction_rules.xml 与「卸载即删」。
enum DeviceOnlyData {
  private static let keychainClaimedKey = "superxd.keychainClaimed"

  // iOS 卸载应用不删钥匙串：新装后第一次启动先清掉上次安装留下的记住账号凭据、私信私钥与学习通、拼多多会话，同安卓卸载即删。
  // 标记放在 UserDefaults，卸载时随应用删除；钥匙串条目都是「仅本机」级别，换机恢复的备份带不过来。
  static func claimKeychain() {
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: keychainClaimedKey) { return }
    let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword] as CFDictionary)
    NSLog("[DeviceOnlyData] action=claim_keychain status=%d", status)
    defaults.set(true, forKey: keychainClaimedKey)
  }

  // 通道 superxd/backup：把 Dart 侧给的目录与文件标记为不进 iCloud 备份与换机迁移（lib/device/backup_exclusion.dart）。
  static func register(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "superxd/backup", binaryMessenger: messenger).setMethodCallHandler { call, result in
      guard call.method == "exclude", let paths = call.arguments as? [String] else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        for path in paths {
          var url = URL(fileURLWithPath: path)
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          try url.setResourceValues(values)
        }
        result(nil)
      } catch {
        result(FlutterError(code: "EXCLUDE_FAILED", message: String(describing: type(of: error)), details: nil))
      }
    }
  }
}
