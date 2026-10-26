import SwiftUI
import WidgetKit

// 桌面与锁屏的课表小组件（扩展最低 iOS 16.2，同实时活动；主应用仍是 iOS 16），规则同安卓 CourseWidgets.kt：快照与配色由主应用写进 App Group（CourseBridge.swift），这里按系统时间挑当前与下一节，
// 在上下课时刻、校园日界与快照过期时刻刷新时间线。文字不小于 14 点；颜色用应用发来的配色，跟随系统时按系统深浅色挑。点按只把应用带到前台。
@main
struct CourseWidgetsBundle: WidgetBundle {
  var body: some Widget {
    CourseNextWidget()
    CoursePairWidget()
    CourseDayWidget()
    CourseLiveActivity()
  }
}

private let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

struct WidgetCourse {
  let start: Date
  let end: Date
  let date: String
  let startText: String
  let endText: String
  let name: String
  let place: String
}

struct WidgetColors {
  let background: Color
  let text: Color
  let secondary: Color

  init(_ map: [String: Any]?, fallback: (Int, Int, Int)) {
    func color(_ key: String, _ value: Int) -> Color {
      let argb = map?[key] as? Int ?? value
      return Color(.sRGB, red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255, blue: Double(argb & 0xFF) / 255, opacity: Double((argb >> 24) & 0xFF) / 255)
    }
    background = color("background", fallback.0)
    text = color("text", fallback.1)
    secondary = color("secondary", fallback.2)
  }
}

// 快照与配色，规则同安卓的 WidgetState；读坏了按未登录显示。
struct WidgetState {
  var status = "signedOut"
  var zone = TimeZone.current
  var until = Date.distantPast
  var items: [WidgetCourse] = []
  var mode = "system"
  // 应用还没发来配色时的中性配色（衬底 92% 不透明），同安卓。
  var light = WidgetColors(nil, fallback: (0xEBFFFFFF, 0xFF1F1F1F, 0xFF5F5F5F))
  var dark = WidgetColors(nil, fallback: (0xEB1F1F1F, 0xFFF2F2F2, 0xFFBDBDBD))

  static func read() -> WidgetState {
    var state = WidgetState()
    let directory = SharedGroup.widgetDirectory
    func file(_ key: String) -> [String: Any]? {
      guard let url = directory?.appendingPathComponent("\(key).json"), let data = try? Data(contentsOf: url) else { return nil }
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    if let theme = file("theme") {
      state.mode = theme["mode"] as? String ?? "system"
      state.light = WidgetColors(theme["light"] as? [String: Any], fallback: (0xEBFFFFFF, 0xFF1F1F1F, 0xFF5F5F5F))
      state.dark = WidgetColors(theme["dark"] as? [String: Any], fallback: (0xEB1F1F1F, 0xFFF2F2F2, 0xFFBDBDBD))
    }
    guard let snapshot = file("snapshot") else { return state }
    state.status = snapshot["status"] as? String ?? "signedOut"
    state.zone = (snapshot["timeZone"] as? String).flatMap(TimeZone.init(identifier:)) ?? .current
    state.until = Date(timeIntervalSince1970: (snapshot["until"] as? Double ?? 0) / 1000)
    state.items = (snapshot["items"] as? [[String: Any]] ?? []).compactMap { item in
      guard let start = item["start"] as? Double, let end = item["end"] as? Double, let date = item["date"] as? String else { return nil }
      return WidgetCourse(start: Date(timeIntervalSince1970: start / 1000), end: Date(timeIntervalSince1970: end / 1000), date: date,
                          startText: item["startText"] as? String ?? "", endText: item["endText"] as? String ?? "",
                          name: item["name"] as? String ?? "", place: item["place"] as? String ?? "")
    }
    return state
  }

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
  }

  private func day(_ date: Date) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  }

  // 不能显示课程时的提示；快照过期也算。
  func message(_ now: Date) -> String? {
    switch status {
    case "ready": now >= until ? "打开应用更新课表" : nil
    case "noTerm": "还没有课表"
    case "noTermStart": "开学日未设置"
    case "noBells": "作息时间未设置"
    default: "登录后显示课表"
    }
  }

  func upcoming(_ now: Date) -> [WidgetCourse] { items.filter { $0.end > now } }

  // 「今天」「明天」，更晚的写星期几；快照只覆盖 7 天，星期几不会有歧义。
  func dayWord(_ date: String, _ now: Date) -> String {
    if date == day(now) { return "今天" }
    if date == day(now.addingTimeInterval(86_400)) { return "明天" }
    let parts = date.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, let value = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return date }
    return weekdays[calendar.component(.weekday, from: value) - 1]
  }

  // 正在上：「上课中 · 至09:40」；今天：「08:00」；更晚：「明天 08:00」。
  func label(_ course: WidgetCourse, _ now: Date) -> String {
    if course.start <= now { return "上课中 · 至\(course.endText)" }
    if course.date == day(now) { return course.startText }
    return "\(dayWord(course.date, now)) \(course.startText)"
  }

  // 「今日课程」显示哪天：最早一节没下课的课所在的日子（今天的课上完了就是下一个有课的日子）。
  func shownDay(_ now: Date) -> String { upcoming(now).first?.date ?? day(now) }

  func dayTitle(_ date: String, _ now: Date) -> String {
    let parts = date.split(separator: "-").compactMap { Int($0) }
    return parts.count == 3 ? "\(dayWord(date, now)) \(parts[1])月\(parts[2])日" : dayWord(date, now)
  }

  // 需要重画的时刻：上下课、校园日界、快照过期，取 24 小时内的。
  func boundaries(after now: Date) -> [Date] {
    let midnight = calendar.startOfDay(for: now).addingTimeInterval(86_400)
    let all = items.flatMap { [$0.start, $0.end] } + [midnight, until]
    return Array(Set(all.filter { $0 > now && $0 < now.addingTimeInterval(86_400) })).sorted().prefix(40).map { $0 }
  }

  func colors(_ scheme: ColorScheme) -> WidgetColors {
    switch mode {
    case "light": light
    case "dark": dark
    default: scheme == .dark ? dark : light
    }
  }
}

struct CourseEntry: TimelineEntry {
  let date: Date
  let state: WidgetState
}

struct CourseProvider: TimelineProvider {
  func placeholder(in context: Context) -> CourseEntry { CourseEntry(date: Date(), state: WidgetState()) }

  func getSnapshot(in context: Context, completion: @escaping (CourseEntry) -> Void) { completion(CourseEntry(date: Date(), state: .read())) }

  func getTimeline(in context: Context, completion: @escaping (Timeline<CourseEntry>) -> Void) {
    let now = Date()
    let state = WidgetState.read()
    let dates = [now] + state.boundaries(after: now)
    completion(Timeline(entries: dates.map { CourseEntry(date: $0, state: state) }, policy: .after(dates.last!.addingTimeInterval(60))))
  }
}

// 小组件的底：iOS 17 起交给系统的 containerBackground（系统按需去掉，如待机显示），更早的直接铺。
private struct WidgetBackground: ViewModifier {
  let color: Color

  func body(content: Content) -> some View {
    if #available(iOS 17.0, *) {
      content.containerBackground(color, for: .widget)
    } else {
      content.padding().background(color)
    }
  }
}

private struct CourseCard<Content: View>: View {
  @Environment(\.colorScheme) private var scheme
  let entry: CourseEntry
  @ViewBuilder let content: (WidgetColors) -> Content

  var body: some View {
    let colors = entry.state.colors(scheme)
    Group {
      if let message = entry.state.message(entry.date) {
        Text(message).font(.system(size: 15, weight: .semibold)).foregroundStyle(colors.text).frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        content(colors).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .modifier(WidgetBackground(color: colors.background))
  }
}

// 下一节课：哪天、几点、课名与地点；锁屏上是一行时间加课名。
struct CourseNextWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "CourseNext", provider: CourseProvider()) { entry in CourseNextView(entry: entry) }
      .configurationDisplayName("下一节课")
      .description("正在上或接下来的一节课")
      .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline])
  }
}

struct CourseNextView: View {
  @Environment(\.widgetFamily) private var family
  let entry: CourseEntry

  var body: some View {
    let state = entry.state
    let course = state.upcoming(entry.date).first
    switch family {
    case .accessoryInline:
      Text(course.map { "\(state.label($0, entry.date)) \($0.name)" } ?? state.message(entry.date) ?? "近期没课")
        .modifier(AccessoryBackground())
    case .accessoryRectangular:
      VStack(alignment: .leading, spacing: 2) {
        if let course, state.message(entry.date) == nil {
          Text(state.label(course, entry.date)).font(.system(size: 14, weight: .semibold))
          Text(course.name).font(.system(size: 15, weight: .bold)).lineLimit(1)
          if !course.place.isEmpty { Text(course.place).font(.system(size: 14)).lineLimit(1) }
        } else {
          Text(state.message(entry.date) ?? "近期没课").font(.system(size: 15, weight: .semibold))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .modifier(AccessoryBackground())
    default:
      CourseCard(entry: entry) { colors in
        if let course {
          let ongoing = course.start <= entry.date
          VStack(alignment: .leading, spacing: 4) {
            Text(ongoing ? "上课中" : state.dayWord(course.date, entry.date)).font(.system(size: 14, weight: .medium)).foregroundStyle(colors.secondary)
            Text(ongoing ? "至\(course.endText)" : course.startText).font(.system(size: 28, weight: .bold)).monospacedDigit().foregroundStyle(colors.text).minimumScaleFactor(0.7).lineLimit(1)
            Spacer(minLength: 0)
            Text(course.name).font(.system(size: 15, weight: .bold)).foregroundStyle(colors.text).lineLimit(2)
            if !course.place.isEmpty { Text(course.place).font(.system(size: 14)).foregroundStyle(colors.secondary).lineLimit(1).truncationMode(.head) }
          }
        } else {
          Text("近期没课").font(.system(size: 15, weight: .semibold)).foregroundStyle(colors.text).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
  }
}

// 锁屏小组件的底：iOS 17 起要声明 containerBackground，交给系统画。
private struct AccessoryBackground: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 17.0, *) {
      content.containerBackground(.clear, for: .widget)
    } else {
      content
    }
  }
}

// 接下来两节：每节课名一行、时间与地点一行；正在上的课不写地点（人已在教室）。
struct CoursePairWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "CoursePair", provider: CourseProvider()) { entry in
      CourseCard(entry: entry) { colors in
        let courses = Array(entry.state.upcoming(entry.date).prefix(2))
        if courses.isEmpty {
          Text("近期没课").font(.system(size: 15, weight: .semibold)).foregroundStyle(colors.text).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(courses.enumerated()), id: \.offset) { _, course in
              VStack(alignment: .leading, spacing: 2) {
                Text(course.name).font(.system(size: 16, weight: .bold)).foregroundStyle(colors.text).lineLimit(1)
                let place = course.start <= entry.date ? "" : course.place
                Text(place.isEmpty ? entry.state.label(course, entry.date) : "\(entry.state.label(course, entry.date)) · \(place)")
                  .font(.system(size: 14)).foregroundStyle(colors.secondary).lineLimit(1)
              }
            }
          }
        }
      }
    }
    .configurationDisplayName("接下来两节")
    .description("正在上或接下来的两节课")
    .supportedFamilies([.systemMedium])
  }
}

// 今日课程：今天的全部课，已下课的变淡；今天的课上完后显示下一个有课的日子。
struct CourseDayWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "CourseDay", provider: CourseProvider()) { entry in
      CourseCard(entry: entry) { colors in
        let state = entry.state
        let day = state.shownDay(entry.date)
        let courses = state.items.filter { $0.date == day }
        VStack(alignment: .leading, spacing: 10) {
          Text(state.dayTitle(day, entry.date)).font(.system(size: 14, weight: .semibold)).foregroundStyle(colors.secondary)
          if courses.isEmpty {
            Text("这天没课").font(.system(size: 15, weight: .semibold)).foregroundStyle(colors.text)
          }
          ForEach(Array(courses.prefix(6).enumerated()), id: \.offset) { _, course in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Text(course.startText).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(colors.text)
              VStack(alignment: .leading, spacing: 2) {
                Text(course.name).font(.system(size: 15, weight: .bold)).foregroundStyle(colors.text).lineLimit(1)
                Text(course.place.isEmpty ? "至\(course.endText)" : "至\(course.endText) · \(course.place)").font(.system(size: 14)).foregroundStyle(colors.secondary).lineLimit(1)
              }
            }
            .opacity(course.end <= entry.date ? 0.45 : 1)
          }
        }
      }
    }
    .configurationDisplayName("今日课程")
    .description("今天的全部课程，已下课的变淡；今天的课上完后显示下一个有课的日子")
    .supportedFamilies([.systemLarge])
  }
}
