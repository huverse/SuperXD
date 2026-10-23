import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

// 给开屏画作算清单里的尺寸与颜色（assets/paintings/paintings.json）。加一幅画：图放进 assets/paintings，运行
//   dart run tool/painting_colors.dart assets/paintings/<文件名>.jpg
// 打印这一幅在清单里的 width、height、horizon 与 sky，连同手写的 id、title、note、focus 加进清单。
// horizon 是顶边从左到右 6 段的平均色：画作上方的天空按它横向铺开，与画作顶边逐段接上；sky 是屏幕顶端的天空色，应用名写在它上面：
// 取顶边最偏蓝的那一段（天空多半在那儿）保留色相提亮——各段平均会让暖色与冷色互相抵消成灰。
// 打印的是建议值：顶边有树冠、建筑等前景的段，在清单里改成两旁天空的颜色（不然前景色会像一股烟往上冒，河畔树影就是这样改的）。
const _bands = 6;

// 保留色相与饱和度，亮度提到不低于 lightness（HSL）。
List<double> _lighten(List<double> rgb, double lightness) {
  final [red, green, blue] = [for (final channel in rgb) channel / 255];
  final high = [red, green, blue].reduce((a, b) => a > b ? a : b), low = [red, green, blue].reduce((a, b) => a < b ? a : b);
  final light = (high + low) / 2, delta = high - low;
  if (delta == 0) return [for (final _ in rgb) (light < lightness ? lightness : light) * 255];
  final saturation = delta / (1 - (2 * light - 1).abs());
  final hue = high == red ? ((green - blue) / delta) % 6 : high == green ? (blue - red) / delta + 2 : (red - green) / delta + 4;
  final target = light < lightness ? lightness : light;
  final chroma = (1 - (2 * target - 1).abs()) * saturation, second = chroma * (1 - (hue % 2 - 1).abs()), base = target - chroma / 2;
  final (r, g, b) = switch (hue.floor()) { 0 => (chroma, second, 0.0), 1 => (second, chroma, 0.0), 2 => (0.0, chroma, second), 3 => (0.0, second, chroma), 4 => (second, 0.0, chroma), _ => (chroma, 0.0, second) };
  return [(r + base) * 255, (g + base) * 255, (b + base) * 255];
}

String _hex(num red, num green, num blue) => '#${[red, green, blue].map((value) => value.round().clamp(0, 255).toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('用法：dart run tool/painting_colors.dart assets/paintings/<文件名>.jpg');
    exit(64);
  }
  final image = img.decodeImage(File(args.single).readAsBytesSync());
  if (image == null) {
    stderr.writeln('读不出这张图：${args.single}');
    exit(65);
  }
  // 顶边取最上面 3% 的行，免得只取一行被单个笔触带偏。
  final rows = (image.height * .03).ceil().clamp(1, image.height);
  final horizon = <List<double>>[];
  for (var band = 0; band < _bands; band++) {
    final left = image.width * band ~/ _bands, right = image.width * (band + 1) ~/ _bands;
    var red = 0.0, green = 0.0, blue = 0.0;
    for (var y = 0; y < rows; y++) {
      for (var x = left; x < right; x++) {
        final pixel = image.getPixel(x, y);
        red += pixel.r;
        green += pixel.g;
        blue += pixel.b;
      }
    }
    final count = rows * (right - left);
    horizon.add([red / count, green / count, blue / count]);
  }
  final bluest = horizon.reduce((best, color) => (color[2] - color[0]) + (color[2] - color[1]) / 2 > (best[2] - best[0]) + (best[2] - best[1]) / 2 ? color : best);
  final sky = _lighten(bluest, .84);
  stdout.writeln(const JsonEncoder.withIndent('  ').convert({
    'width': image.width,
    'height': image.height,
    'horizon': [for (final color in horizon) _hex(color[0], color[1], color[2])],
    'sky': _hex(sky[0], sky[1], sky[2]),
  }));
}
