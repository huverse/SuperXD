import 'package:flutter/material.dart';

import 'package:superxd/local/display_settings.dart';
import 'package:superxd/page/course_cards.dart';
import 'package:superxd/page/schedule_page.dart';
import 'package:superxd/page/today_page.dart';

// 字号条的推荐范围（人工决策见 local/display_settings.dart 的 textSizeMin）：同样的字号，屏越窄、字体越宽越早挤，所以不写死，
// 按这台手机的屏宽与当前字体（含系统粗体文本），用页面自己判断改排的那几条规则来量：主要页面都保持原排法
// （学期视图带左侧栏、课程卡带时刻列、今天页与课表顶栏的按钮带字）的最大字号就是推荐上限，下限是标准 100%。
// [人工决策-2026-10-31 21:04:58] 推荐上限算进学期视图的左侧栏（用户要推荐范围落在左侧栏那种排法里，选「推荐=左侧栏上限」，
// 未选「放宽左侧栏到 4 个字」「放宽到 5 个字」，左侧栏的标准不动）：左侧栏比其余几条先撑不住，推荐上限就是它还放得下的最大字号。
// 10-31 用真字体扫过：Maple 360dp 只到 100%、393dp 110%、411dp 120%、430dp 130%；宋体 360dp 115%、411dp 140%、430dp 150%；
// 粗体文本不影响这两种字体；320dp 标准字号已是顶部栏（推荐仍至少标 100%）。10-27 不算左侧栏时 Maple 360dp 到 145%、411dp 到 175%。

// 在 size 下会改排的地方，按影响大小排，超出推荐时照这个提醒（今天页与课表的顶栏合成一句）。
List<String> textSizeAdaptations(BuildContext context, double screenWidth, double size) {
  final scaler = TextScaler.linear(size);
  return [
    if (!semesterRailFits(context, screenWidth, textScaler: scaler)) '学期视图的月份栏移到顶部',
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

// 组合根在 MaterialApp.builder 里量这台手机的推荐上限，交给 builder（跟随系统时的上限，见 DisplaySettings.effectiveTextSize），
// 下面可经 TextSizeComfort.of 取到上限与按同口径量的改排处（开发者模式的字号记录用）。屏宽、粗体文本或字体变了才重量。
// 量字与外观页同口径：页面在 Scaffold 的 Material 里，默认文字样式是主题的 bodyMedium；这一层在它外面，默认的是 MaterialApp 的兜底样式，
// 拿它量会让没写字体的规则量成别的字体（10-31 模拟器上 Maple 360dp 记成过 160%，外观页是 145%）。所以给量字垫一层 bodyMedium，
// 再把原来的默认样式原样还给下面的应用，应用的显示不变。
class TextSizeComfort extends StatefulWidget {
  const TextSizeComfort({super.key, required this.builder});
  final Widget Function(BuildContext context, double comfortable) builder;

  static ({double comfortable, List<String> Function(double size) adaptations}) of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_TextSizeComfortScope>()!;
    return (comfortable: scope.comfortable, adaptations: scope.adaptations);
  }

  @override
  State<TextSizeComfort> createState() => _TextSizeComfortState();
}

class _TextSizeComfortState extends State<TextSizeComfort> {
  final _measure = GlobalKey();
  String? _measured;
  double _comfortable = comfortableTextSizeMin;

  List<String> _adaptations(double size) {
    final measure = _measure.currentContext!;
    return textSizeAdaptations(measure, MediaQuery.sizeOf(measure).width, size);
  }

  @override
  Widget build(BuildContext context) {
    final outer = DefaultTextStyle.of(context);
    final body = Theme.of(context).textTheme.bodyMedium!;
    return DefaultTextStyle(
      style: body,
      child: Builder(
        key: _measure,
        builder: (measure) {
          final width = MediaQuery.sizeOf(measure).width;
          final inputs = '$width|${MediaQuery.boldTextOf(measure)}|${body.fontFamily}';
          if (inputs != _measured) {
            _measured = inputs;
            _comfortable = comfortableTextSize(measure, width);
          }
          return _TextSizeComfortScope(
            comfortable: _comfortable,
            adaptations: _adaptations,
            child: DefaultTextStyle(
              style: outer.style,
              textAlign: outer.textAlign,
              softWrap: outer.softWrap,
              overflow: outer.overflow,
              maxLines: outer.maxLines,
              textWidthBasis: outer.textWidthBasis,
              textHeightBehavior: outer.textHeightBehavior,
              child: widget.builder(context, _comfortable),
            ),
          );
        },
      ),
    );
  }
}

class _TextSizeComfortScope extends InheritedWidget {
  const _TextSizeComfortScope({required this.comfortable, required this.adaptations, required super.child});
  final double comfortable;
  final List<String> Function(double size) adaptations;

  @override
  bool updateShouldNotify(_TextSizeComfortScope oldWidget) => oldWidget.comfortable != comfortable;
}
