import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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
    for (final palette in [...CampusPalette.values, ...CampusPalette.darkValues]) {
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
            '${directory.path}/${palette.id}-${palette.brightness.name}-${(phase * 4).round()}.png',
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
    // 云雾按定时器一拍一拍地走（见 campus_background.dart 的 _tick），流动与否看进度变没变。
    final flowing = (tester.widget<CustomPaint>(find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter is AtmospherePainter)).painter! as AtmospherePainter).progress;
    final before = flowing.value;
    await tester.pump(const Duration(seconds: 3));
    expect(flowing.value, isNot(before));
    expect(builds, count);
    update(() => phase = .5);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('弹窗、弹层开着时云雾停在原处（不逼着整屏模糊逐帧重算），关掉后从原处接着流动', (tester) async {
    final overlays = ValueNotifier(0);
    addTearDown(overlays.dispose);
    await tester.pumpWidget(MaterialApp(home: CampusMotion(child: CampusAtmosphere(overlays: overlays, child: const SizedBox.expand()))));
    Animation<double> progress() => (tester.widget<CustomPaint>(find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter is AtmospherePainter)).painter! as AtmospherePainter).progress;
    await tester.pump(const Duration(seconds: 3));
    expect(progress().value, closeTo(3 / 24, .01));
    overlays.value = 1;
    await tester.pump();
    final paused = progress().value;
    await tester.pump(const Duration(seconds: 3));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(progress().value, paused);
    overlays.value = 0;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(progress().value, closeTo(paused + 1 / 24, .01));
    await tester.pumpWidget(const SizedBox());
  });

  // [人工决策] 见 lib/theme/campus_background.dart 的 _tick：云雾每秒只更新约 20 次、先画成半分辨率贴图，低电量（iOS）与省电模式（安卓）下停住。
  testWidgets('云雾每秒只更新约 20 次、用半分辨率贴图，低电量与省电模式下停住，关掉后从原处接着走', (tester) async {
    await tester.pumpWidget(MaterialApp(home: CampusMotion(child: CampusAtmosphere(child: const SizedBox.expand()))));
    final painter = tester.widget<CustomPaint>(find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter is AtmospherePainter)).painter! as AtmospherePainter;
    final progress = painter.progress;
    expect(painter.cache, isNotNull);
    var changes = 0;
    void count() => changes++;
    progress.addListener(count);
    // 按 120Hz 的屏幕逐帧推进一秒。
    for (var frame = 0; frame < 120; frame++) {
      await tester.pump(const Duration(microseconds: 8333));
    }
    expect(changes, inInclusiveRange(18, 21));
    expect(progress.value, closeTo(1 / 24, .01));
    Future<void> lowPower(bool on) => tester.binding.defaultBinaryMessenger.handlePlatformMessage('superxd/native_ui', const StandardMethodCodec().encodeMethodCall(MethodCall('lowPower', on)), (_) {});
    await lowPower(true);
    await tester.pump();
    final paused = progress.value;
    await tester.pump(const Duration(seconds: 2));
    expect(progress.value, paused);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await lowPower(false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(progress.value, closeTo(paused + 1 / 24, .01));
    progress.removeListener(count);
    await tester.pumpWidget(const SizedBox());
  }, variant: const TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}));

  // 颗粒的小圆点拼成一组一次画完（见 FrostTexture）：不逐个画圆，也不经离屏贴图，图案同原来逐点画的小圆一样。
  testWidgets('颗粒每张表面一次画完，图案同逐点画的一样', (tester) async {
    // 直接画进录制再转成图片（不对渲染树截图），按测试的像素密度 3 对比；两边都按卡片的圆角裁剪（原来的颗粒自带圆角裁剪，现在由卡片裁）。
    Future<List<int>> pixels(CustomPainter painter, double radius) async {
      final recorder = ui.PictureRecorder();
      const size = Size(150, 100);
      final canvas = Canvas(recorder)
        ..scale(3)
        ..clipRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)));
      painter.paint(canvas, size);
      final picture = recorder.endRecording();
      final image = await picture.toImage(450, 300);
      final bytes = (await image.toByteData())!.buffer.asUint8List().toList();
      image.dispose();
      picture.dispose();
      return bytes;
    }
    for (final radius in const [0.0, 24.0]) {
      await tester.pumpWidget(MaterialApp(home: Center(child: SizedBox(width: 150, height: 100, child: FrostTexture(radius: radius)))));
      final painter = tester.widget<CustomPaint>(find.descendant(of: find.byType(FrostTexture), matching: find.byType(CustomPaint))).painter!;
      final canvas = _CountingCanvas();
      painter.paint(canvas, const Size(390, 800));
      expect([canvas.circles, canvas.shapes, canvas.points], [0, 0, 1]);
      final reference = _DottedGrain(CampusPalette.of(tester.element(find.byType(FrostTexture))).onSurfaceVariant);
      final (drawn, expected) = (await tester.runAsync(() async => (await pixels(painter, radius), await pixels(reference, radius))))!;
      expect(drawn.length, expected.length);
      var differs = 0;
      for (var index = 0; index < drawn.length; index++) {
        if ((drawn[index] - expected[index]).abs() > 2) differs++;
      }
      expect(differs, 0, reason: 'radius=$radius');
      expect(expected.any((value) => value > 0), isTrue);
    }
  });
  // 云雾先画成半分辨率贴图再整屏贴上（见 AtmosphereCache）：同直接画对照，按像素密度 3 渲染，差别不到肉眼可辨的程度。
  for (final palette in [...CampusPalette.values, ...CampusPalette.darkValues]) {
    test('${palette.label}${palette.isDark ? '（深色）' : ''}云雾半分辨率贴图同直接画看不出差别', () async {
      const size = Size(130, 280), ratio = 3.0;
      Future<Uint8List> render(AtmosphereCache? cache, double phase) async {
        final recorder = ui.PictureRecorder();
        AtmospherePainter(progress: AlwaysStoppedAnimation(phase), highContrast: false, palette: palette, cache: cache, ratio: ratio).paint(Canvas(recorder)..scale(ratio), size);
        final picture = recorder.endRecording();
        final image = await picture.toImage((size.width * ratio).toInt(), (size.height * ratio).toInt());
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
        image.dispose();
        picture.dispose();
        return bytes;
      }
      final cache = AtmosphereCache();
      addTearDown(cache.dispose);
      for (final phase in const [0.0, .37, .81]) {
        final direct = await render(null, phase), cached = await render(cache, phase);
        var total = 0, worst = 0;
        for (var index = 0; index < direct.length; index++) {
          final difference = (direct[index] - cached[index]).abs();
          total += difference;
          if (difference > worst) worst = difference;
        }
        debugPrint('[AtmosphereTest] palette=${palette.id} phase=$phase cacheMean=${(total / direct.length).toStringAsFixed(3)} cacheMax=$worst');
        expect(total / direct.length, lessThan(1));
        expect(worst, lessThanOrEqualTo(6));
      }
    });
  }
}

// 原来的逐点画法，作对照。
class _DottedGrain extends CustomPainter {
  const _DottedGrain(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withValues(alpha: .016);
    for (var y = 3.0; y < size.height; y += 12) {
      for (var x = 3.0; x < size.width; x += 12) {
        canvas.drawCircle(Offset(x + (y.toInt() % 7), y), .55, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DottedGrain oldDelegate) => false;
}

class _CountingCanvas implements Canvas {
  int circles = 0, shapes = 0, points = 0;
  @override
  void drawCircle(Offset center, double radius, Paint paint) => circles++;
  @override
  void drawRawPoints(ui.PointMode pointMode, Float32List points, Paint paint) => this.points++;
  @override
  void drawRRect(RRect rrect, Paint paint) => shapes++;
  @override
  void drawRect(Rect rect, Paint paint) => shapes++;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
