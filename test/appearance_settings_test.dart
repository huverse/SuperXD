import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/page/appearance_page.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_theme.dart';

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
    var settings = await DisplaySettings.open(databasePath: path);
    expect(settings.scale, 1.25);
    // 存过设置的老安装保持当时的苔灰，默认改成雾蓝不覆盖它。
    expect(settings.paletteId, 'sage');
    expect(settings.fontId, 'maple');
    await Future.wait([
      settings.setPalette('rose'),
      settings.setFont('serif'),
      settings.setScale(1.4),
    ]);
    await settings.close();
    settings = await DisplaySettings.open(databasePath: path);
    expect(settings.paletteId, 'rose');
    expect(settings.fontFamily, 'Noto Serif SC');
    expect(settings.scale, 1.4);
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
    await saved.insert('display_settings', {'id': 1, 'text_scale': 1.1, 'palette_id': 'sage'});
    await saved.close();
    settings = await DisplaySettings.open(databasePath: path);
    expect(settings.paletteId, 'sage');
    await settings.close();
    await directory.delete(recursive: true);

    String launch(String folder) => RegExp(r'name="launch_background">(#[0-9A-F]{6})<').firstMatch(File('android/app/src/main/res/$folder/colors.xml').readAsStringSync())!.group(1)!;
    String hex(Color color) => '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
    expect(launch('values'), hex(CampusPalette.byId(DisplaySettings.defaultPaletteId).backgroundTop));
    expect(launch('values-night'), hex(CampusPalette.byId(DisplaySettings.defaultPaletteId, brightness: Brightness.dark).backgroundTop));
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
    await Future.wait([settings.setGlassMode('reduced'), settings.setScale(1.25)]);
    expect(() => settings.setGlassMode('ultra'), throwsArgumentError);
    await settings.close();
    settings = await DisplaySettings.open(databasePath: path);
    expect(settings.glassMode, 'reduced');
    expect(settings.scale, 1.25);
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
    await Future.wait([settings.setWallpaper(picked.path, '色调'), settings.setWallpaperLook(blur: 80, fade: 67), settings.setScale(1.25)]);
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
    expect([settings.wallpaperFile?.path, settings.wallpaperTone, settings.wallpaperBlur, settings.wallpaperFade, settings.scale], [name, '色调', 80, 67, 1.25]);
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
      expect([settings.wallpaperBlur, settings.wallpaperFade, settings.scale], [...expected, 1.1]);
      await settings.close();
    }
    await directory.delete(recursive: true);
  });
  test('五套配色在所有表面角色上均可读', () {
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
  testWidgets('五套配色与两种字体在窄屏特大字号均无溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700)); addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final palette in CampusPalette.values) {
      for (final font in DisplaySettings.fontFamilies.keys) {
        final settings = DisplaySettings.memory(); await settings.setPalette(palette.id); await settings.setFont(font); await settings.setScale(1.4);
        await tester.pumpWidget(MaterialApp(theme: campusTheme(palette: palette, fontFamily: settings.fontFamily), builder: (context, child) => DisplayScope(settings: settings, child: MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.4)), child: child!)), home: AppearancePage(key: ValueKey('${palette.id}-$font'))));
        await tester.pumpAndSettle(); await tester.scrollUntilVisible(find.text('文学衬线'), 220, scrollable: find.byType(Scrollable).first); await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '${palette.id}-$font');
        // 字体预览是图，页面上的文字只用正在用的字体：没在用的内置字体首次排版要在主线程解析全部字重，首帧会卡住、转场被吃掉。
        final families = <String?>{};
        for (final paragraph in tester.allRenderObjects.whereType<RenderParagraph>()) {
          paragraph.text.visitChildren((span) { families.add(span.style?.fontFamily); return true; });
        }
        expect(families.difference({null, settings.fontFamily, 'packages/lucide_icons_flutter/Lucide'}), isEmpty, reason: '${palette.id}-$font');
        expect(find.byWidgetPredicate((widget) => widget is Image && '${widget.image}'.contains('font_previews')), findsNWidgets(2));
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
    await tester.scrollUntilVisible(find.text('文学衬线'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('文学衬线'));
    await tester.pumpAndSettle();
    expect(settings.fontId, 'serif');
    final context = tester.element(find.byType(AppearancePage));
    expect(Theme.of(context).textTheme.bodyMedium!.fontFamily, 'Noto Serif SC');
    expect(
      CampusPalette.of(context).primary,
      CampusPalette.byId('mist').primary,
    );
    await tester.ensureVisible(find.text('特大'));
    await tester.tap(find.text('特大'));
    await tester.pumpAndSettle();
    expect(settings.scale, 1.4);
    await tester.scrollUntilVisible(find.text('简化'), -200, scrollable: find.byType(Scrollable).first);
    expect(tester.widget<CampusSegmented<String>>(find.byType(CampusSegmented<String>)).selected, 'auto');
    await tester.tap(find.text('简化'));
    await tester.pumpAndSettle();
    expect(settings.glassMode, 'reduced');
    expect(tester.widget<CampusSegmented<String>>(find.byType(CampusSegmented<String>)).selected, 'reduced');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
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
