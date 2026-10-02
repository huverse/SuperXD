# domain 领域核心

定位：纯 Dart，不依赖 Flutter，也不依赖项目内其他层。外部包只有三个：uuid 用于生成版本 id，timezone 用于校园时区，crypto 用于日历事件 UID。业务端口 CampusGateway 和全部视图类型都定义在这里，供 page、application、gateway 共用。

# 文件职责

- account.dart：账号身份 AccountIdentity（教务来源 URL 加学号），以及旧库导入的状态与报告类型。
- campus_gateway.dart：
  - 业务端口 CampusGateway，覆盖会话、学期、课表、成绩、作息、开学日和课表版本的读取、同步与写入。所有方法都返回 GatewayResult，不抛异常。
  - 视图类型：GatewayResult、GatewayError、ScheduleView、GradesView、BellsView、RevisionView 等。
- gateway_code.dart：错误码登记表 GatewayCode，每个常量配一行语义注释。新错误码先在这里登记再使用；测试里保留字面量，用来钉住线上取值。
- campus_log.dart：日志出口 campusLog。默认写 stderr；应用入口和设备端工具入口要注入 debugPrint，日志才会进入 logcat。
- campus_clock.dart：
  - campusTimeZone：校园时区的唯一定义。
  - campusToday：校园时区的今天。campusNow：校园时区今天的零点。
  - formatCampusTimestamp：把 UTC 字符串转成校园时间用于展示。
  - clockMinutes：把 HH:mm 转成分钟数。
  - campusMoment：校园日期加当天分钟换算成 UTC 绝对时刻。formatCampusClock：绝对时刻在校园时区的钟点 HH:mm。
- week.dart：ISO 日期与周次计算。第几周从开学日所在周的周一起算（weekIndex、weekRange）。termStartHint 是开学日的说明文案。
- schedule_store.dart：课表核心模型与版本规则。
  - 模型：CourseRecord、CourseMeeting、TermRef、ScheduleRevision、ScheduleScope。
  - ScheduleStore 负责 edit、planSync、commitSync、restore，以及内存中的版本裁剪。
  - fingerprint 判断内容是否变化；visibleCourses 按日或按周筛选课程。
- schedule_edit.dart：课表编辑规则。
  - 校验与规范化：validateSchedule、normalizeSchedule。
  - 单时段与单周调整，冲突检测 courseOverlaps。
  - 变更对比 scheduleChanges，以及时段、周次的显示文案。
- period_spans.dart：把当日课程按节次展开成 PeriodSpan（有课段与空档段），并决定补齐哪些节次。
- meeting_time.dart：按作息把节次换算成上课时刻 MeetingTime。
- course_occurrence.dart：courseOccurrences 把课表、开学日与作息展开成带 UTC 起止时刻的课程实例 CourseOccurrence，供课前提醒、日历导出、桌面小组件共用；节次文案统一用 CourseOccurrence.periods。
  - 按“时段 × 周次”直接定位日期，不逐天扫描。
  - 缺开学日或作息时返回空并带原因（OccurrenceGap），作息里找不到的节次计入 unresolved，不猜时刻。
- course_reminder.dart：课前提醒规则与端口。
  - planReminders：未来 14 天、最多 128 条，提醒时刻已过的不安排。
  - CourseReminderPort：系统调度端口，由 device 层实现；ReminderCapability 表示通知与精确闹钟权限。
  - 提醒设置类型 ReminderSetting 定义在 campus_gateway.dart（默认关闭、提前 15 分钟，档位 5/10/15/30）。
- course_widget.dart：桌面小组件快照与端口。
  - widgetSnapshot：今天起 7 天、最多 200 次课；缺开学日或作息时只给状态。今天已下课的也保留，供“今日课程”变淡显示。
  - WidgetStatus 区分未登录、没有学期、缺开学日、缺作息与正常；快照带过期时刻，过期后小组件提示打开应用。
  - CourseWidgetPort 由 device 层实现；配色类型 WidgetTheme（浅深两套与深浅色模式）。
- ical.dart：buildIcal 把课程实例写成 iCalendar 文本（RFC 5545 最小子集，手写）。
  - 每次上课一个事件，时刻一律 UTC；转义、CRLF、75 八位组折行且不切断多字节字符。
  - UID 由学期、课程、日期、节次哈希而来，重复导入时更新同一事件；不含账号信息。单次最多 icalEventLimit（5000）个事件。
- grades.dart：成绩 JSON 的编解码与边界校验（GradeDataException）、学年摘要，以及筛选与排序（GradeFilter、GradeSort、selectGrades）。

# 关键规则

- 课表版本：
  - 来源只有两种：edu（教务同步）和 user（编辑、恢复）。操作类型有 edit、sync、restore 三种。
  - planSync 的判定：
    - 还没有 head 时，直接插入。
    - 内容指纹相同时，返回 unchanged。
    - 当前 head 来自用户时，返回 needs_confirm，须用户确认覆盖。
    - 当前 head 来自教务时，直接插入新版本。
  - restore 一律生成新的 user 版本，所以之后的教务替换必须确认，历史不会倒退覆盖。
  - 内容没有变化时，edit 和 restore 都返回原 head，不产生新版本。
  - 每学期最多保留 scheduleRevisionLimit（100）个版本，新 head 与最近一次 edu 版本受保护。持久化层 local/app_database.dart 在事务内按同一规则裁剪。
- 课表校验上限：
  - 每学期最多 500 门课，每门课最多 100 个时段。
  - 周次 1–53，节次 1–30。
  - 课程名称 1–200 字，教师和地点各不超过 200 字，学分 0–100。
  - 同一课程不得出现重复的“时段加周次”。
- 单周调整只移除原时段中的这一周。调整全部时段或整门课程，必须由用户明确选择。
- 节次展开：白天按采用的作息补齐节次，晚课只按当日课程延伸。全天没课时仍是空日，不补出不存在的钟点。
- 成绩：
  - 载荷上限 4MB，课程上限 1000 条，单个文本上限 2000 字。
  - 结构不符时抛 GradeDataException，由网关转成 GRADE_DATA_INVALID 并保留原成绩。
- 时间：今天、周次等业务日界只通过 campus_clock 和 week 计算；持久化的时间是 UTC ISO 字符串，展示时才转成校园时区。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/domain
- 本目录的标记位于日志出口、节次展开、单周调整、版本恢复四处。
