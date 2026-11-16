// 字号与间距令牌（11-16 架构方案 PR D，用户选「推荐方案全做」）：镜像现有界面里实际用到的值，不改样子；新代码写字号与间距用这里的名字，
// 不再写数字字面量，test/code_conventions_test.dart 冻结 lib/theme 以外的字面量数量、只许减少，碰到的文件顺手换成令牌。
// 字号最小 14（用户规则）；超大的展示数字（倒计时、棋盘上的数）是一次性的，可以照旧写字面量。
abstract final class CampusFontSize {
  // 次要信息、说明、标签（bodyMedium、bodySmall）。
  static const double secondary = 14;
  // 正文与列表主行（bodyLarge、titleMedium、按钮）。
  static const double body = 16;
  // 卡片标题。
  static const double cardTitle = 17;
  // 推入页的标题（titleLarge）。
  static const double title = 18;
  // 弹窗标题。
  static const double dialogTitle = 20;
  // 底栏根页的大标题（headlineMedium）。
  static const double headline = 26;
}

// 间距：4 的倍数为主，2 只用于图标与文字之间的细缝。
abstract final class CampusGap {
  static const double hairline = 2;
  static const double tight = 4;
  static const double small = 8;
  static const double medium = 12;
  static const double large = 16;
  static const double section = 24;
}
