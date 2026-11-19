import 'dart:math' as math;

import 'package:flutter/painting.dart';

// 在 OKLCH 里取色（同 CSS Color 4 的 oklch()）：明度、彩度、色相分开调，换色相时看起来一样亮（HSL 换色相忽明忽暗，黄比蓝亮得多）。
// 色相从一个颜色（种子）取，或直接给角度（degrees）；之后按明度、彩度、色相偏移取。节日红包的主题与汉诺塔的盘子共用（11-19 从 page/festival/reward_kit.dart 挪来）。
class CampusTone {
  factory CampusTone(Color seed) {
    final (_, a, b) = _toOklab(seed);
    return CampusTone._(math.atan2(b, a));
  }
  // OKLCH 的色相角（度）：红约 29、黄约 110、绿约 142、青约 195、蓝约 264、紫约 310。
  CampusTone.degrees(double degrees) : hue = degrees * math.pi / 180;
  const CampusTone._(this.hue);
  final double hue;

  // 明度 0–1、彩度（OKLCH 的 C，常用 0–0.3）、相对种子的色相偏移（度）。
  Color pick(double lightness, double chroma, {double turn = 0, double alpha = 1}) => _pick(lightness, chroma, hue + turn * math.pi / 180, alpha);

  // 超出 sRGB 时逐步降彩度直到能显示。
  static Color _pick(double lightness, double chroma, double angle, double alpha) {
    var reach = chroma;
    while (true) {
      final rgb = _fromOklab(lightness, reach * math.cos(angle), reach * math.sin(angle));
      final inside = rgb.$1 >= -1e-4 && rgb.$1 <= 1.0001 && rgb.$2 >= -1e-4 && rgb.$2 <= 1.0001 && rgb.$3 >= -1e-4 && rgb.$3 <= 1.0001;
      if (inside || reach < 1e-3) return Color.from(alpha: alpha, red: _encode(rgb.$1), green: _encode(rgb.$2), blue: _encode(rgb.$3));
      reach *= .92;
    }
  }

  static double _linear(double channel) => channel <= .04045 ? channel / 12.92 : math.pow((channel + .055) / 1.055, 2.4).toDouble();
  static double _encode(double linear) {
    final value = linear.clamp(0.0, 1.0);
    return value <= .0031308 ? 12.92 * value : 1.055 * math.pow(value, 1 / 2.4) - .055;
  }

  static double _cbrt(double value) => value < 0 ? -math.pow(-value, 1 / 3).toDouble() : math.pow(value, 1 / 3).toDouble();

  static (double, double, double) _toOklab(Color color) {
    final red = _linear(color.r), green = _linear(color.g), blue = _linear(color.b);
    final l = _cbrt(.4122214708 * red + .5363325363 * green + .0514459929 * blue);
    final m = _cbrt(.2119034982 * red + .6806995451 * green + .1073969566 * blue);
    final s = _cbrt(.0883024619 * red + .2817188376 * green + .6299787005 * blue);
    return (.2104542553 * l + .7936177850 * m - .0040720468 * s, 1.9779984951 * l - 2.4285922050 * m + .4505937099 * s, .0259040371 * l + .7827717662 * m - .8086757660 * s);
  }

  // 返回线性 sRGB（可能超出 0–1，调用方据此判断是否在色域内）。
  static (double, double, double) _fromOklab(double lightness, double a, double b) {
    final l = math.pow(lightness + .3963377774 * a + .2158037573 * b, 3).toDouble();
    final m = math.pow(lightness - .1055613458 * a - .0638541728 * b, 3).toDouble();
    final s = math.pow(lightness - .0894841775 * a - 1.2914855480 * b, 3).toDouble();
    return (4.0767416621 * l - 3.3077115913 * m + .2309699292 * s, -1.2684380046 * l + 2.6097574011 * m - .3413193965 * s, -.0041960863 * l - .7034186147 * m + 1.7076147010 * s);
  }
}
