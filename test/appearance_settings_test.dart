import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/page/appearance_page.dart';
import 'package:superxd/page/text_size_range.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_theme.dart';

import 'form_layout_support.dart';

// 点字号条上某个大小的位置（测试里玻璃没初始化，用的是实色档的系统滑杆，拇指离两端 24）；点一下即拖到并松手。
Future<void> _slideTextSize(WidgetTester tester, double size) async {
  final rect = tester.getRect(find.byType(Slider));
  final fraction = (size - DisplaySettings.textSizeMin) / (DisplaySettings.textSizeMax - DisplaySettings.textSizeMin);
  await tester.tapAt(Offset(rect.left + 24 + fraction * (rect.width - 48), rect.center.dy));
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  test('设备设置v1迁移保留字号，连续修改和重开不互相覆盖', () async {
    final directory = await Directory.systemTemp.createTemp('appearance-');
    final path = '${directory.path}/display.db';
    final old = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) => db.execute(
        'CREATE TABLE display_settings (id INTEGER PRIMARY KEY CHECK(id=1), text_scale REAL NOT NULL)',
      ),
    );
    await old.insert('display_settings', {'id': 1, 'text_scale': 1.25});
    await old.close();
    var settings = await DisplaySettings.open(databasePath: path, systemTextScale: 1);
    // 老的倍数在 v8 换算成实际大小：系统字号 1.0 时 1.25 倍就是 125%。
    expect(settings.textSize, 1.25);
    // v1 升上来时配色列默认是苔灰；苔灰删掉后（10-27）在 v7 换成默认的雾蓝。
    expect(settings.paletteId, 'mist');
    expect(settings.fontId, 'maple');
    await Future.wait([
      settings.setPalette('rose'),
      settings.setFont('serif'),
      settings.setTextSize(1.4),
    ]);
    await settings.close();
    settings = await DisplaySettings.open(databasePath: path);
    expect(settings.paletteId, 'rose');
    expect(settings.fontFamily, 'Noto Serif SC');
    expect(settings.textSize, 1.4);
    await settings.close();
    await directory.delete(recursive: true);
  });
  // 用户要求默认配色改为雾蓝：只改默认值，存过显示设置的保持原样；启动窗口底色跟着默认配色，冷启动不闪别的颜色。
  test('默认配色是雾蓝：新装与没存过显示设置的都是雾蓝，存过的保持原值；启动窗口浅深底色同默认配色', () async {
    expect(DisplaySettings.defaultPaletteId, 'mist');
    expect(DisplaySettings.memory().paletteId, 'mist');
    final directory = await Directory.systemTemp.createTemp('appearance-');
    final path = '${directory.path}/display.db';
    var settings = await DisplaySettings.open(databasePath: path);
    expect(settings.paletteId, 'mist');
    await settings.close();
    // 打开过、但一项都没改的老安装（库里没有行）重开也是雾蓝。
    settings = await DisplaySettings.open(databasePath: path);
    expect(settings.paletteId, 'mist');
    await settings.close();
    final saved = await openDatabase(path);
    await saved.insert('display_settings', {'id': 1, 'text_scale': 1.1, 'palette_id': 'rose'});
    await saved.close();
    settings = await DisplaySettings.open(databasePath: path);
    expect(settings.paletteId, 'rose');
    await settings.close();
    await directory.delete(recursive: true);

    String launch(String folder) => RegExp(r'name="launch_background">(#[0-9A-F]{6})<').firstMatch(File('android/app/src/main/res/$folder/colors.xml').readAsStringSync())!.group(1)!;
    String hex(Color color) => '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
    expect(launch('values'), hex(CampusPalette.byId(DisplaySettings.defaultPaletteId).backgroundTop));
    expect(launch('values-night'), hex(CampusPalette.byId(DisplaySettings.defaultPaletteId, brightness: Brightness.dark).backgroundTop));
    // iOS 的系统启动图底色（LaunchBackground 颜色集，浅深两份）同样跟着默认配色。
    final colors = (jsonDecode(File('ios/Runner/Assets.xcassets/LaunchBackground.colorset/Contents.json').readAsStringSync())['colors'] as List).cast<Map<String, dynamic>>();
    String ios(Map<String, dynamic> entry) {
      final components = entry['color']['components'] as Map<String, dynamic>;
      return '#${[for (final channel in ['red', 'green', 'blue']) (components[channel] as String).substring(2)].join()}';
    }
    expect(ios(colors.firstWhere((entry) => entry['appearances'] == null)), launch('values'));
    expect(ios(colors.firstWhere((entry) => entry['appearances'] != null)), launch('values-night'));
    expect(File('ios/Runner/Base.lproj/LaunchScreen.storyboard').readAsStringSync(), contains('<color key="backgroundColor" name="LaunchBackground"/>'));
  });
  test('设备设置v3迁移默认玻璃自动，玻璃模式与其他设置并发保存后重开保留', () async {
    final directory = await Directory.systemTemp.createTemp('appearance-');
    final path = '${directory.path}/display.db';
    final old = await openDatabase(
      path,
      version: 3,
      onCreate: (db, _) => db.execute(
        "CREATE TABLE display_settings (id INTEGER PRIMARY KEY CHECK(id=1), text_scale REAL NOT NULL, palette_id TEXT NOT NULL DEFAULT 'sage', font_id TEXT NOT NULL DEFAULT 'maple', theme_mode TEXT NOT NULL DEFAULT 'system')",
      ),
    );
    await old.insert('display_settings', {'id': 1, 'text_scale': 1.1, 'palette_id': 'dusk', 'theme_mode': 'dark'});
    await old.close();
    var settings = await DisplaySettings.open(databasePath: path);
    expect(settings.glassMode, 'auto');
    expect(settings.paletteId, 'dusk');
    expect(settings.themeMode, ThemeMode.dark);
    await Future.wait([settings.setGlassMode('reduced'), settings.setTextSize(1.25)]);
    expect(() => settings.setGlassMode('ultra'), throwsArgumentError);
    await settings.close();
    settings = await DisplaySettings.open(databasePath: path);
    expect(settings.glassMode, 'reduced');
    expect(settings.textSize, 1.25);
    expect(settings.paletteId, 'dusk');
    await settings.close();
    await directory.delete(recursive: true);
  });
  test('设备设置v4迁移无壁纸；壁纸与其他设置并发保存后重开保留，启动清孤儿文件，文件丢失按未设置处理', () async {
    final directory = await Directory.systemTemp.createTemp('appearance-');
    final path = '${directory.path}/display.db';
    final wallpapers = Directory('${directory.path}/wallpaper');
    final old = await openDatabase(
      path,
      version: 4,
      onCreate: (db, _) => db.execute(
        "CREATE TABLE display_settings (id INTEGER PRIMARY KEY CHECK(id=1), text_scale REAL NOT NULL, palette_id TEXT NOT NULL DEFAULT 'sage', font_id TEXT NOT NULL DEFAULT 'maple', theme_mode TEXT NOT NULL DEFAULT 'system', glass_mode TEXT NOT NULL DEFAULT 'auto')",
      ),
    );
    await old.insert('display_settings', {'id': 1, 'text_scale': 1.1, 'palette_id': 'oat', 'glass_mode': 'full'});
    await old.close();
    var settings = await DisplaySettings.open(databasePath: path, wallpaperDirectory: wallpapers);
    expect([settings.wallpaperFile, settings.wallpaperTone, settings.wallpaperBlur, settings.wallpaperFade], [null, null, DisplaySettings.defaultWallpaperBlur, 0]);
    expect([settings.paletteId, settings.glassMode], ['oat', 'full']);
    final picked = File('${directory.path}/picked.jpg')..writeAsBytesSync([1, 2, 3]);
    await Future.wait([settings.setWallpaper(picked.path, '色调'), settings.setWallpaperLook(blur: 80, fade: 67), settings.setTextSize(1.25)]);
    expect(() => settings.setWallpaperLook(blur: 101, fade: 0), throwsArgumentError);
    expect(() => settings.previewWallpaper(fade: -1), throwsArgumentError);
    // 预览只改外观、不落库。
    settings.previewWallpaper(blur: 10);
    expect([settings.wallpaperLook.value.blur, settings.wallpaperBlur], [10, 80]);
    final name = settings.wallpaperFile!.path;
    expect(picked.existsSync(), isTrue);
    await settings.close();
    File('${wallpapers.path}/wallpaper_0.jpg').writeAsBytesSync([9]);
    settings = await DisplaySettings.open(databasePath: path, wallpaperDirectory: wallpapers);
    expect([settings.wallpaperFile?.path, settings.wallpaperTone, settings.wallpaperBlur, settings.wallpaperFade, settings.textSize], [name, '色调', 80, 67, 1.25]);
    expect(settings.wallpaperLook.value, (blur: 80, fade: 67));
    expect(wallpapers.listSync().map((entity) => entity.path), [name]);
    await settings.close();
    File(name).deleteSync();
    settings = await DisplaySettings.open(databasePath: path, wallpaperDirectory: wallpapers);
    expect([settings.wallpaperFile, settings.wallpaperTone], [null, null]);
    await settings.close();
    final rows = await (await openDatabase(path)).query('display_settings');
    expect([rows.single['wallpaper_file'], rows.single['wallpaper_tone'], rows.single['palette_id']], [null, null, 'oat']);
    await directory.delete(recursive: true);
  });
  test('设备设置v5迁移：壁纸模糊与淡化三档换算为连续量，观感不变', () async {
    final directory = await Directory.systemTemp.createTemp('appearance-');
    for (final (blur, fade, expected) in [(0, 2, [0, 67]), (1, 0, [DisplaySettings.defaultWallpaperBlur, 0]), (2, 1, [67, 33])]) {
      final path = '${directory.path}/display_$blur$fade.db';
      final old = await openDatabase(
        path,
        version: 5,
        onCreate: (db, _) => db.execute(
          "CREATE TABLE display_settings (id INTEGER PRIMARY KEY CHECK(id=1), text_scale REAL NOT NULL, palette_id TEXT NOT NULL DEFAULT 'sage', font_id TEXT NOT NULL DEFAULT 'maple', theme_mode TEXT NOT NULL DEFAULT 'system', glass_mode TEXT NOT NULL DEFAULT 'auto', wallpaper_file TEXT, wallpaper_tone TEXT, wallpaper_blur INTEGER NOT NULL DEFAULT 1, wallpaper_fade INTEGER NOT NULL DEFAULT 0)",
        ),
      );
      await old.insert('display_settings', {'id': 1, 'text_scale': 1.1, 'wallpaper_blur': blur, 'wallpaper_fade': fade});
      await old.close();
      final settings = await DisplaySettings.open(databasePath: path);
      expect([settings.wallpaperBlur, settings.wallpaperFade, settings.textSize], [...expected, 1.1]);
      await settings.close();
    }
    await directory.delete(recursive: true);
  });
  // [人工决策] 见 local/display_settings.dart 的 paletteIds 与 systemFont（10-27 删苔灰、iOS 默认改回 Maple）。
  test('设备设置v7迁移：苔灰换成雾蓝，iOS 存着的系统字体一次性换成 Maple，之后再选系统字体不再改', () async {
    final directory = await Directory.systemTemp.createTemp('appearance-');
    final path = '${directory.path}/display.db';
    final old = await openDatabase(
      path,
      version: 6,
      onCreate: (db, _) => db.execute(
        "CREATE TABLE display_settings (id INTEGER PRIMARY KEY CHECK(id=1), text_scale REAL NOT NULL, palette_id TEXT NOT NULL DEFAULT 'sage', font_id TEXT NOT NULL DEFAULT 'maple', theme_mode TEXT NOT NULL DEFAULT 'system', glass_mode TEXT NOT NULL DEFAULT 'auto', wallpaper_file TEXT, wallpaper_tone TEXT, wallpaper_blur INTEGER NOT NULL DEFAULT 27, wallpaper_fade INTEGER NOT NULL DEFAULT 0)",
      ),
    );
    await old.insert('display_settings', {'id': 1, 'text_scale': 1.25, 'palette_id': 'sage', 'font_id': 'system', 'theme_mode': 'dark'});
    await old.close();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      var settings = await DisplaySettings.open(databasePath: path);
      expect([settings.paletteId, settings.fontId, settings.textSize, settings.themeMode], ['mist', 'maple', 1.25, ThemeMode.dark]);
      await settings.setFont(DisplaySettings.systemFont);
      await settings.close();
      settings = await DisplaySettings.open(databasePath: path);
      expect(settings.fontId, DisplaySettings.systemFont);
      await settings.close();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    expect(DisplaySettings.paletteIds, isNot(contains('sage')));
    await directory.delete(recursive: true);
  });
  test('各套配色在所有表面角色上均可读', () {
    double contrast(Color a, Color b) {
      final first = a.computeLuminance(), second = b.computeLuminance();
      return (first > second ? first + .05 : second + .05) /
          (first > second ? second + .05 : first + .05);
    }

    expect(
      CampusPalette.values.map((palette) => palette.id),
      DisplaySettings.paletteIds,
    );
    for (final palette in CampusPalette.values) {
      for (final background in [
        palette.surface,
        palette.surfaceSelected,
        palette.backgroundTop,
        palette.backgroundBottom,
        palette.glassFallback,
      ]) {
        expect(
          contrast(palette.onSurface, background),
          greaterThanOrEqualTo(4.5),
          reason: palette.id,
        );
        expect(
          contrast(palette.onSurfaceVariant, background),
          greaterThanOrEqualTo(4.5),
          reason: palette.id,
        );
      }
      expect(
        contrast(palette.primary, palette.onPrimary),
        greaterThanOrEqualTo(4.5),
      );
    }
  });
  testWidgets('四套配色与两种字体在窄屏特大字号均无溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700)); addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final palette in CampusPalette.values) {
      for (final font in DisplaySettings.fontFamilies.keys) {
        final settings = DisplaySettings.memory(); await settings.setPalette(palette.id); await settings.setFont(font); await settings.setTextSize(1.4);
        await tester.pumpWidget(MaterialApp(theme: campusTheme(palette: palette, fontFamily: settings.fontFamily), builder: (context, child) => DisplayScope(settings: settings, child: MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.4)), child: child!)), home: AppearancePage(key: ValueKey('${palette.id}-$font'))));
        await tester.pumpAndSettle();
        // 两张字体卡依次滚到眼前（页面底部一屏装不下两张），各自的预览都是图。
        final previews = <String>{};
        for (final label in ['Maple', '文学衬线']) {
          await tester.scrollUntilVisible(find.text(label), 220, scrollable: find.byType(Scrollable).first); await tester.pumpAndSettle();
          previews.addAll(find.byWidgetPredicate((widget) => widget is Image && '${widget.image}'.contains('font_previews')).evaluate().map((element) => '${(element.widget as Image).image}'.contains('maple') ? 'maple' : 'serif'));
        }
        expect(tester.takeException(), isNull, reason: '${palette.id}-$font');
        // 字体预览是图，页面上的文字只用正在用的字体：没在用的内置字体首次排版要在主线程解析全部字重，首帧会卡住、转场被吃掉。
        final families = <String?>{};
        for (final paragraph in tester.allRenderObjects.whereType<RenderParagraph>()) {
          paragraph.text.visitChildren((span) { families.add(span.style?.fontFamily); return true; });
        }
        expect(families.difference({null, settings.fontFamily, 'packages/lucide_icons_flutter/Lucide'}), isEmpty, reason: '${palette.id}-$font');
        expect(previews, {'maple', 'serif'}, reason: '${palette.id}-$font');
        await tester.pumpWidget(const SizedBox()); settings.dispose();
      }
    }
  });
  testWidgets('配色名在常见宽度特大字号下不折行：两列放不下就改单列', (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 900)); addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final scale in [1.0, 1.4]) {
      final settings = DisplaySettings.memory();
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), builder: (context, child) => DisplayScope(settings: settings, child: MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!)), home: AppearancePage(key: ValueKey(scale))));
      await tester.pumpAndSettle();
      final label = find.text(CampusPalette.values.first.label);
      expect(tester.getSize(label).height, lessThan(16 * scale * 2), reason: '×$scale');
      final columns = CampusPalette.forBrightness(Brightness.light).map((palette) => tester.getTopLeft(find.text(palette.label)).dx.round()).toSet();
      expect(columns, hasLength(scale == 1 ? 2 : 1), reason: '×$scale');
      await tester.pumpWidget(const SizedBox()); settings.dispose();
    }
  });
  testWidgets('界面页配色字体即时生效，两种字体预览和字号可选', (tester) async {
    final settings = DisplaySettings.memory();
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: settings,
        builder: (context, _) => MaterialApp(
          theme: campusTheme(
            palette: CampusPalette.byId(settings.paletteId),
            fontFamily: settings.fontFamily,
          ),
          builder: (context, child) =>
              DisplayScope(settings: settings, child: child!),
          home: const AppearancePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('雾蓝'));
    await tester.pumpAndSettle();
    expect(settings.paletteId, 'mist');
    // 要找的那一项已经露出一角时 scrollUntilVisible 不拖、只直接跳，跳完不排版，不等一帧就按跳之前的位置点，可能点到屏幕外。
    await tester.scrollUntilVisible(find.text('文学衬线'), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('文学衬线'));
    await tester.pumpAndSettle();
    expect(settings.fontId, 'serif');
    final context = tester.element(find.byType(AppearancePage));
    expect(Theme.of(context).textTheme.bodyMedium!.fontFamily, 'Noto Serif SC');
    expect(
      CampusPalette.of(context).primary,
      CampusPalette.byId('mist').primary,
    );
    // 换字体时那张卡锚定在原位，列表按需建、更远的字号条还没建出来，要滚过去。
    await tester.scrollUntilVisible(find.byType(Slider), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await _slideTextSize(tester, 1.4);
    await tester.pumpAndSettle();
    expect(settings.textSize, 1.4);
    // 切字号时字号那一行锚定在原位，玻璃效果可能已建出来但在屏幕外：滚到它露出再点。
    await tester.ensureVisible(find.text('简化'));
    await tester.pumpAndSettle();
    expect(tester.widget<CampusSegmented<String>>(find.byType(CampusSegmented<String>)).selected, 'auto');
    await tester.tap(find.text('简化'));
    await tester.pumpAndSettle();
    expect(settings.glassMode, 'reduced');
    expect(tester.widget<CampusSegmented<String>>(find.byType(CampusSegmented<String>)).selected, 'reduced');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  });
  // 用户反馈：从大字号切到小字号时整页跳动、按钮变形。改为字号连续过渡（人工决策见 display_settings.dart 的 CampusTextScale），点的那一行停在手指下。
  testWidgets('改字号连续过渡：途中是中间字号、一路单调变化，字号条每一帧都停在原位', (tester) async {
    // 视口矮一些，切到标准字号后下面仍有可滚的余量（到底时校正不了的那部分照常移动，见 scroll_anchor.dart）。
    await tester.binding.setSurfaceSize(const Size(400, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final settings = DisplaySettings.memory();
    await settings.setTextSize(1.4);
    await tester.pumpWidget(ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        theme: campusTheme(fontFamily: settings.fontFamily),
        builder: (context, child) => DisplayScope(settings: settings, child: CampusTextScale(textSize: settings.textSize, child: child!)),
        home: const AppearancePage(),
      ),
    ));
    await tester.pumpAndSettle();
    final scrollable = find.byType(Scrollable).first;
    final slider = find.byType(Slider);
    await tester.scrollUntilVisible(slider, 200, scrollable: scrollable);
    await tester.pumpAndSettle();
    // 往回滚一段：下面留出余量（滚到底时，下面的内容变矮那一点校正不了，见本用例后半段；字号条下面还有预览卡与玻璃效果，变矮得多）。
    await tester.drag(scrollable, const Offset(0, 320));
    await tester.pumpAndSettle();
    double scaleNow() => MediaQuery.textScalerOf(tester.element(slider)).scale(14) / 14;
    expect(scaleNow(), closeTo(1.4, 1e-6));
    Future<List<double>> morph(double size, {required List<double> scales}) async {
      final tops = [tester.getTopLeft(slider).dy];
      await _slideTextSize(tester, size);
      for (var frame = 0; frame < 24; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        scales.add(scaleNow());
        tops.add(tester.getTopLeft(slider).dy);
      }
      await tester.pumpAndSettle();
      return [...tops, tester.getTopLeft(slider).dy];
    }
    final scales = <double>[];
    final tops = await morph(1.0, scales: scales);
    // 测试里系统字号是 100%，点在「系统」那一档就回到跟随系统。
    expect(settings.textSize, isNull);
    expect(scaleNow(), closeTo(1.0, 1e-6));
    expect(scales.where((scale) => scale > 1.02 && scale < 1.38), isNotEmpty, reason: '途中有中间字号，不是一帧跳过去');
    for (var index = 1; index < scales.length; index++) {
      expect(scales[index], lessThanOrEqualTo(scales[index - 1] + 1e-9));
    }
    for (final top in tops) {
      expect(top, closeTo(tops.first, 1), reason: '上面的内容变矮时字号条不跟着往上跳');
    }

    // 滚到最底再切到 140%：底边贴着屏幕底，字号条跟着下面内容的变化平滑移动，每一帧只挪一点、不跳。
    await tester.drag(scrollable, const Offset(0, -2000));
    await tester.pumpAndSettle();
    final bottomTops = await morph(1.4, scales: <double>[]);
    expect(settings.textSize, 1.4);
    for (var index = 1; index < bottomTops.length; index++) {
      expect((bottomTops[index] - bottomTops[index - 1]).abs(), lessThan(8), reason: '第 $index 帧');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  });
  // [人工决策] 见 local/display_settings.dart 的 textSizeMin：字号从系统字号上的倍数改成实际显示大小，老设置升级后看起来不变。
  test('设备设置v8迁移：原来的标准跟随系统，较大及以上换成当时的实际大小（按 5% 一档）', () async {
    final directory = await Directory.systemTemp.createTemp('appearance-');
    for (final (old, system, expected) in [(1.0, 1.3, null), (1.25, 1.3, 1.65), (1.4, 1.0, 1.4), (1.1, .9, 1.0)]) {
      final path = '${directory.path}/display_$old$system.db';
      final database = await openDatabase(
        path,
        version: 7,
        onCreate: (db, _) => db.execute(
          "CREATE TABLE display_settings (id INTEGER PRIMARY KEY CHECK(id=1), text_scale REAL NOT NULL, palette_id TEXT NOT NULL DEFAULT 'mist', font_id TEXT NOT NULL DEFAULT 'maple', theme_mode TEXT NOT NULL DEFAULT 'system', glass_mode TEXT NOT NULL DEFAULT 'auto', wallpaper_file TEXT, wallpaper_tone TEXT, wallpaper_blur INTEGER NOT NULL DEFAULT 27, wallpaper_fade INTEGER NOT NULL DEFAULT 0)",
        ),
      );
      await database.insert('display_settings', {'id': 1, 'text_scale': old});
      await database.close();
      final settings = await DisplaySettings.open(databasePath: path, systemTextScale: system);
      expect(settings.textSize, expected, reason: '$old × 系统 $system');
      await settings.close();
    }
    await directory.delete(recursive: true);
    // 跟随系统时系统字号比标准小也照着来，最小按 80%；选的大小按 5% 一档夹在 80%–200%。
    expect(DisplaySettings.effectiveTextSize(null, .85), .85);
    expect(DisplaySettings.effectiveTextSize(null, .7), .8);
    expect(DisplaySettings.effectiveTextSize(null, 1.3), 1.3);
    expect(DisplaySettings.effectiveTextSize(1.2, 1.6), 1.2);
    expect([DisplaySettings.snapTextSize(1.23), DisplaySettings.snapTextSize(2.4), DisplaySettings.snapTextSize(.83), DisplaySettings.snapTextSize(.6)], [1.25, 2.0, .85, .8]);
  });

  // 推荐上限按屏宽与字体量（同 text_size_range.dart 文件头记的 10-27 扫描结果）：课程卡还带时刻列、今天页与课表顶栏的按钮还带字的最大字号。
  testWidgets('推荐字号上限随屏宽与字体变：Maple 360dp 到 145%、411dp 到 175%，宋体 360dp 到 170%', (tester) async {
    await loadCampusFonts(tester);
    for (final (font, width, expected) in [('Maple Mono NF CN', 360.0, 1.45), ('Maple Mono NF CN', 411.0, 1.75), ('Noto Serif SC', 360.0, 1.7)]) {
      await tester.pumpWidget(MaterialApp(key: ValueKey(font), theme: campusTheme(fontFamily: font), home: const Scaffold(body: SizedBox.expand())));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(SizedBox).last);
      final comfortable = comfortableTextSize(context, width);
      expect(comfortable, expected, reason: '$font ${width}dp');
      expect(textSizeAdaptations(context, width, comfortable), isEmpty);
      expect(textSizeAdaptations(context, width, DisplaySettings.snapTextSize(comfortable + DisplaySettings.textSizeStep)), isNotEmpty);
    }
  });

  testWidgets('字号条：默认跟随系统并标出系统位置，拖过推荐上限重震一下并说明哪里会改排，松在系统那一档回到跟随系统', (tester) async {
    // 推荐范围按窗口宽度算（页面里取 MediaQuery 的尺寸），要设窗口而不只是渲染面。
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 1600);
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await loadCampusFonts(tester);
    final haptics = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final settings = DisplaySettings.memory();
    await tester.pumpWidget(ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        theme: campusTheme(fontFamily: settings.fontFamily),
        builder: (context, child) => DisplayScope(settings: settings, child: CampusTextScale(textSize: settings.textSize, child: child!)),
        home: const AppearancePage(),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byType(Slider), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    // 跟随系统：数值是系统的 130%，刻度标着「系统」，下面写这台手机的推荐范围（Maple 360dp 到 145%）。
    expect(find.textContaining('130%', findRichText: true), findsWidgets);
    expect(find.text('系统'), findsOneWidget);
    expect(find.text('这台手机推荐 100%–145%'), findsOneWidget);
    expect(tester.widget<CampusGlassChip>(find.widgetWithText(CampusGlassChip, '跟随系统')).selected, isTrue);

    await _slideTextSize(tester, 1.9);
    await tester.pumpAndSettle();
    expect(settings.textSize, 1.9);
    expect(haptics, contains('HapticFeedbackType.mediumImpact'), reason: '越过推荐上限重震一下');
    expect(find.text('超出推荐：课程卡时刻挪到首行、顶栏按钮只留图标'), findsOneWidget);
    // 预览卡按 190% 排，内容一栏放不下改两栏，时刻写在第一行。
    expect(find.text('10:00–11:40', findRichText: true), findsOneWidget);
    expect(tester.widget<CampusGlassChip>(find.widgetWithText(CampusGlassChip, '跟随系统')).selected, isFalse);

    // 按住拖动、停在那里不松手：只改预览，过了补存的 300ms 也不改全应用；抬起手指才生效。
    await tester.scrollUntilVisible(find.byType(Slider), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byType(Slider));
    double x(double size) => rect.left + 24 + (size - DisplaySettings.textSizeMin) / (DisplaySettings.textSizeMax - DisplaySettings.textSizeMin) * (rect.width - 48);
    final gesture = await tester.startGesture(Offset(x(1.9), rect.center.dy));
    await gesture.moveTo(Offset(x(1.6), rect.center.dy));
    await tester.pump();
    await gesture.moveTo(Offset(x(1.5), rect.center.dy));
    await tester.pump(const Duration(milliseconds: 600));
    expect(settings.textSize, 1.9);
    expect(find.textContaining('150%', findRichText: true), findsWidgets);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(settings.textSize, 1.5);

    await tester.scrollUntilVisible(find.byType(Slider), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await _slideTextSize(tester, 1.3);
    await tester.pumpAndSettle();
    expect(settings.textSize, isNull, reason: '松在系统那一档回到跟随系统');

    await tester.scrollUntilVisible(find.byType(Slider), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await _slideTextSize(tester, 1.15);
    await tester.pumpAndSettle();
    expect(settings.textSize, 1.15);
    // 可以拖到比标准小（最小 80%），推荐范围仍从标准 100% 标起。
    await tester.scrollUntilVisible(find.byType(Slider), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await _slideTextSize(tester, .8);
    await tester.pumpAndSettle();
    expect(settings.textSize, .8);
    expect(find.text('这台手机推荐 100%–145%'), findsOneWidget);
    // 外观模式的分段控件里也有「跟随系统」，点字号这一节的那个按钮。
    await tester.tap(find.widgetWithText(CampusGlassChip, '跟随系统'));
    await tester.pumpAndSettle();
    expect(settings.textSize, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  });
  testWidgets('减少动画时字号直接换成新值', (tester) async {
    double? textSize = 1.4;
    late StateSetter update;
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: StatefulBuilder(builder: (context, setState) {
        update = setState;
        return CampusTextScale(textSize: textSize, child: Builder(builder: (context) => Text('${MediaQuery.textScalerOf(context).scale(10)}', textDirection: TextDirection.ltr)));
      }),
    ));
    expect(find.text('14.0'), findsOneWidget);
    update(() => textSize = null);
    await tester.pump();
    expect(find.text('10.0'), findsOneWidget);
  });
  testWidgets('限档时说明原因，点「完整」（已选中也算）即解除限档重试', (tester) async {
    const channel = MethodChannel('superxd/glass');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'guard' ? true : null;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      campusGlassCapped.value = false;
    });
    await CampusGlassGuard.load();
    expect(campusGlassCapped.value, isTrue);
    final settings = DisplaySettings.memory();
    await settings.setGlassMode('full');
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), builder: (context, child) => DisplayScope(settings: settings, child: child!), home: const AppearancePage()));
    await tester.pumpAndSettle();
    const notice = '点「完整」重试';
    await tester.scrollUntilVisible(find.text(notice), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('完整'));
    await tester.pumpAndSettle();
    expect(calls, ['guard', 'retry']);
    expect(campusGlassCapped.value, isFalse);
    expect(find.text(notice), findsNothing);
    expect(settings.glassMode, 'full');
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  });
}
