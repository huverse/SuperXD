import ActivityKit
import SwiftUI
import WidgetKit

// 课程实时活动的画面（锁屏与灵动岛），由主应用的 CourseLive.swift 发起（[人工决策] 在那里）。同安卓的课程胶囊：课前倒数到上课，上课中倒数到下课并画进度。
// 画面只在发起、更新与到了过期时刻时重画：课前那份的过期时刻是上课，到点重画成上课中；上课中那份的过期时刻是下课，到点重画成已下课。
struct CourseLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: CourseActivityAttributes.self) { context in
      CourseLiveView(state: context.state)
        .padding(16)
    } dynamicIsland: { context in
      let phase = CoursePhase(context.state)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text(context.state.title).font(.system(size: 16, weight: .bold)).lineLimit(1)
        }
        DynamicIslandExpandedRegion(.trailing) {
          CourseTimer(phase: phase, state: context.state).font(.system(size: 16, weight: .semibold))
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            Text(phase.line(context.state)).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
            if phase != .before { CourseProgress(state: context.state) }
          }
        }
      } compactLeading: {
        Image(systemName: phase == .before ? "bell.fill" : "book.fill")
      } compactTrailing: {
        CourseTimer(phase: phase, state: context.state).font(.system(size: 14, weight: .semibold)).frame(maxWidth: 52)
      } minimal: {
        Image(systemName: phase == .before ? "bell.fill" : "book.fill")
      }
    }
  }
}

enum CoursePhase {
  case before, during, ended

  // 画面重画时按当时的时刻定阶段；到了过期时刻系统会重画一次。
  init(_ state: CourseActivityAttributes.ContentState) {
    let now = Date()
    self = now >= state.end ? .ended : now >= state.start ? .during : .before
  }

  func line(_ state: CourseActivityAttributes.ContentState) -> String {
    switch self {
    case .before: state.before
    case .during: state.during
    case .ended: "已下课"
    }
  }
}

private struct CourseTimer: View {
  let phase: CoursePhase
  let state: CourseActivityAttributes.ContentState

  var body: some View {
    switch phase {
    case .before: Text(timerInterval: state.fireAt...max(state.fireAt, state.start), countsDown: true).monospacedDigit().multilineTextAlignment(.trailing)
    case .during: Text(timerInterval: state.start...state.end, countsDown: true).monospacedDigit().multilineTextAlignment(.trailing)
    case .ended: Text("已下课")
    }
  }
}

private struct CourseProgress: View {
  let state: CourseActivityAttributes.ContentState

  var body: some View {
    ProgressView(timerInterval: state.start...state.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
  }
}

private struct CourseLiveView: View {
  let state: CourseActivityAttributes.ContentState

  var body: some View {
    let phase = CoursePhase(state)
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(state.title).font(.system(size: 17, weight: .bold)).lineLimit(1)
        Spacer(minLength: 12)
        CourseTimer(phase: phase, state: state).font(.system(size: 22, weight: .bold))
      }
      Text(phase.line(state)).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
      if phase != .before { CourseProgress(state: state) }
    }
  }
}
