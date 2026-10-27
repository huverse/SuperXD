import Flutter
import UIKit
import UserNotifications

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
    CourseBridge.register(messenger: messenger)
    dialogs.register(messenger: messenger)
    tabBar.register(messenger: messenger)
    // 快捷入口要收场景回调（冷启动带来的入口、后台时点的入口），按插件登记。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SuperXDAppShortcuts") {
      shortcuts.register(with: registrar)
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
