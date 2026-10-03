import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;

import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/page/appearance_page.dart';
import 'package:superxd/theme/campus_background.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/theme/wallpaper_tone.dart';

Future<Uint8List> _png(int width, int height, void Function(Canvas canvas, Size size) draw) async {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder), Size(width.toDouble(), height.toDouble()));
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

// 与实现无关的对比度核对：衬底色按透明度叠在最不利的像素上（sRGB 通道混合），再算 WCAG 对比度。
double _luminance(double red, double green, double blue) {
  double linear(double channel) => channel <= .04045 ? channel / 12.92 : math.pow((channel + .055) / 1.055, 2.4).toDouble();
  return .2126 * linear(red) + .7152 * linear(green) + .0722 * linear(blue);
}

double _contrast(double first, double second) => (math.max(first, second) + .05) / (math.min(first, second) + .05);

WallpaperTone _tone(int columns, int rows, List<int> Function(int cell) darkest, List<int> Function(int cell) brightest) => WallpaperTone(
  width: columns * 100,
  height: rows * 100,
  columns: columns,
  rows: rows,
  darkest: Uint8List.fromList([for (var cell = 0; cell < columns * rows; cell++) ...darkest(cell)]),
  brightest: Uint8List.fromList([for (var cell = 0; cell < columns * rows; cell++) ...brightest(cell)]),
);

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var attempt = 0; attempt < 1000 && !done(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

// 业务完成信号（设置已写入、文件已删除）先于页面“保存中/导入中”的收尾：继续让真实异步跑到加载提示消失，再按控件动画时长推进，
// 不用 pumpAndSettle 等“绝对静止”（慢机器上转圈还在播，CI 曾在清除壁纸后超时）。点按发生在真实异步里，先出一帧再看提示。
Future<void> _settled(WidgetTester tester) async {
  await tester.pump();
  for (var attempt = 0; attempt < 1000 && find.byType(CampusLoading).evaluate().isNotEmpty; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  expect(find.byType(CampusLoading), findsNothing);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('色调网格按原图比例划分，记下每格最暗与最亮像素，编码可往返、损坏时拒绝', (tester) async {
    final tone = (await tester.runAsync(() async => measureWallpaper(await _png(64, 128, (canvas, size) {
      canvas.drawRect(Offset.zero & Size(size.width, size.height / 2), Paint()..color = const Color(0xFF000000));
      canvas.drawRect(Rect.fromLTWH(0, size.height / 2, size.width, size.height / 2), Paint()..color = const Color(0xFFFFFFFF));
      // 左下角一格（原图4×4像素）里放一个2×2黑点：该格最暗近黑、最亮仍为白，其余下半格最暗为白。
      canvas.drawRect(Rect.fromLTWH(0, size.height - 2, 2, 2), Paint()..color = const Color(0xFF000000));
    }))))!;
    expect([tone.width, tone.height, tone.columns, tone.rows], [64, 128, 16, 32]);
    int darkest(int row, int column) => tone.darkest[(row * tone.columns + column) * 3];
    int brightest(int row, int column) => tone.brightest[(row * tone.columns + column) * 3];
    expect(darkest(0, 5), lessThan(10));
    expect(brightest(0, 5), lessThan(10));
    expect(darkest(20, 5), greaterThan(245));
    expect(darkest(31, 0), lessThan(40));
    expect(brightest(31, 0), greaterThan(245));
    final copy = WallpaperTone.decode(tone.encode())!;
    expect([copy.width, copy.height, copy.columns, copy.rows], [64, 128, 16, 32]);
    expect(copy.darkest, tone.darkest);
    expect(WallpaperTone.decode('{"width":1}'), isNull);
    expect(WallpaperTone.decode('不是JSON'), isNull);
    expect(WallpaperTone.decode(tone.encode().replaceFirst('"columns":16', '"columns":15')), isNull);
    expect(WallpaperTone.decode(null), isNull);
    final landscape = (await tester.runAsync(() async => measureWallpaper(await _png(300, 100, (canvas, size) => canvas.drawColor(const Color(0xFF808080), BlendMode.src)))))!;
    expect([landscape.columns, landscape.rows], [48, 16]);
    expect(await tester.runAsync(() async {
      try {
        await measureWallpaper(Uint8List.fromList(List.filled(64, 7)));
        return false;
      } catch (_) {
        return true;
      }
    }), isTrue);
  });

  test('五配色深浅两色在纯黑、纯白、棋盘格与随机色上逐格淡化后，正文、次要文字与主色文字均不低于4.5:1', () {
    final random = math.Random(7);
    final tones = {
      '纯黑': _tone(16, 32, (_) => [0, 0, 0], (_) => [0, 0, 0]),
      '纯白': _tone(16, 32, (_) => [255, 255, 255], (_) => [255, 255, 255]),
      '棋盘格': _tone(16, 32, (_) => [0, 0, 0], (_) => [255, 255, 255]),
      '随机': _tone(16, 32, (_) => [for (var channel = 0; channel < 3; channel++) random.nextInt(256)], (_) => [for (var channel = 0; channel < 3; channel++) random.nextInt(256)]),
    };
    for (final palette in [...CampusPalette.values, ...CampusPalette.darkValues]) {
      final veil = wallpaperVeilColor(palette);
      final texts = [palette.onSurface, palette.onSurfaceVariant, palette.primary].map((color) => color.computeLuminance());
      for (final entry in tones.entries) {
        final tone = entry.value;
        final alphas = wallpaperVeilAlphas(tone, palette);
        final worst = palette.isDark ? tone.brightest : tone.darkest;
        for (var cell = 0; cell < alphas.length; cell++) {
          final alpha = alphas[cell];
          final mixed = _luminance(
            veil.r * alpha + worst[cell * 3] / 255 * (1 - alpha),
            veil.g * alpha + worst[cell * 3 + 1] / 255 * (1 - alpha),
            veil.b * alpha + worst[cell * 3 + 2] / 255 * (1 - alpha),
          );
          for (final text in texts) {
            expect(_contrast(text, mixed), greaterThanOrEqualTo(4.5), reason: '${palette.id} ${palette.isDark} ${entry.key} cell=$cell');
          }
          // 用户淡化量只会在下限之上加，单调、拉满即整张盖住。
          var previous = alpha;
          for (final fade in [0.0, .25, .5, .75, 1.0]) {
            final veiled = wallpaperVeilAlpha(alpha, fade);
            expect(veiled, greaterThanOrEqualTo(previous - 1e-12));
            expect(veiled, lessThanOrEqualTo(1));
            previous = veiled;
          }
          expect(wallpaperVeilAlpha(alpha, 0), alpha);
          expect(wallpaperVeilAlpha(alpha, 1), 1);
        }
      }
      // 单格暗斑：淡化从峰值向四周约三格平滑下降，相邻格之差不超过峰值的三分之一，壁纸上不显网格。
      final spot = _tone(16, 32, (cell) => cell == 16 * 15 + 8 ? (palette.isDark ? [255, 255, 255] : [0, 0, 0]) : (palette.isDark ? [0, 0, 0] : [255, 255, 255]), (cell) => cell == 16 * 15 + 8 ? (palette.isDark ? [255, 255, 255] : [0, 0, 0]) : (palette.isDark ? [0, 0, 0] : [255, 255, 255]));
      final bump = wallpaperVeilAlphas(spot, palette);
      final peak = bump.reduce(math.max);
      expect(peak, greaterThan(.3), reason: palette.id);
      for (var row = 0; row < 32; row++) {
        for (var column = 0; column < 15; column++) {
          expect((bump[row * 16 + column] - bump[row * 16 + column + 1]).abs(), lessThanOrEqualTo(peak / 3 + 1e-9), reason: '${palette.id} $row $column');
        }
      }
      // 浅色壁纸在浅色主题下本就可读，不额外淡化。
      if (!palette.isDark) expect(wallpaperVeilAlphas(tones['纯白']!, palette).every((alpha) => alpha == 0), isTrue, reason: palette.id);
    }
  });

  testWidgets('设了壁纸时背景不再循环、可停稳，画壁纸与淡化层；外观变化平滑跟随，与云雾互换交叉淡化；高对比度时不画壁纸', (tester) async {
    final bytes = (await tester.runAsync(() => _png(90, 160, (canvas, size) => canvas.drawColor(const Color(0xFF203040), BlendMode.src))))!;
    final tone = (await tester.runAsync(() => measureWallpaper(bytes)))!;
    final look = ValueNotifier((blur: 67, fade: 0));
    addTearDown(look.dispose);
    final wallpaper = CampusWallpaper(image: MemoryImage(bytes), tone: tone, look: look);
    Widget host({bool highContrast = false, bool custom = true}) => MaterialApp(
      theme: campusTheme(),
      home: MediaQuery(data: MediaQueryData(size: const Size(400, 800), highContrast: highContrast), child: CampusAtmosphere(phase: .3, wallpaper: custom ? wallpaper : null, child: const SizedBox.expand())),
    );
    final fog = find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter is AtmospherePainter);
    double sigma() => (tester.widget<ImageFiltered>(find.byType(ImageFiltered)).imageFilter as dynamic).sigmaX as double;
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(sigma(), closeTo(.67 * CampusWallpaper.maxBlurSigma, .01));
    expect(fog, findsNothing);
    // 滑杆改值时模糊平滑跟随，中途是中间值；模糊为 0 时不再套滤镜。
    look.value = (blur: 0, fade: 50);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(sigma(), allOf(greaterThan(0), lessThan(.67 * CampusWallpaper.maxBlurSigma)));
    await tester.pumpAndSettle();
    expect(find.byType(ImageFiltered), findsNothing);
    // 恢复云雾：中途两层同在、交叉淡化，结束只剩云雾。
    await tester.pumpWidget(host(custom: false));
    await tester.pump(const Duration(milliseconds: 200));
    expect([find.byType(Image).evaluate().length, fog.evaluate().length], [1, 1]);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    // 换上壁纸：先解码好再换，解码完成前仍是云雾（不先淡到底色）；完成后从云雾直接交叉淡化到图片。
    await tester.pumpWidget(host());
    await tester.pump();
    expect([find.byType(Image).evaluate().length, fog.evaluate().length], [0, 1]);
    for (var attempt = 0; attempt < 200 && find.byType(Image).evaluate().isEmpty; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect([find.byType(Image).evaluate().length, fog.evaluate().length], [1, 1]);
    await tester.pumpAndSettle();
    expect([find.byType(Image).evaluate().length, fog.evaluate().length], [1, 0]);
    await tester.pumpWidget(host(highContrast: true));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(fog, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('界面页导入壁纸：只留一份并删掉缓存副本，可调模糊淡化、恢复云雾；取消不提示，坏图与超限原地提示', (tester) async {
    final directory = (await tester.runAsync(() => Directory.systemTemp.createTemp('wallpaper-')))!;
    addTearDown(() => directory.deleteSync(recursive: true));
    final wallpaperDirectory = Directory('${directory.path}/wallpaper');
    final settings = DisplaySettings.memory(wallpaperDirectory: wallpaperDirectory);
    String? next;
    var picks = 0;
    // 假选图：清理即删掉自己的临时文件，用来核对页面无论成败都会清理。
    Future<PickedWallpaper?> pick() async {
      picks++;
      final chosen = next;
      return chosen == null ? null : (path: chosen, discard: () => File(chosen).delete());
    }

    Future<String> picked(String name, List<int> bytes) async {
      final file = File('${directory.path}/$name');
      await file.writeAsBytes(bytes);
      return file.path;
    }

    await tester.pumpWidget(MaterialApp(
      theme: campusTheme(),
      builder: (context, child) => DisplayScope(settings: settings, child: child!),
      home: AppearancePage(pickWallpaper: pick),
    ));
    await tester.pumpAndSettle();
    expect(find.text('模糊'), findsNothing);
    // 取消选图：不提示、不改设置。
    await tester.runAsync(() async {
      await tester.tap(find.text('自定义图片'));
      await _until(tester, () => picks == 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await _settled(tester);
    expect(settings.wallpaperFile, isNull);
    expect(find.textContaining('请'), findsNothing);
    // 坏图：原地提示，缓存副本照样删除。
    next = (await tester.runAsync(() => picked('broken.jpg', List.filled(64, 7))))!;
    await tester.runAsync(() async {
      await tester.tap(find.text('自定义图片'));
      await _until(tester, () => !File(next!).existsSync());
    });
    await _settled(tester);
    expect(find.text('无法读取这张图片，请换一张'), findsOneWidget);
    expect(File(next).existsSync(), isFalse);
    expect(settings.wallpaperFile, isNull);
    // 超过20MB：不解码，直接提示。
    next = (await tester.runAsync(() async {
      final file = File('${directory.path}/huge.jpg');
      final handle = await file.open(mode: FileMode.write);
      await handle.setPosition(DisplaySettings.wallpaperMaxBytes);
      await handle.writeByte(0);
      await handle.close();
      return file.path;
    }))!;
    await tester.runAsync(() async {
      await tester.tap(find.text('自定义图片'));
      await _until(tester, () => !File(next!).existsSync());
    });
    await _settled(tester);
    expect(find.text('图片超过20MB，请换一张'), findsOneWidget);
    // 正常导入两次：目录只留最新一份，缓存副本删除。
    for (final name in ['first.png', 'second.png']) {
      next = (await tester.runAsync(() async => picked(name, await _png(60, 120, (canvas, size) => canvas.drawColor(const Color(0xFF406080), BlendMode.src)))))!;
      final before = settings.wallpaperFile;
      await tester.runAsync(() async {
        await tester.tap(find.text(before == null ? '自定义图片' : '更换图片'));
        await _until(tester, () => settings.wallpaperFile != null && settings.wallpaperFile?.path != before?.path && !File(next!).existsSync());
      });
      await _settled(tester);
    }
    expect(find.textContaining('请换一张'), findsNothing);
    expect(File(next!).existsSync(), isFalse);
    expect(wallpaperDirectory.listSync().map((entity) => entity.path), [settings.wallpaperFile!.path]);
    expect(WallpaperTone.decode(settings.wallpaperTone), isNotNull);
    expect([settings.wallpaperBlur, settings.wallpaperFade], [DisplaySettings.defaultWallpaperBlur, 0]);
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('透明度'), 120, scrollable: list);
    await tester.pumpAndSettle();
    expect(find.text('${DisplaySettings.defaultWallpaperBlur}%'), findsOneWidget);
    // 拖动中只预览（背景与百分比实时变化），松手才落库。
    final fade = find.byType(Slider).last;
    final gesture = await tester.startGesture(tester.getCenter(fade) - Offset(tester.getSize(fade).width / 2 - 24, 0));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    final previewed = settings.wallpaperLook.value.fade;
    expect(previewed, greaterThan(0));
    expect(settings.wallpaperFade, 0);
    expect(find.text('$previewed%'), findsOneWidget);
    await gesture.up();
    await tester.pump();
    expect(settings.wallpaperFade, previewed);
    // 玻璃滑杆的读屏增减没有松手回调：停手后补存。
    campusGlassReady.value = true;
    addTearDown(() => campusGlassReady.value = false);
    final handle = tester.ensureSemantics();
    await tester.pump();
    expect(find.byType(liquid.GlassSlider), findsNWidgets(2));
    tester.semantics.increase(find.semantics.byPredicate((node) => node.label == '模糊' && node.getSemanticsData().hasAction(SemanticsAction.increase)));
    await tester.pump();
    expect(settings.wallpaperBlur, DisplaySettings.defaultWallpaperBlur);
    await tester.pump(const Duration(milliseconds: 400));
    expect(settings.wallpaperBlur, greaterThan(DisplaySettings.defaultWallpaperBlur));
    handle.dispose();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('默认云雾'), -120, scrollable: list);
    await tester.runAsync(() async {
      await tester.tap(find.text('默认云雾'));
      await _until(tester, () => settings.wallpaperFile == null && wallpaperDirectory.listSync().isEmpty);
    });
    await _settled(tester);
    expect(settings.wallpaperFile, isNull);
    expect(wallpaperDirectory.listSync(), isEmpty);
    expect(find.text('模糊'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  });
}
