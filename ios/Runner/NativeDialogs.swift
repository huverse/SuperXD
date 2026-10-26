import Flutter
import UIKit

// 系统弹窗、系统菜单与外观同步（lib/theme/native_glass.dart 的 showNativeAlert、showNativeMenu、NativeAppearanceSync）。
// [人工决策-2026-10-26 21:47:04] iOS 上的玻璃换成苹果官方组件（用户选定「换成系统组件」）：确认与提示用 UIAlertController，⋯ 菜单用系统 UIMenu，
// 都由系统画 Liquid Glass、跟随系统的清透或着色与降低透明度等设置；应用里不再有玻璃档位。
final class NativeDialogs: NSObject {
  private var pendingMenu: MenuAnchorButton?

  func register(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "superxd/native_ui", binaryMessenger: messenger).setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      let arguments = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "appearance":
        Self.applyAppearance(arguments)
        result(nil)
      case "alert":
        self.alert(arguments, result: result)
      case "menu":
        self.menu(arguments, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // 应用自己有浅色、深色与跟随系统：系统组件（弹窗、菜单、玻璃、分享面板）按应用这一份显示，主题色同应用的控件激活色。
  private static func applyAppearance(_ arguments: [String: Any]) {
    let style: UIUserInterfaceStyle = arguments["dark"] as? Bool == true ? .dark : .light
    let tint = (arguments["tint"] as? Int).map(UIColor.init(argb:))
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      for window in scene.windows {
        window.overrideUserInterfaceStyle = style
        if let tint { window.tintColor = tint }
      }
    }
  }

  // 操作按钮按 Dart 侧给的顺序；cancel 是取消（系统把它排在固定位置），destructive 是警示红，preferred 是主操作（加粗）。点哪个返回第几个。
  private func alert(_ arguments: [String: Any], result: @escaping FlutterResult) {
    guard let presenter = UIApplication.shared.topViewController, let actions = arguments["actions"] as? [[String: Any]] else {
      result(FlutterError(code: "NO_WINDOW", message: nil, details: nil))
      return
    }
    let controller = UIAlertController(title: arguments["title"] as? String, message: arguments["message"] as? String, preferredStyle: .alert)
    var answered = false
    for (index, action) in actions.enumerated() {
      let style: UIAlertAction.Style = switch action["style"] as? String {
      case "cancel": .cancel
      case "destructive": .destructive
      default: .default
      }
      let item = UIAlertAction(title: action["title"] as? String, style: style) { _ in
        guard !answered else { return }
        answered = true
        result(index)
      }
      controller.addAction(item)
      if action["preferred"] as? Bool == true { controller.preferredAction = item }
    }
    presenter.present(controller, animated: true)
  }

  // 系统菜单从 Dart 侧点的那个控件弹出：在它的位置放一个透明按钮挂上 UIMenu，用公开的 performPrimaryAction 打开（iOS 17.4 起，同 WebKit 的下拉框）；
  // 更早的系统改用从同一位置弹出的 action sheet（没有图标与勾）。点了哪项返回第几项，点空白关掉返回空。
  private func menu(_ arguments: [String: Any], result: @escaping FlutterResult) {
    guard let presenter = UIApplication.shared.topViewController, let host = presenter.view,
          let rect = arguments["rect"] as? [Double], rect.count == 4, let items = arguments["items"] as? [[String: Any]]
    else {
      result(FlutterError(code: "NO_WINDOW", message: nil, details: nil))
      return
    }
    let frame = host.convert(CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]), from: host.window)
    pendingMenu?.finish(nil)
    if #available(iOS 17.4, *) {
      let button = MenuAnchorButton(frame: frame)
      button.onFinish = { [weak self, weak button] index in
        result(index)
        button?.removeFromSuperview()
        if self?.pendingMenu === button { self?.pendingMenu = nil }
      }
      button.menu = UIMenu(children: items.enumerated().map { index, item in
        var attributes: UIMenuElement.Attributes = []
        if item["destructive"] as? Bool == true { attributes.insert(.destructive) }
        if item["disabled"] as? Bool == true { attributes.insert(.disabled) }
        return UIAction(title: item["title"] as? String ?? "", image: (item["symbol"] as? String).flatMap { UIImage(systemName: $0) }, attributes: attributes, state: item["checked"] as? Bool == true ? .on : .off) { [weak button] _ in
          button?.finish(index)
        }
      })
      host.addSubview(button)
      pendingMenu = button
      button.performPrimaryAction()
      return
    }
    let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    var answered = false
    for (index, item) in items.enumerated() {
      let action = UIAlertAction(title: item["title"] as? String, style: item["destructive"] as? Bool == true ? .destructive : .default) { _ in
        guard !answered else { return }
        answered = true
        result(index)
      }
      action.isEnabled = item["disabled"] as? Bool != true
      sheet.addAction(action)
    }
    sheet.addAction(UIAlertAction(title: arguments["cancel"] as? String ?? "取消", style: .cancel) { _ in
      guard !answered else { return }
      answered = true
      result(nil)
    })
    sheet.popoverPresentationController?.sourceView = host
    sheet.popoverPresentationController?.sourceRect = frame
    presenter.present(sheet, animated: true)
  }
}

// 只用来挂菜单的透明按钮：菜单收起时（选了一项或点空白）结束这一次，只回复一次。
final class MenuAnchorButton: UIButton {
  var onFinish: ((Int?) -> Void)?
  private var chosen: Int?

  override init(frame: CGRect) {
    super.init(frame: frame)
    showsMenuAsPrimaryAction = true
    isAccessibilityElement = false
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func finish(_ index: Int?) {
    if index != nil { chosen = index }
    guard let onFinish else { return }
    if index == nil || chosen != nil {
      self.onFinish = nil
      onFinish(chosen)
    }
  }

  override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
    super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
    // 选中项的回调可能在收起动画之后才到：收起走完再多等一会儿，还没选才算点了空白。
    let settle = { [weak self] in DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.finish(nil) } }
    if let animator {
      animator.addCompletion(settle)
    } else {
      settle()
    }
  }
}

extension UIColor {
  convenience init(argb: Int) {
    self.init(red: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255, blue: CGFloat(argb & 0xFF) / 255, alpha: CGFloat((argb >> 24) & 0xFF) / 255)
  }
}
