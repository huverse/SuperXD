import 'package:flutter/widgets.dart';

import 'package:superxd/local/display_settings.dart';
import 'package:superxd/page/course_cards.dart';
import 'package:superxd/page/schedule_page.dart';
import 'package:superxd/page/today_page.dart';

// 字号条的推荐范围（人工决策见 local/display_settings.dart 的 textSizeMin）：同样的字号，屏越窄、字体越宽越早挤，所以不写死，
// 按这台手机的屏宽与当前字体（含系统粗体文本），用页面自己判断改排的那几条规则来量：主要页面都保持原排法
// （课程卡带时刻列、今天页与课表顶栏的按钮带字）的最大字号就是推荐上限，下限是标准 100%。
// 10-27 在 320–430dp、三种字体下逐档扫过：Maple 在 360dp 到 145%、411dp 到 175%，宋体与系统字体宽松约两三档；全程不裁字，超出只是改排。

// 在 size 下会改排的地方，按影响大小排，超出推荐时照这个提醒（今天页与课表的顶栏合成一句）。
List<String> textSizeAdaptations(BuildContext context, double screenWidth, double size) {
  final scaler = TextScaler.linear(size);
  return [
    if (!courseCardColumnsFit(context, screenWidth - 32, textScaler: scaler)) '课程卡时刻挪到首行',
    if (!todayHeaderFits(context, screenWidth - 32, textScaler: scaler) || !scheduleTitleFits(context, screenWidth, textScaler: scaler)) '顶栏按钮只留图标',
  ];
}

// 推荐范围的下限是标准 100%：字号条最小到 80%（人工决策见 display_settings.dart 的 textSizeMin），比标准小的字低于设计尺寸 14px，不标推荐。
const comfortableTextSizeMin = 1.0;

// 推荐上限：字号越大越挤，按 5% 一档二分找最后一个不改排的；最窄的屏也至少是标准 100%。
double comfortableTextSize(BuildContext context, double screenWidth) {
  double sizeAt(int step) => DisplaySettings.snapTextSize(comfortableTextSizeMin + step * DisplaySettings.textSizeStep);
  var low = 0, high = ((DisplaySettings.textSizeMax - comfortableTextSizeMin) / DisplaySettings.textSizeStep).round();
  if (textSizeAdaptations(context, screenWidth, sizeAt(high)).isEmpty) return sizeAt(high);
  while (high - low > 1) {
    final middle = (low + high) ~/ 2;
    if (textSizeAdaptations(context, screenWidth, sizeAt(middle)).isEmpty) {
      low = middle;
    } else {
      high = middle;
    }
  }
  return sizeAt(low);
}
