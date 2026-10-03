import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:superxd/theme/campus_palette.dart';

// 壁纸色调网格：导入时把图解码成小图，按格记下最暗与最亮的像素（sRGB 三字节），运行时不再解码原图。
// 网格按原图比例划分，短边 16 格、长边按比例最多 48 格；每格取样 8×8 像素。
class WallpaperTone {
  const WallpaperTone({
    required this.width,
    required this.height,
    required this.columns,
    required this.rows,
    required this.darkest,
    required this.brightest,
  });
  final int width;
  final int height;
  final int columns;
  final int rows;
  final Uint8List darkest;
  final Uint8List brightest;

  String encode() => jsonEncode({
    'width': width,
    'height': height,
    'columns': columns,
    'rows': rows,
    'darkest': base64Encode(darkest),
    'brightest': base64Encode(brightest),
  });

  // 设置库里的值来自本应用写入，仍按边界数据校验；格式不对时返回 null，按未设置壁纸处理。
  static WallpaperTone? decode(String? text) {
    if (text == null) return null;
    try {
      final json = jsonDecode(text) as Map<String, Object?>;
      final columns = json['columns'] as int, rows = json['rows'] as int;
      final darkest = base64Decode(json['darkest'] as String), brightest = base64Decode(json['brightest'] as String);
      final width = json['width'] as int, height = json['height'] as int;
      if (columns <= 0 || rows <= 0 || width <= 0 || height <= 0) return null;
      if (darkest.length != columns * rows * 3 || brightest.length != darkest.length) return null;
      return WallpaperTone(width: width, height: height, columns: columns, rows: rows, darkest: darkest, brightest: brightest);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

const _cellSamples = 8;
const _shortCells = 16;
const _longCellsMax = 48;

// 解码失败（不是图片或格式不支持）时抛出，由调用方提示换一张。
Future<WallpaperTone> measureWallpaper(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final width = descriptor.width, height = descriptor.height;
  final portrait = height >= width;
  final longCells = (_shortCells * (portrait ? height / width : width / height)).round().clamp(_shortCells, _longCellsMax);
  final columns = portrait ? _shortCells : longCells, rows = portrait ? longCells : _shortCells;
  final codec = await descriptor.instantiateCodec(targetWidth: columns * _cellSamples, targetHeight: rows * _cellSamples);
  final frame = await codec.getNextFrame();
  final pixels = (await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  frame.image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  final darkest = Uint8List(columns * rows * 3), brightest = Uint8List(columns * rows * 3);
  final stride = columns * _cellSamples;
  for (var row = 0; row < rows; row++) {
    for (var column = 0; column < columns; column++) {
      var low = double.infinity, high = -1.0;
      var lowAt = 0, highAt = 0;
      for (var y = row * _cellSamples; y < (row + 1) * _cellSamples; y++) {
        for (var x = column * _cellSamples; x < (column + 1) * _cellSamples; x++) {
          final at = (y * stride + x) * 4;
          final luminance = _luminance(pixels.getUint8(at), pixels.getUint8(at + 1), pixels.getUint8(at + 2));
          if (luminance < low) {
            low = luminance;
            lowAt = at;
          }
          if (luminance > high) {
            high = luminance;
            highAt = at;
          }
        }
      }
      final cell = (row * columns + column) * 3;
      for (var channel = 0; channel < 3; channel++) {
        darkest[cell + channel] = pixels.getUint8(lowAt + channel);
        brightest[cell + channel] = pixels.getUint8(highAt + channel);
      }
    }
  }
  return WallpaperTone(width: width, height: height, columns: columns, rows: rows, darkest: darkest, brightest: brightest);
}

// 淡化衬底色取 backgroundTop：五套配色深浅两色下它对正文、次要文字和主色文字都在 5.9:1 以上，每格总能淡化达标。
ui.Color wallpaperVeilColor(CampusPalette palette) => palette.backgroundTop;

// 每格最小淡化透明度：衬底色叠在该格最不利的像素上（浅色看最暗、深色看最亮），正文、次要文字和主色文字都不低于 4.8:1。
// 混色按 sRGB 通道计算，与界面实际合成方式一致。用户调的淡化量不在这里加，见 wallpaperVeilAlpha：
// 拖动滑杆时每帧只做一次加法，不重算这份网格。
Float64List wallpaperVeilAlphas(WallpaperTone tone, CampusPalette palette) {
  final veil = wallpaperVeilColor(palette);
  final texts = [palette.onSurface, palette.onSurfaceVariant, palette.primary].map((color) => color.computeLuminance()).toList();
  final worst = palette.isDark ? tone.brightest : tone.darkest;
  final alphas = Float64List(tone.columns * tone.rows);
  for (var cell = 0; cell < alphas.length; cell++) {
    final pixel = [for (var channel = 0; channel < 3; channel++) worst[cell * 3 + channel] / 255];
    bool readable(double alpha) {
      final mixed = _luminance255(
        (veil.r * alpha + pixel[0] * (1 - alpha)) * 255,
        (veil.g * alpha + pixel[1] * (1 - alpha)) * 255,
        (veil.b * alpha + pixel[2] * (1 - alpha)) * 255,
      );
      return texts.every((text) => (math.max(text, mixed) + .05) / (math.min(text, mixed) + .05) >= _targetContrast);
    }

    var low = 0.0, high = 1.0;
    if (!readable(low)) {
      for (var step = 0; step < 14; step++) {
        final middle = (low + high) / 2;
        if (readable(middle)) {
          high = middle;
        } else {
          low = middle;
        }
      }
    } else {
      high = 0;
    }
    alphas[cell] = high;
  }
  return _smooth(_smooth(alphas, tone.columns, tone.rows, dilate: true), tone.columns, tone.rows, dilate: false);
}

// 用户淡化量 fade（0–1）叠在可读下限 floor 之上：fade 为 0 时就是下限，为 1 时整张盖满（等于看不到图）。
// 结果单调不低于 floor，可读性保证不受淡化量影响。
double wallpaperVeilAlpha(double floor, double fade) => floor + (1 - floor) * fade;

// 先 3×3 取最大再 3×3 取平均：相邻格的透明度从阶跃变为约三格宽的平滑过渡，壁纸上不显网格；
// 膨胀后每格周围 3×3 都不低于它原本所需，取平均仍不低于所需，可读性保证不变。
Float64List _smooth(Float64List values, int columns, int rows, {required bool dilate}) {
  final result = Float64List(values.length);
  for (var row = 0; row < rows; row++) {
    for (var column = 0; column < columns; column++) {
      var maximum = 0.0, sum = 0.0, count = 0;
      for (var neighborRow = math.max(0, row - 1); neighborRow <= math.min(rows - 1, row + 1); neighborRow++) {
        for (var neighborColumn = math.max(0, column - 1); neighborColumn <= math.min(columns - 1, column + 1); neighborColumn++) {
          final value = values[neighborRow * columns + neighborColumn];
          maximum = math.max(maximum, value);
          sum += value;
          count++;
        }
      }
      result[row * columns + column] = dilate ? maximum : sum / count;
    }
  }
  return result;
}

// 留出取样与玻璃栏叠加的余量：4.6 时深色浮动底栏标签在白色区域上只剩 4.56:1（模拟器实测），取 4.8。
const _targetContrast = 4.8;

double _luminance(int red, int green, int blue) => _luminance255(red.toDouble(), green.toDouble(), blue.toDouble());

double _luminance255(double red, double green, double blue) {
  double linear(double value) {
    final channel = value / 255;
    return channel <= .04045 ? channel / 12.92 : math.pow((channel + .055) / 1.055, 2.4).toDouble();
  }

  return .2126 * linear(red) + .7152 * linear(green) + .0722 * linear(blue);
}
