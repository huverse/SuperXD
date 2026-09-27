import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/theme/campus_background.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_palette.dart';

const _size = Size(180, 320);
Future<Uint8List> _render(
  CampusPalette palette,
  double phase, {
  bool highContrast = false,
  Size size = _size,
}) async {
  final recorder = ui.PictureRecorder();
  AtmospherePainter(
    progress: AlwaysStoppedAnimation(phase),
    highContrast: highContrast,
    palette: palette,
  ).paint(Canvas(recorder), size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
      .buffer
      .asUint8List();
  image.dispose();
  picture.dispose();
  return bytes;
}

({double mean, double changedFraction, int maximum}) _difference(
  Uint8List before,
  Uint8List after,
) {
  var total = 0;
  var changed = 0;
  var maximum = 0;
  for (var offset = 0; offset < before.length; offset += 4) {
    var pixel = 0;
    for (var channel = 0; channel < 3; channel++) {
      final difference = (before[offset + channel] - after[offset + channel])
          .abs();
      total += difference;
      pixel = math.max(pixel, difference);
      maximum = math.max(maximum, difference);
    }
    if (pixel >= 4) changed++;
  }
  return (
    mean: total / (before.length / 4 * 3),
    changedFraction: changed / (before.length / 4),
    maximum: maximum,
  );
}

double _contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance(), b = background.computeLuminance();
  return (math.max(a, b) + .05) / (math.min(a, b) + .05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final palette in CampusPalette.values) {
    test('${palette.label}柔雾六秒可辨、短帧平滑、完整周期首尾连续', () async {
      final initial = await _render(palette, 0);
      final short = _difference(initial, await _render(palette, 1 / (24 * 60)));
      final sixSeconds = _difference(initial, await _render(palette, .25));
      final seam = _difference(initial, await _render(palette, 1));
      debugPrint(
        '[AtmosphereTest] palette=${palette.id} sixSecondsMean=${sixSeconds.mean.toStringAsFixed(2)} changed=${sixSeconds.changedFraction.toStringAsFixed(2)} frameMean=${short.mean.toStringAsFixed(3)} seam=${seam.mean}',
      );
      expect(sixSeconds.mean, greaterThan(3));
      expect(sixSeconds.changedFraction, greaterThan(.25));
      expect(short.mean, lessThan(.2));
      expect(short.maximum, lessThanOrEqualTo(2));
      expect(seam.mean, lessThan(.03));
    });
    test('${palette.label}云雾不退化为近纯色底，实际留白保留光色变化', () async {
      final base = await _render(palette, 0, highContrast: true);
      final fog = await _render(palette, 0);
      final difference = _difference(base, fog);
      expect(difference.mean, greaterThan(8));
      expect(difference.changedFraction, greaterThan(.65));
    });
    test('${palette.label}各相位实际背景与卡片合成色对比度保持4.5', () async {
      var minimum = double.infinity;
      for (final size in [_size, const Size(320, 180), const Size(192, 192)]) {
        for (var phase = 0; phase < 8; phase++) {
          final pixels = await _render(palette, phase / 8, size: size);
          for (var offset = 0; offset < pixels.length; offset += 16) {
            expect(pixels[offset + 3], 255);
            final background = Color.fromARGB(
              255,
              pixels[offset],
              pixels[offset + 1],
              pixels[offset + 2],
            );
            for (final surface in [
              background,
              Color.alphaBlend(
                palette.surface.withValues(alpha: .91),
                background,
              ),
            ]) {
              minimum = math.min(
                minimum,
                _contrast(palette.onSurfaceVariant, surface),
              );
              minimum = math.min(
                minimum,
                _contrast(palette.onSurface, surface),
              );
              minimum = math.min(minimum, _contrast(palette.primary, surface));
            }
          }
        }
      }
      expect(
        minimum,
        greaterThanOrEqualTo(4.5),
        reason: '${palette.id}: $minimum',
      );
    });
  }
  testWidgets('五主题实际磨砂卡片合成，留白层次与正文同时保留', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      final font = FontLoader('Maple Mono NF CN')..addFont(rootBundle.load('assets/fonts/maple_mono_nf_cn_regular.ttf'));
      await font.load();
    });
    final boundaryKey = GlobalKey();
    for (final palette in CampusPalette.values) {
      final frames = <Uint8List>[];
      for (final phase in [0.0, .25, .5, .75]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: campusTheme(palette: palette),
            home: RepaintBoundary(
              key: boundaryKey,
              child: CampusAtmosphere(
                phase: phase,
                child: Scaffold(
                  body: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        const SizedBox(
                          height: 56,
                          child: Center(child: Text('2026-09-25 周五')),
                        ),
                        const SizedBox(height: 24),
                        for (var index = 0; index < 4; index++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: CampusSurface(
                              child: SizedBox(
                                width: double.infinity,
                                height: 108,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      '第${index * 2 + 1}–${index * 2 + 2}节',
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: palette.primary,
                                      ),
                                    ),
                                    const Text('08:00–09:40'),
                                    Text(
                                      '课程 ${index + 1}',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: palette.onSurface,
                                      ),
                                    ),
                                    const Text('教室 · 教师'),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          frames.add(Uint8List.fromList(pixels));
          // 保存在系统临时目录，不把机器相关截图作为仓库golden或主观验收结论。
          final directory = Directory(
            '${Directory.systemTemp.path}/superxd-atmosphere-composite',
          );
          await directory.create(recursive: true);
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!
              .buffer
              .asUint8List();
          await File(
            '${directory.path}/${palette.id}-${(phase * 4).round()}.png',
          ).writeAsBytes(png);
          image.dispose();
        });
      }
      final guttersBefore = <int>[], guttersAfter = <int>[];
      for (var y = 70; y < 780; y++) {
        for (final x in [4, 8, 382, 386]) {
          final offset = (y * 390 + x) * 4;
          guttersBefore.addAll(frames[0].sublist(offset, offset + 4));
          guttersAfter.addAll(frames[1].sublist(offset, offset + 4));
        }
      }
      final changes = _difference(
        Uint8List.fromList(guttersBefore),
        Uint8List.fromList(guttersAfter),
      );
      expect(changes.mean, greaterThan(3), reason: palette.id);
      expect(changes.changedFraction, greaterThan(.4), reason: palette.id);
      expect(tester.takeException(), isNull);
    }
  });
  test('高对比模式不画流光，横竖屏与小尺寸保持不透明', () async {
    final palette = CampusPalette.values.first;
    expect(
      _difference(
        await _render(palette, 0, highContrast: true),
        await _render(palette, .5, highContrast: true),
      ).maximum,
      0,
    );
    for (final size in [
      const Size(320, 180),
      const Size(48, 48),
      const Size(1, 1),
    ]) {
      final bytes = await _render(palette, .73, size: size);
      expect(bytes.length, size.width.toInt() * size.height.toInt() * 4);
      for (var offset = 3; offset < bytes.length; offset += 4) {
        expect(bytes[offset], 255);
      }
    }
  });
  testWidgets('固定相位切换正确启停，不逐帧重建业务child', (tester) async {
    double? phase = .2;
    late StateSetter update;
    var builds = 0;
    final content = Builder(
      builder: (context) {
        builds++;
        return const SizedBox.expand();
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CampusMotion(
          child: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return CampusAtmosphere(phase: phase, child: content);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    update(() => phase = null);
    await tester.pump();
    final count = builds;
    await tester.pump(const Duration(seconds: 3));
    expect(tester.binding.hasScheduledFrame, isTrue);
    expect(builds, count);
    update(() => phase = .5);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
