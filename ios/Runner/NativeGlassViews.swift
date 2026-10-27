import Flutter
import UIKit

// 系统底栏（lib/theme/native_glass.dart 的 NativeTabBar）。iOS 26 起是悬浮的 Liquid Glass 底栏，更早的系统是同一组件的旧样式。
// [人工决策-2026-10-27 00:26:51] 底栏不再做成平台视图，直接挂在 Flutter 视图之上（用户选定「底栏真玻璃，其余自绘」）：
// 平台视图里的系统玻璃取不到 Flutter 画出的背景（10-27 真机截图上底栏比背景还暗），高度又要 Dart 侧去量（安全区算了两次，底栏被拉高变形），
// 每一帧还要多合成一层。挂在 Flutter 视图上之后，玻璃取样的就是下面 Flutter 画出的内容，高度与悬浮位置由系统排。
// 它总在 Flutter 内容之上、系统弹窗之下，所以 Dart 侧逐帧交来底栏该在的样子：壳页被推入的页面盖住时跟着左移，只露出新页面左边缘以左的部分；
// 壳页上开着弹窗、弹层或开屏没走完时淡出；只有完全露出时才接点按。读屏由 Flutter 侧的语义节点负责，系统底栏对读屏隐藏，免得读两遍。
final class NativeTabBar: NSObject, UITabBarDelegate {
  private var channel: FlutterMethodChannel?
  private let bar = UITabBar()
  private let host = TabBarHost()
  private var reportedHeight: CGFloat = 0
  // 现有各项的标题与图标：变了才整组重建。
  private var itemLooks: [[String?]] = []

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "superxd/tab_bar", binaryMessenger: messenger)
    self.channel = channel
    bar.delegate = self
    bar.accessibilityElementsHidden = true
    host.bar = bar
    host.onHeight = { [weak self] height in self?.report(height) }
    host.addSubview(bar)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      let arguments = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "show":
        self.show(arguments)
      case "geometry":
        self.geometry(arguments)
      case "hide":
        self.host.removeFromSuperview()
        self.reportedHeight = 0
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
    }
  }

  // 挂到 Flutter 视图上（第一次或换了窗口时），再更新各项、选中与着色。
  private func show(_ arguments: [String: Any]) {
    // 刚挂上时先透明，等 Dart 交来第一份样子再淡入（开屏还没走完时就一直不出现）。
    if host.superview == nil, let flutterView = (UIApplication.shared.keyWindowRoot as? FlutterViewController)?.view {
      host.frame = flutterView.bounds
      host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      host.alpha = 0
      flutterView.addSubview(host)
    }
    let items = arguments["items"] as? [[String: Any]] ?? []
    // 每一项建的时候就给齐标题与图标，之后只改角标：先建空项再补标题与图标时，系统只给选中的那一项重新排版，
    // 其余各项的标题停在空项时的位置（10-27 真机截图：没选中的标题比图标低一截、往左偏）。
    let looks = items.map { [$0["title"] as? String, $0["symbol"] as? String, $0["selectedSymbol"] as? String] }
    if looks != itemLooks {
      itemLooks = looks
      bar.setItems(looks.enumerated().map { index, look in
        let item = UITabBarItem(title: look[0], image: look[1].flatMap { UIImage(systemName: $0) }, selectedImage: look[2].flatMap { UIImage(systemName: $0) })
        item.tag = index
        return item
      }, animated: false)
    }
    for (index, item) in items.enumerated() {
      guard let tabItem = bar.items?[safe: index] else { continue }
      let badge = item["badge"] as? Int ?? 0
      tabItem.badgeValue = badge > 0 ? (badge > 99 ? "99+" : String(badge)) : item["dot"] as? Bool == true ? "" : nil
    }
    if let tint = (arguments["tint"] as? Int).map(UIColor.init(argb:)) { bar.tintColor = tint }
    if let item = bar.items?[safe: arguments["selected"] as? Int ?? 0], bar.selectedItem !== item { bar.selectedItem = item }
    host.setNeedsLayout()
  }

  // shift 是壳页此刻的横向位移，cover 是盖上来的新页面左边缘（都是逻辑像素、相对屏幕左边）；visible 为假时淡出。
  private func geometry(_ arguments: [String: Any]) {
    let shift = CGFloat(arguments["shift"] as? Double ?? 0)
    let cover = CGFloat(arguments["cover"] as? Double ?? .greatestFiniteMagnitude)
    let visible = arguments["visible"] as? Bool != false
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    bar.transform = CGAffineTransform(translationX: shift, y: 0)
    host.cover = cover
    CATransaction.commit()
    bar.isUserInteractionEnabled = visible && arguments["interactive"] as? Bool == true
    let alpha: CGFloat = visible ? 1 : 0
    if host.alpha != alpha {
      UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.host.alpha = alpha }
    }
  }

  private func report(_ height: CGFloat) {
    guard abs(height - reportedHeight) > 0.5 else { return }
    reportedHeight = height
    channel?.invokeMethod("height", arguments: Double(height))
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    channel?.invokeMethod("select", arguments: item.tag)
  }
}

// 铺满 Flutter 视图的透明容器：只有点在底栏上才接，其余点按落到下面的 Flutter。
// 新页面盖上来时按它的左边缘裁掉右边（矩形裁剪，不用遮罩：遮罩会让里面的系统玻璃取不到背景）。
final class TabBarHost: UIView {
  weak var bar: UITabBar?
  var onHeight: ((CGFloat) -> Void)?
  private let clip = UIView()

  var cover: CGFloat = .greatestFiniteMagnitude {
    didSet { if cover != oldValue { layoutClip() } }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    clip.clipsToBounds = true
    clip.backgroundColor = .clear
    addSubview(clip)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func addSubview(_ view: UIView) {
    view === clip ? super.addSubview(view) : clip.addSubview(view)
  }

  // 底栏多高由系统定（各版本、有没有底部安全区都不同）：按铺满宽度贴底排好后量出的总高（含底部安全区）报给 Dart。
  override func layoutSubviews() {
    super.layoutSubviews()
    layoutClip()
    guard let bar else { return }
    let transform = bar.transform
    bar.transform = .identity
    // 贴底之后底栏才拿得到底部安全区，再量一次。
    for _ in 0..<2 {
      let height = bar.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
      bar.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
    }
    bar.transform = transform
    onHeight?(bar.bounds.height)
  }

  private func layoutClip() {
    clip.frame = CGRect(x: 0, y: 0, width: max(0, min(cover, bounds.width)), height: bounds.height)
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard alpha > 0.01, let bar, bar.isUserInteractionEnabled else { return nil }
    let hit = super.hitTest(point, with: event)
    return hit === self || hit === clip ? nil : hit
  }
}

extension UIApplication {
  // 主窗口的根界面（Flutter 视图所在的那个），不往上找弹出的界面。
  var keyWindowRoot: UIViewController? {
    connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController
  }
}

extension Array {
  subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
