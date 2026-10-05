// 生成界面页的字体预览图（assets/font_previews）。改了预览文字、字号或换了内置字体后重跑：
// PUB_HOSTED_URL=https://pub.dev flutter test tool/font_previews.dart
// 用真实引擎按页面里同样的文字样式（卡片默认样式叠加预览样式）以 3 倍像素绘制，白色字形、透明底，页面里按配色着色。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/local/display_settings.dart';
import 'package:superxd/page/appearance_page.dart';
import 'package:superxd/theme/campus_theme.dart';

void main() {
  testWidgets('生成字体预览图', (tester) async {
    await tester.runAsync(() async {
      for (final family in {'Maple Mono NF CN': 'maple_mono_nf_cn', 'Noto Serif SC': 'noto_serif_sc'}.entries) {
        final loader = FontLoader(family.key);
        for (final weight in ['regular', 'medium', 'semibold']) {
          loader.addFont(File('assets/fonts/${family.value}_$weight.ttf').readAsBytes().then(ByteData.sublistView));
        }
        await loader.load();
      }
    });
    for (final entry in DisplaySettings.fontFamilies.entries) {
      late TextStyle style;
      await tester.pumpWidget(MaterialApp(theme: campusTheme(fontFamily: entry.value), home: Material(child: Builder(builder: (context) {
        style = DefaultTextStyle.of(context).style.merge(fontPreviewStyle(entry.value)).copyWith(color: Colors.white);
        return const SizedBox();
      }))));
      await tester.runAsync(() async {
        final painter = TextPainter(text: TextSpan(text: fontPreviewText, style: style), textDirection: TextDirection.ltr)..layout();
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..scale(fontPreviewScale);
        painter.paint(canvas, Offset.zero);
        final image = await recorder.endRecording().toImage((painter.width * fontPreviewScale).ceil(), (painter.height * fontPreviewScale).ceil());
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('assets/font_previews/${entry.key}.png').writeAsBytes(png!.buffer.asUint8List());
        painter.dispose();
      });
    }
  });
}
