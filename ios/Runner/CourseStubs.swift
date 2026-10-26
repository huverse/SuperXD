import Flutter

// 课程胶囊（通道 superxd/course_live）与桌面小组件（superxd/course_widget）在 iOS 上还没接上（实时活动与 WidgetKit 小组件在下一步补）：
// 先回「没有胶囊」并收下快照不做事，课前提醒照常走本地通知，不因通道缺失整轮失败。
enum CourseStubs {
  static func register(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "superxd/course_live", binaryMessenger: messenger).setMethodCallHandler { call, result in
      switch call.method {
      case "capability":
        result(["live": false, "allowed": false])
      case "replace", "openSettings":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    FlutterMethodChannel(name: "superxd/course_widget", binaryMessenger: messenger).setMethodCallHandler { call, result in
      switch call.method {
      case "publish", "theme":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
