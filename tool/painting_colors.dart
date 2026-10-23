import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

// 给开屏画作算清单里的尺寸与颜色（assets/paintings/paintings.json）。加一幅画：图放进 assets/paintings，运行
//   dart run tool/painting_colors.dart assets/paintings/<文件名>.jpg
// 打印这一幅在清单里的 width、height、horizon 与 sky，连同手写的 id、title、note、focus 加进清单。
// horizon 是顶边从左到右 6 段的平均色：画作上方的天空按它横向铺开，与画作顶边逐段接上；sky 是屏幕顶端的天空色（顶边平均色提亮或压暗一些），应用名写在它上面。
const _bands = 6;

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
  final average = [for (var channel = 0; channel < 3; channel++) horizon.map((color) => color[channel]).reduce((sum, value) => sum + value) / _bands];
  final luminance = (.2126 * average[0] + .7152 * average[1] + .0722 * average[2]) / 255;
  // 亮的天空往白里提一些（应用名用深色写），暗的天空往黑里压一些（应用名用浅色写）。
  final target = luminance >= .3 ? 255.0 : 0.0, amount = luminance >= .3 ? .35 : .3;
  final sky = [for (final channel in average) channel + (target - channel) * amount];
  stdout.writeln(const JsonEncoder.withIndent('  ').convert({
    'width': image.width,
    'height': image.height,
    'horizon': [for (final color in horizon) _hex(color[0], color[1], color[2])],
    'sky': _hex(sky[0], sky[1], sky[2]),
  }));
}
