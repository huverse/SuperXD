import Flutter
import UIKit

// 常用功能的快捷入口，对应安卓 AppShortcuts.kt（通道 superxd/app_shortcuts）：iOS 只有长按应用图标的菜单，没有「添加到桌面」的接口，pin 一律返回 false。
// 菜单图标只能用随包的图或系统的 SF Symbols，用不了 Dart 画好的 PNG：入口 id（工具 id.入口 id）到 SF Symbols 名在 symbols 里登记，没登记的不带图标。
// 冷启动带来的入口 id 先记下由 Dart 取一次；Dart 已经取过之后才收到的（系统交来得晚），和后台时点的一样经 launch 交回。
final class AppShortcuts: NSObject, FlutterSceneLifeCycleDelegate {
  private static let symbols = ["express.identity": "qrcode"]
  private var channel: FlutterMethodChannel?
  private var pending: String?
  private var launchTaken = false

  func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "superxd/app_shortcuts", binaryMessenger: registrar.messenger())
    self.channel = channel
    registrar.addSceneDelegate(self)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "publish":
        let items = ((call.arguments as? [String: Any])?["shortcuts"] as? [[String: Any]]) ?? []
        UIApplication.shared.shortcutItems = items.compactMap { item in
          guard let id = item["id"] as? String, let label = item["label"] as? String else { return nil }
          return UIApplicationShortcutItem(type: id, localizedTitle: label, localizedSubtitle: nil, icon: Self.symbols[id].map { UIApplicationShortcutIcon(systemImageName: $0) }, userInfo: nil)
        }
        result(nil)
      case "pin":
        result(false)
      case "takeLaunch":
        result(self.pending)
        self.pending = nil
        self.launchTaken = true
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions?) -> Bool {
    guard let item = connectionOptions?.shortcutItem else { return false }
    deliver(item.type)
    return true
  }

  func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) -> Bool {
    deliver(shortcutItem.type)
    completionHandler(true)
    return true
  }

  private func deliver(_ id: String) {
    if launchTaken {
      channel?.invokeMethod("launch", arguments: id)
    } else {
      pending = id
    }
  }
}
