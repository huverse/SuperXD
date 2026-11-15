import Flutter
import UIKit
import UserNotifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let files = ToolboxFileExporter()
  private let exits = ProcessExitReasons()
  private let glass = GlassGuard()
  private let calendar = CalendarExporter()
  private let shortcuts = AppShortcuts()
  private let dialogs = NativeDialogs()
  private let tabBar = NativeTabBar()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 要赶在 Dart 读钥匙串之前。
    DeviceOnlyData.claimKeychain()
    // 课前提醒在前台时也要弹出来：通知中心的回调交给 FlutterAppDelegate，由它转给 flutter_local_notifications。
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    // 自动同步的后台刷新（人工决策见 lib/domain/auto_sync.dart）：标识同 Info.plist 与 lib/device/background_sync.dart；要在启动完成前登记。
    // 到没到间隔由 Dart 判断（autoSyncDue），这里不限最早时刻，什么时候叫醒由系统定。后台引擎要自己注册插件（读账号库、会话与钥匙串）。
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    WorkmanagerPlugin.registerPeriodicTask(withIdentifier: "com.superxd.superxd.autoSync")
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    DeviceOnlyData.register(messenger: messenger)
    files.register(messenger: messenger)
    exits.register(messenger: messenger)
    glass.register(messenger: messenger)
    calendar.register(messenger: messenger)
    ChaoxingDevice.register(messenger: messenger)
    LocationSettings.register(messenger: messenger)
    SensitiveClipboard.register(messenger: messenger)
    CourseBridge.register(messenger: messenger)
    dialogs.register(messenger: messenger)
    tabBar.register(messenger: messenger)
    // 快捷入口要收场景回调（冷启动带来的入口、后台时点的入口），按插件登记。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SuperXDAppShortcuts") {
      shortcuts.register(with: registrar)
    }
  }
}

// 复制恢复码这类敏感内容，对应安卓 SensitiveClipboard.kt（通道 superxd/sensitive_clipboard，Dart 侧 lib/page/sensitive_clipboard.dart；
// 人工决策见 lib/domain/app_account.dart 的 19:18:31 那条）：只放本机（localOnly，不经通用剪贴板同步到同一 Apple 账号的别的设备），
// 到点由系统清掉（expirationDate，只清这一项，用户之后自己复制了别的不受影响）。iOS 没有安卓那样的「敏感内容」标记。
enum SensitiveClipboard {
  static func register(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "superxd/sensitive_clipboard", binaryMessenger: messenger).setMethodCallHandler { call, result in
      guard call.method == "copy",
            let arguments = call.arguments as? [String: Any],
            let text = arguments["text"] as? String,
            let clearAfter = arguments["clearAfterMs"] as? Int
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      UIPasteboard.general.setItems(
        [["public.utf8-plain-text": text]],
        options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(Double(clearAfter) / 1000)]
      )
      result(nil)
    }
  }
}

extension UIApplication {
  // 弹分享面板、快速查看要从最上层的界面弹。
  var topViewController: UIViewController? {
    let window = connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
    var top = window?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }
}
