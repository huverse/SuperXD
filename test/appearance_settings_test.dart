import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/local/display_settings.dart';
import 'package:superxd/page/appearance_page.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
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
    expect([settings.wallpaperFile, settings.wallpaperTone, settings.wallpaperBlur, settings.wallpaperFade], [null, null, 1, 0]);
    expect([settings.paletteId, settings.glassMode], ['oat', 'full']);
    final picked = File('${directory.path}/picked.jpg')..writeAsBytesSync([1, 2, 3]);
    await Future.wait([settings.setWallpaper(picked.path, '色调'), settings.setWallpaperFade(2), settings.setScale(1.25)]);
    expect(() => settings.setWallpaperBlur(3), throwsArgumentError);
    final name = settings.wallpaperFile!.path;
    expect(picked.existsSync(), isTrue);
    await settings.close();
    File('${wallpapers.path}/wallpaper_0.jpg').writeAsBytesSync([9]);
    settings = await DisplaySettings.open(databasePath: path, wallpaperDirectory: wallpapers);
    expect([settings.wallpaperFile?.path, settings.wallpaperTone, settings.wallpaperFade, settings.scale], [name, '色调', 2, 1.25]);
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
        await tester.pumpWidget(const SizedBox()); settings.dispose();
      }
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
    expect(tester.widget<CampusGlassChip>(find.widgetWithText(CampusGlassChip, '自动')).selected, isTrue);
    await tester.tap(find.text('简化'));
    await tester.pumpAndSettle();
    expect(settings.glassMode, 'reduced');
    expect(tester.widget<CampusGlassChip>(find.widgetWithText(CampusGlassChip, '简化')).selected, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  });
}
