import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/page/festival/reward_kit.dart';

// 单独一个文件：RewardSprites.load 的结果全局缓存，在 festival_test.dart 的界面测试里先被假时钟下的揭晓调过，会一直等不完。
void main() {
  // 粒子贴图在 CPU 上算好再上传（见 RewardSprites）：同原来用画布画的三格对照，边缘抗锯齿的写法不同，差别不到肉眼可辨的程度。
  test('粒子贴图不经离屏渲染，三格同原来画布画的一样', () async {
    expect(RewardSprites.image, isNull);
    await RewardSprites.load();
    final image = RewardSprites.image!;
    expect([image.width, image.height], [192, 64]);
    final drawn = (await image.toByteData())!.buffer.asUint8List();
    final recorder = ui.PictureRecorder();
    _paintSpritesOnCanvas(Canvas(recorder));
    final picture = recorder.endRecording();
    final reference = await picture.toImage(192, 64);
    final expected = (await reference.toByteData())!.buffer.asUint8List();
    reference.dispose();
    picture.dispose();
    for (final (name, from) in [('dot', 0), ('star', 64), ('streak', 128)]) {
      var total = 0, worst = 0, lit = 0;
      for (var y = 0; y < 64; y++) {
        for (var x = from; x < from + 64; x++) {
          final index = (y * 192 + x) * 4 + 3;
          final difference = (drawn[index] - expected[index]).abs();
          total += difference;
          if (difference > worst) worst = difference;
          if (drawn[index] > 0) lit++;
        }
      }
      debugPrint('[RewardSpritesTest] sprite=$name mean=${(total / 4096).toStringAsFixed(3)} max=$worst lit=$lit');
      expect(total / 4096, lessThan(1), reason: name);
      expect(worst, lessThanOrEqualTo(40), reason: name);
      expect(lit, greaterThan(40), reason: name);
    }
  });
}

// 原来用画布画粒子贴图的写法（以前画完再 toImageSync），作对照。
void _paintSpritesOnCanvas(Canvas canvas) {
  const white = Color(0xFFFFFFFF);
  canvas.drawCircle(const Offset(32, 32), 32, Paint()..shader = ui.Gradient.radial(const Offset(32, 32), 32, [white, white.withValues(alpha: .42), white.withValues(alpha: .1), white.withValues(alpha: 0)], [0, .18, .5, 1]));
  canvas.drawCircle(const Offset(96, 32), 14, Paint()..shader = ui.Gradient.radial(const Offset(96, 32), 14, [white.withValues(alpha: .7), white.withValues(alpha: 0)]));
  final star = Path();
  for (var arm = 0; arm < 4; arm++) {
    final angle = arm * math.pi / 2;
    final tip = Offset(96 + math.cos(angle) * 30, 32 + math.sin(angle) * 30);
    final side = Offset(math.cos(angle + math.pi / 2), math.sin(angle + math.pi / 2)) * 2.6;
    star
      ..moveTo(96 + side.dx, 32 + side.dy)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(96 - side.dx, 32 - side.dy)
      ..close();
  }
  canvas.drawPath(star, Paint()..shader = ui.Gradient.radial(const Offset(96, 32), 30, [white, white.withValues(alpha: .55), white.withValues(alpha: 0)], [0, .35, 1]));
  canvas.drawRRect(RRect.fromLTRBR(132, 27, 188, 37, const Radius.circular(5)), Paint()..shader = ui.Gradient.linear(const Offset(132, 0), const Offset(188, 0), [white.withValues(alpha: 0), white.withValues(alpha: .45), white], [0, .7, 1]));
}
