import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/local/display_settings.dart';
import 'package:superxd/page/appearance_page.dart';
import 'package:superxd/page/text_size_range.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_background.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_theme.dart';

void main() {
  setUpAll(() {sqfliteFfiInit();databaseFactory=databaseFactoryFfi;});
  test('v2迁移与新安装默认system，并发保存及重开不覆盖显示设置', () async {
    final directory=await Directory.systemTemp.createTemp('dark-settings-');
    final path='${directory.path}/display.db';
    final old=await openDatabase(path,version:2,onCreate:(db,version) async {
      await db.execute("CREATE TABLE display_settings (id INTEGER PRIMARY KEY, text_scale REAL NOT NULL, palette_id TEXT NOT NULL, font_id TEXT NOT NULL)");
      await db.insert('display_settings',{'id':1,'text_scale':1.25,'palette_id':'rose','font_id':'serif'});
    });await old.close();
    var settings=await DisplaySettings.open(databasePath:path);
    expect(settings.themeMode,ThemeMode.system);expect(settings.textSize,1.25);expect(settings.paletteId,'rose');expect(settings.fontId,'serif');
    await Future.wait([settings.setThemeMode(ThemeMode.dark),settings.setPalette('mist'),settings.setTextSize(1.4)]);
    await settings.close();settings=await DisplaySettings.open(databasePath:path);
    expect(settings.themeMode,ThemeMode.dark);expect(settings.paletteId,'mist');expect(settings.textSize,1.4);expect(settings.fontId,'serif');
    await settings.close();
    final raw=await openDatabase(path);await raw.update('display_settings',{'theme_mode':'invalid'});await raw.close();
    settings=await DisplaySettings.open(databasePath:path);expect(settings.themeMode,ThemeMode.system);await settings.close();
    settings=await DisplaySettings.open(databasePath:'${directory.path}/new.db');expect(settings.themeMode,ThemeMode.system);await settings.close();await directory.delete(recursive:true);
  });

  testWidgets('系统明暗动态切换，手动模式覆盖，三选项即时生效且保持路由', (tester) async {
    final settings=DisplaySettings.memory();
    tester.platformDispatcher.platformBrightnessTestValue=Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(ListenableBuilder(listenable:settings,builder:(context,_)=>MaterialApp(
      theme:campusTheme(palette:CampusPalette.byId(settings.paletteId)),darkTheme:campusTheme(palette:CampusPalette.byId(settings.paletteId,brightness:Brightness.dark)),themeMode:settings.themeMode,
      builder:(context,child)=>DisplayScope(settings:settings,child:TextSizeComfort(builder:(_,_)=>child!)),home:const AppearancePage(),
    )));await tester.pumpAndSettle();
    final element=tester.element(find.byType(AppearancePage));
    expect(Theme.of(element).brightness,Brightness.light);
    tester.platformDispatcher.platformBrightnessTestValue=Brightness.dark;await tester.pumpAndSettle();expect(Theme.of(element).brightness,Brightness.dark);
    await tester.tap(find.text('浅色'));await tester.pumpAndSettle();expect(settings.themeMode,ThemeMode.light);expect(Theme.of(element).brightness,Brightness.light);
    tester.platformDispatcher.platformBrightnessTestValue=Brightness.light;await tester.pumpAndSettle();
    await tester.tap(find.text('深色'));await tester.pumpAndSettle();expect(Theme.of(element).brightness,Brightness.dark);
    await tester.tap(find.descendant(of:find.byType(CampusSegmented<ThemeMode>),matching:find.text('跟随系统')));await tester.pumpAndSettle();expect(Theme.of(element).brightness,Brightness.light);
    expect(identical(element,tester.element(find.byType(AppearancePage))),isTrue);
    await tester.pumpWidget(const SizedBox());settings.dispose();
  });

  for(final palette in CampusPalette.darkValues) {
    test('${palette.label}暗色色板与多相位雾光玻璃合成保持可读，不是亮色反转', () async {
      double contrast(Color a,Color b){final left=a.computeLuminance(),right=b.computeLuminance();return (math.max(left,right)+.05)/(math.min(left,right)+.05);}
      expect(palette.brightness,Brightness.dark);
      expect(palette.surface.computeLuminance(),greaterThan(palette.backgroundTop.computeLuminance()));
      expect(palette.surfaceSelected.computeLuminance(),greaterThan(palette.surface.computeLuminance()));
      var minimum=double.infinity;
      for(final size in [const Size(180,320),const Size(320,180)]) {
        for(var phase=0;phase<8;phase++) {
          final recorder=ui.PictureRecorder();
          AtmospherePainter(progress:AlwaysStoppedAnimation(phase/8),highContrast:false,palette:palette).paint(Canvas(recorder),size);
          final picture=recorder.endRecording();final image=await picture.toImage(size.width.toInt(),size.height.toInt());
          final pixels=(await image.toByteData(format:ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
          for(var offset=0;offset<pixels.length;offset+=32){
            final background=Color.fromARGB(255,pixels[offset],pixels[offset+1],pixels[offset+2]);
            for(final surface in [background,Color.alphaBlend(palette.surface.withValues(alpha:.91),background),Color.alphaBlend(palette.glassTint.withValues(alpha:.62),background),palette.surfaceSelected]) {
              for(final foreground in [palette.onSurface,palette.onSurfaceVariant,palette.primary,palette.danger]) {
                minimum=math.min(minimum,contrast(foreground,surface));
              }
            }
          }
          image.dispose();picture.dispose();
        }
      }
      expect(minimum,greaterThanOrEqualTo(4.5),reason:'${palette.id}: $minimum');
      expect(contrast(palette.primary,palette.onPrimary),greaterThanOrEqualTo(4.5));
      expect(contrast(palette.danger,palette.onDanger),greaterThanOrEqualTo(4.5));
      expect(campusSystemOverlay(palette).statusBarIconBrightness,Brightness.light);
      expect(campusSystemOverlay(palette).systemNavigationBarContrastEnforced,isFalse);
    });
  }

  test('标签色在八套配色的卡片、选中底与磨砂底上都不低于 3:1（图形元素）', () {
    double contrast(Color a,Color b){final left=a.computeLuminance(),right=b.computeLuminance();return (math.max(left,right)+.05)/(math.min(left,right)+.05);}
    for(final palette in [...CampusPalette.values,...CampusPalette.darkValues]) {
      expect(palette.tagColors,hasLength(6));
      for(final (index,color) in palette.tagColors.indexed) {
        for(final surface in [palette.surface,palette.surfaceSelected,palette.glassFallback]) {
          expect(contrast(color,surface),greaterThanOrEqualTo(3),reason:'${palette.id} ${palette.brightness.name} #$index');
        }
      }
    }
  });

  // 11-16 选中着色（人工决策见 campus_palette.dart 的 selectedFill）：选中的文字（主色）压在选中底上，卡片与浮层玻璃两种底都不低于 4.5:1；
  // 选中底与未选的卡片底分得出来，激活色细边对卡片底不低于 3:1（非文字元素）。
  test('选中着色：选中文字对选中底不低于 4.5:1，细边对卡片底不低于 3:1，八套配色', () {
    double contrast(Color a,Color b){final left=a.computeLuminance(),right=b.computeLuminance();return (math.max(left,right)+.05)/(math.min(left,right)+.05);}
    for(final palette in [...CampusPalette.values,...CampusPalette.darkValues]) {
      final reason='${palette.id} ${palette.brightness.name}';
      expect(contrast(palette.primary,Color.alphaBlend(palette.selectedFill,palette.surface)),greaterThanOrEqualTo(4.5),reason:reason);
      expect(contrast(palette.primary,Color.alphaBlend(palette.selectedFill,palette.glassTint)),greaterThanOrEqualTo(4.5),reason:reason);
      expect(contrast(palette.selectedEdge().color,palette.surface),greaterThanOrEqualTo(3),reason:reason);
      expect(contrast(Color.alphaBlend(palette.selectedFill,palette.surface),palette.surface),greaterThan(1.1),reason:reason);
    }
  });

  // 11-17 设计审查：快递身份码的倒计时用浅色 attention（#F59E0B）当 14 号字，对卡片底只有约 2:1。文字与小标记改用 attentionText。
  test('提醒文字色在八套配色的卡片底（91% 叠在背景上）与全屏白底上都不低于 4.5:1', () {
    double contrast(Color a,Color b){final left=a.computeLuminance(),right=b.computeLuminance();return (math.max(left,right)+.05)/(math.min(left,right)+.05);}
    for(final palette in [...CampusPalette.values,...CampusPalette.darkValues]) {
      final reason='${palette.id} ${palette.brightness.name}';
      final card=Color.alphaBlend(palette.surface.withValues(alpha:.91),palette.backgroundBottom);
      expect(contrast(palette.attentionText,card),greaterThanOrEqualTo(4.5),reason:reason);
      expect(contrast(palette.attentionText,palette.surface),greaterThanOrEqualTo(4.5),reason:reason);
      // 快递身份码全屏出示是纯白底、只用浅色配色。
      if(!palette.isDark) expect(contrast(palette.attentionText,Colors.white),greaterThanOrEqualTo(4.5),reason:reason);
    }
  });

  test('激活色强调文字在八套配色的卡片底上：大号字不低于 3:1，深色不低于 4.5:1', () {
    double contrast(Color a,Color b){final left=a.computeLuminance(),right=b.computeLuminance();return (math.max(left,right)+.05)/(math.min(left,right)+.05);}
    for(final palette in [...CampusPalette.values,...CampusPalette.darkValues]) {
      expect(contrast(palette.accentText,palette.surface),greaterThanOrEqualTo(palette.isDark ? 4.5 : 3),reason:'${palette.id} ${palette.brightness.name}');
    }
  });
}
