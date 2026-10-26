import ActivityKit
import Foundation

// 课程的实时活动（锁屏与灵动岛），主应用（CourseLive.swift 发起与更新）与小组件扩展（CourseLiveActivity.swift 画）共用这份定义。
// 一节课一个活动，key 是这节课的稳定键；fireAt 是提醒时刻（开始显示），start、end 是上下课；before、during 是课前与上课中的说明行（钟点由 Dart 按校园时区写好）。
@available(iOS 16.2, *)
struct CourseActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var title: String
    var before: String
    var during: String
    var fireAt: Date
    var start: Date
    var end: Date
  }

  var key: String
}
