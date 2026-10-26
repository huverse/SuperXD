import Flutter
import UIKit

// 满档玻璃的运行时守护，对应安卓 GlassGuard.kt（通道 superxd/glass）：本进程用过满档、且上一进程在前台时异常结束，本版本内限档，升级后重试；
// 外观页点「完整」时 retry 解除。iOS 读不到上一进程的退出原因，改为自己记「是否在前台」：切到后台时清掉，
// 进程在前台被结束（崩溃、被系统因内存杀掉）才会留着；在后台被回收是正常的，不算。
final class GlassGuard {
  private static let usedFullKey = "glass_guard.usedFull"
  private static let foregroundKey = "glass_guard.foreground"
  private static let cappedVersionKey = "glass_guard.cappedVersion"
  private let defaults = UserDefaults.standard

  func register(messenger: FlutterBinaryMessenger) {
    let failed = defaults.bool(forKey: Self.usedFullKey) && defaults.bool(forKey: Self.foregroundKey)
    defaults.removeObject(forKey: Self.usedFullKey)
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    if failed {
      defaults.set(version, forKey: Self.cappedVersionKey)
      NSLog("[GlassGuard] action=cap version=%@", version)
    }
    let capped = defaults.string(forKey: Self.cappedVersionKey) == version
    defaults.set(true, forKey: Self.foregroundKey)
    let center = NotificationCenter.default
    // 用户在多任务界面划掉应用会先收到 willTerminate，同样不算异常。
    for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
      center.addObserver(forName: name, object: nil, queue: .main) { [defaults] _ in defaults.set(false, forKey: Self.foregroundKey) }
    }
    center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [defaults] _ in defaults.set(true, forKey: Self.foregroundKey) }
    FlutterMethodChannel(name: "superxd/glass", binaryMessenger: messenger).setMethodCallHandler { [defaults] call, result in
      switch call.method {
      case "guard":
        result(capped)
      case "markFull":
        defaults.set(true, forKey: Self.usedFullKey)
        result(nil)
      case "retry":
        defaults.removeObject(forKey: Self.cappedVersionKey)
        NSLog("[GlassGuard] action=retry")
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
