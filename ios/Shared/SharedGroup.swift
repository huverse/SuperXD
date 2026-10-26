import Foundation

// 主应用与小组件扩展共用的 App Group（主应用写课表快照，小组件读）。主应用与扩展都编进这个文件。
// 自签（全能签等）时分组名由证书决定、各人不同，所以不写死：从安装包自带的描述文件 embedded.mobileprovision 里读出可用的分组，
// 优先 group.<主应用包名>（正式签名时自己登记的那个），否则按名字排第一个；没有描述文件（没签名的包）或证书不带分组时为空，小组件就只显示提示。
enum SharedGroup {
  static let identifier: String? = {
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
          let data = try? Data(contentsOf: url),
          let start = data.range(of: Data("<?xml".utf8)),
          let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
          let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
          let entitlements = plist["Entitlements"] as? [String: Any],
          let groups = (entitlements["com.apple.security.application-groups"] as? [String])?.sorted(), !groups.isEmpty
    else { return nil }
    let preferred = "group." + mainBundleIdentifier
    return groups.contains(preferred) ? preferred : groups[0]
  }()

  static var defaults: UserDefaults? { identifier.flatMap(UserDefaults.init(suiteName:)) }

  // 扩展的包名是「主应用包名.扩展名」。
  private static var mainBundleIdentifier: String {
    let identifier = Bundle.main.bundleIdentifier ?? ""
    return Bundle.main.bundleURL.pathExtension == "appex" ? (identifier as NSString).deletingPathExtension : identifier
  }
}
