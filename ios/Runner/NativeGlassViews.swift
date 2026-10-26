import Flutter
import UIKit

// 嵌进 Flutter 的系统组件（平台视图），Dart 侧在 lib/theme/native_glass.dart。iOS 26 起是 Liquid Glass，更早的系统是同一组件的旧样式或标准材质。
// 每个视图有自己的通道 superxd/<类型>/<视图号>：Dart 发 update 改参数，原生发回点按、选择与数值。
// 只用在导航层与浮层（底栏、顶栏按钮、弹层与弹窗的底、开关与滑杆），内容层不用玻璃（苹果 HIG Materials）。
enum NativeGlassViews {
  static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    registrar.register(NativeViewFactory(messenger) { GlassContainerView(arguments: $0) }, withId: "superxd/glass_view")
    registrar.register(NativeViewFactory(messenger) { GlassButtonView(arguments: $0) }, withId: "superxd/glass_button")
    registrar.register(NativeViewFactory(messenger) { NativeSwitchView(arguments: $0) }, withId: "superxd/switch")
    registrar.register(NativeViewFactory(messenger) { NativeSliderView(arguments: $0) }, withId: "superxd/slider")
    registrar.register(NativeViewFactory(messenger) { NativeTabBarView(arguments: $0) }, withId: "superxd/tab_bar")
  }
}

final class NativeViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  private let make: ([String: Any]) -> NativeView

  init(_ messenger: FlutterBinaryMessenger, make: @escaping ([String: Any]) -> NativeView) {
    self.messenger = messenger
    self.make = make
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    let view = make(args as? [String: Any] ?? [:])
    view.attach(FlutterMethodChannel(name: "superxd/\(view.kind)/\(viewId)", binaryMessenger: messenger))
    return view
  }
}

class NativeView: NSObject, FlutterPlatformView {
  var kind: String { "" }
  let root = UIView()
  private(set) var channel: FlutterMethodChannel?

  func attach(_ channel: FlutterMethodChannel) {
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "update", let arguments = call.arguments as? [String: Any] { self?.update(arguments) }
      result(nil)
    }
  }

  func update(_ arguments: [String: Any]) {}

  func view() -> UIView { root }

  func pin(_ child: UIView) {
    child.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(child)
    NSLayoutConstraint.activate([
      child.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      child.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      child.topAnchor.constraint(equalTo: root.topAnchor),
      child.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
  }
}

// 玻璃底：垫在 Flutter 内容下面（弹层、弹窗、提示条、导航层里的文字按钮）。radius 大于等于 1000 是胶囊；tint 是着色（强调按钮）。
// 不接点按：Flutter 侧按透明命中处理，点按交给上面的 Flutter 内容。
final class GlassContainerView: NativeView {
  override var kind: String { "glass_view" }
  private let effectView = UIVisualEffectView()

  init(arguments: [String: Any]) {
    super.init()
    root.backgroundColor = .clear
    root.isUserInteractionEnabled = false
    effectView.clipsToBounds = true
    pin(effectView)
    update(arguments)
  }

  override func update(_ arguments: [String: Any]) {
    let radius = arguments["radius"] as? Double ?? 0
    let tint = (arguments["tint"] as? Int).map(UIColor.init(argb:))
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect(style: arguments["clear"] as? Bool == true ? .clear : .regular)
      effect.tintColor = tint
      effectView.effect = effect
      effectView.cornerConfiguration = radius >= 1000 ? .capsule() : .corners(radius: .fixed(radius))
    } else {
      effectView.effect = UIBlurEffect(style: .systemThinMaterial)
      effectView.contentView.backgroundColor = tint
      // 系统把超过短边一半的圆角按一半画，胶囊直接给个大数。
      effectView.layer.cornerRadius = radius >= 1000 ? 9999 : radius
      effectView.layer.cornerCurve = .continuous
    }
  }
}

// 顶栏与悬浮的圆形玻璃按钮：SF Symbols 图标，按下有系统的玻璃形变；点按交回 Dart。prominent 时按主题色着色。
final class GlassButtonView: NativeView {
  override var kind: String { "glass_button" }
  private let button = UIButton(type: .system)

  init(arguments: [String: Any]) {
    super.init()
    root.backgroundColor = .clear
    pin(button)
    button.addAction(UIAction { [weak self] _ in self?.channel?.invokeMethod("tap", arguments: nil) }, for: .primaryActionTriggered)
    update(arguments)
  }

  override func update(_ arguments: [String: Any]) {
    let prominent = arguments["prominent"] as? Bool == true
    var configuration: UIButton.Configuration
    if #available(iOS 26.0, *) {
      configuration = prominent ? .prominentGlass() : .glass()
    } else {
      configuration = prominent ? .filled() : .gray()
    }
    configuration.cornerStyle = .capsule
    configuration.image = (arguments["symbol"] as? String).flatMap { UIImage(systemName: $0) }
    configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: arguments["iconSize"] as? Double ?? 17, weight: .medium)
    if let title = arguments["title"] as? String { configuration.title = title }
    if let tint = (arguments["tint"] as? Int).map(UIColor.init(argb:)) { button.tintColor = tint }
    button.configuration = configuration
    button.isEnabled = arguments["enabled"] as? Bool != false
    button.accessibilityLabel = arguments["label"] as? String
  }
}

// 系统开关：iOS 26 起拨动时滑块变成玻璃；onTint 是控件激活色。
final class NativeSwitchView: NativeView {
  override var kind: String { "switch" }
  private let toggle = UISwitch()

  init(arguments: [String: Any]) {
    super.init()
    root.backgroundColor = .clear
    toggle.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(toggle)
    NSLayoutConstraint.activate([toggle.centerXAnchor.constraint(equalTo: root.centerXAnchor), toggle.centerYAnchor.constraint(equalTo: root.centerYAnchor)])
    toggle.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.channel?.invokeMethod("changed", arguments: self.toggle.isOn)
    }, for: .valueChanged)
    update(arguments)
  }

  override func update(_ arguments: [String: Any]) {
    let value = arguments["value"] as? Bool == true
    if toggle.isOn != value { toggle.setOn(value, animated: true) }
    toggle.isEnabled = arguments["enabled"] as? Bool != false
    toggle.onTintColor = (arguments["tint"] as? Int).map(UIColor.init(argb:))
    toggle.accessibilityLabel = arguments["label"] as? String
  }
}

// 系统滑杆，值域 0–1：拖动中连续回 changed，松手（含系统取消）回 ended。
final class NativeSliderView: NativeView {
  override var kind: String { "slider" }
  private let slider = UISlider()

  init(arguments: [String: Any]) {
    super.init()
    root.backgroundColor = .clear
    pin(slider)
    slider.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.channel?.invokeMethod("changed", arguments: Double(self.slider.value))
    }, for: .valueChanged)
    slider.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.channel?.invokeMethod("ended", arguments: Double(self.slider.value))
    }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
    update(arguments)
  }

  override func update(_ arguments: [String: Any]) {
    let value = Float(arguments["value"] as? Double ?? 0)
    if !slider.isTracking && slider.value != value { slider.setValue(value, animated: false) }
    slider.isEnabled = arguments["enabled"] as? Bool != false
    slider.minimumTrackTintColor = (arguments["tint"] as? Int).map(UIColor.init(argb:))
    slider.accessibilityLabel = arguments["label"] as? String
  }
}

// 系统底栏：iOS 26 起悬浮的 Liquid Glass 底栏，按住拖动有系统的放大镜；角标是未读数，dot 为真时是不计数的小圆点。
// 选中交回 Dart，由 Dart 切分支后再把 selected 发回来（Dart 是选中状态的唯一来源）。
final class NativeTabBarView: NativeView, UITabBarDelegate {
  override var kind: String { "tab_bar" }
  private let bar = UITabBar()

  init(arguments: [String: Any]) {
    super.init()
    root.backgroundColor = .clear
    bar.delegate = self
    pin(bar)
    update(arguments)
  }

  override func update(_ arguments: [String: Any]) {
    let items = arguments["items"] as? [[String: Any]] ?? []
    if bar.items?.count != items.count {
      bar.items = items.enumerated().map { index, _ in UITabBarItem(title: nil, image: nil, tag: index) }
    }
    for (index, item) in items.enumerated() {
      guard let tabItem = bar.items?[index] else { continue }
      tabItem.title = item["title"] as? String
      tabItem.image = (item["symbol"] as? String).flatMap { UIImage(systemName: $0) }
      tabItem.selectedImage = (item["selectedSymbol"] as? String).flatMap { UIImage(systemName: $0) }
      let badge = item["badge"] as? Int ?? 0
      tabItem.badgeValue = badge > 0 ? (badge > 99 ? "99+" : String(badge)) : item["dot"] as? Bool == true ? "" : nil
      tabItem.accessibilityValue = item["accessibilityValue"] as? String
    }
    if let tint = (arguments["tint"] as? Int).map(UIColor.init(argb:)) { bar.tintColor = tint }
    let selected = arguments["selected"] as? Int ?? 0
    if let item = bar.items?[safe: selected], bar.selectedItem !== item { bar.selectedItem = item }
    // 底栏多高由系统定（各版本不同）：量好不含底部安全区的高度交给 Dart，Dart 再加上安全区给内容留位置。
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let height = self.bar.sizeThatFits(CGSize(width: UIScreen.main.bounds.width, height: .greatestFiniteMagnitude)).height - self.bar.safeAreaInsets.bottom
      self.channel?.invokeMethod("height", arguments: Double(max(height, 49)))
    }
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    channel?.invokeMethod("select", arguments: item.tag)
  }
}

extension Array {
  subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
