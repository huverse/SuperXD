import ActivityKit
import Flutter
import UIKit
import WidgetKit

// 桌面小组件与课程实时活动的主应用一侧，对应安卓 CourseWidgets.kt（通道 superxd/course_widget）与 CourseLive.kt（通道 superxd/course_live）。
enum CourseBridge {
  static func register(messenger: FlutterBinaryMessenger) {
    // 快照与配色（JSON，钟点已按校园时区写好）原样存进 App Group，小组件扩展读同一份；存完让系统重排小组件的时间线。
    FlutterMethodChannel(name: "superxd/course_widget", binaryMessenger: messenger).setMethodCallHandler { call, result in
      let key = switch call.method {
      case "publish": "snapshot"
      case "theme": "theme"
      default: ""
      }
      guard !key.isEmpty, let value = (call.arguments as? [String: Any])?[key] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let defaults = SharedGroup.defaults else {
        NSLog("[CourseWidget] action=%@ group=none", call.method)
        result(nil)
        return
      }
      defaults.set(value, forKey: key)
      WidgetCenter.shared.reloadAllTimelines()
      result(nil)
    }
    FlutterMethodChannel(name: "superxd/course_live", binaryMessenger: messenger).setMethodCallHandler { call, result in
      switch call.method {
      case "capability":
        if #available(iOS 16.2, *) {
          result(["live": true, "allowed": ActivityAuthorizationInfo().areActivitiesEnabled])
        } else {
          result(["live": false, "allowed": false])
        }
      case "openSettings":
        if let settings = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(settings) }
        result(nil)
      case "replace":
        if #available(iOS 16.2, *), let items = (call.arguments as? [String: Any])?["items"] as? String {
          CourseLive.replace(items)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

// [人工决策-2026-10-26 21:55:35] iOS 上课程胶囊做成实时活动，应用在后台时系统不让自己开始（用户选定「打开应用时补上」）：
// Dart 每次打开或回到前台都交来计划，这时正处在提醒时刻到下课之间的那节课就开始或更新实时活动；课前提醒照常走通知，点通知打开应用也会补上。
// 课前的内容把过期时刻设在上课，到点系统重画成「上课中」、倒数到下课；上课中打开过应用的，过期时刻设在下课，下课后显示已下课。
@available(iOS 16.2, *)
enum CourseLive {
  private struct Planned: Decodable {
    let key: String
    let fireAt: Double
    let start: Double
    let end: Double
    let title: String
    let before: String
    let during: String
  }

  static func replace(_ json: String) {
    let plan: [Planned]
    do {
      plan = try JSONDecoder().decode([Planned].self, from: Data(json.utf8))
    } catch {
      NSLog("[CourseLive] action=decode errorType=%@", String(describing: type(of: error)))
      return
    }
    let now = Date().timeIntervalSince1970 * 1000
    let current = plan.filter { $0.fireAt <= now && now < $0.end }.min { $0.start < $1.start }
    Task {
      for activity in Activity<CourseActivityAttributes>.activities where activity.attributes.key != current?.key {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
      guard let current, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
      let state = CourseActivityAttributes.ContentState(
        title: current.title, before: current.before, during: current.during,
        fireAt: Date(timeIntervalSince1970: current.fireAt / 1000), start: Date(timeIntervalSince1970: current.start / 1000), end: Date(timeIntervalSince1970: current.end / 1000))
      let content = ActivityContent(state: state, staleDate: now < current.start ? state.start : state.end, relevanceScore: 100)
      if let running = Activity<CourseActivityAttributes>.activities.first(where: { $0.attributes.key == current.key }) {
        await running.update(content)
        return
      }
      do {
        _ = try Activity.request(attributes: CourseActivityAttributes(key: current.key), content: content, pushType: nil)
        NSLog("[CourseLive] action=start")
      } catch {
        NSLog("[CourseLive] action=start errorType=%@", String(describing: type(of: error)))
      }
    }
  }
}
