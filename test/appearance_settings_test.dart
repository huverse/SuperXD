import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
    await tester.ensureVisible(find.text('文学衬线'));
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
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  });
}
