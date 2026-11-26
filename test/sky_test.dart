import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/app_services.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/app_shell.dart';
import 'package:superxd/domain/download_pack.dart';
import 'package:superxd/domain/sky.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/local/pack_library.dart';
import 'package:superxd/page/appearance_page.dart';
import 'package:superxd/page/text_size_range.dart';
import 'package:superxd/theme/campus_background.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';

import 'fixture_campus_gateway.dart';
import 'page_fixture_support.dart';

// 两张小 PNG（深蓝、暖橙），当作测试用的星空素材（背景要真能解码出色调网格）。
final _dark = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAkAAAAUCAIAAADQu4ACAAAAFklEQVR4nGMUkQtgwAGYcEmMyo1YOQBJHwCqjPZHPQAAAABJRU5ErkJggg==');
final _warm = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAkAAAAUCAIAAADQu4ACAAAAFklEQVR4nGM8UWHDgAMw4ZIYlRuxcgBq8QGkvctQpwAAAABJRU5ErkJggg==');

final _bytes = <String, Uint8List>{
  for (final style in SkyStyle.values)
    for (final phase in SkyPhase.values) 'sky_${style.id}_${phase.name}.webp': phase == SkyPhase.dusk || phase == SkyPhase.dawn ? _warm : _dark,
};

final _packs = <String, SkyPack>{
  for (final style in SkyStyle.values)
    style.id: SkyPack(style: style, files: [
      for (final phase in SkyPhase.values)
        SkyFile(phase: phase, name: 'sky_${style.id}_${phase.name}.webp', size: _bytes['sky_${style.id}_${phase.name}.webp']!.length, sha256: sha256.convert(_bytes['sky_${style.id}_${phase.name}.webp']!).toString()),
    ]),
};

// 假的中转下载：按块写进目标文件并报进度；hold 为真时第一个文件下到一半停住（held 完成）等取消。
class _FakeSource implements PackSource {
  _FakeSource({this.hold = false});
  bool hold;
  final requested = <String>[];
  Completer<void> held = Completer<void>();

  @override
  Future<void> download(PackFile file, String target, {required void Function(int received) onProgress, required Future<void> abort}) async {
    requested.add(file.name);
    final bytes = _bytes[file.name]!;
    final half = bytes.length ~/ 2;
    await File(target).writeAsBytes(bytes.sublist(0, half));
    onProgress(half);
    if (hold) {
      if (!held.isCompleted) held.complete();
      await abort;
      throw const PackCancelled();
    }
    await File(target).writeAsBytes(bytes, flush: true);
    onProgress(bytes.length);
  }
}

PackLibrary<SkyPack> _library(Directory root, PackSource? source) => PackLibrary<SkyPack>(directory: root, packs: _packs, tag: 'SkyPack', noun: '星空', source: source);

// 济南（校园时区 UTC+8）某天的某个钟点。
DateTime _jinan(int month, int day, int hour, int minute) => DateTime.utc(2026, month, day, hour, minute).subtract(const Duration(hours: 8));

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('登记的星空素材：两个画风各五个时段一幅，文件名合规、不重名，大小与 SHA-256 像样', () {
    expect(skyPacks.keys.toSet(), {for (final style in SkyStyle.values) style.id});
    final names = <String>{};
    for (final pack in skyPacks.values) {
      expect(pack.files.map((file) => file.phase).toSet(), SkyPhase.values.toSet(), reason: pack.id);
      for (final file in pack.files) {
        expect(packFileName.hasMatch(file.name) && file.name.endsWith('.webp'), isTrue, reason: file.name);
        expect(names.add(file.name), isTrue, reason: '${file.name} 重名');
        expect(file.size, greaterThan(0));
        expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(file.sha256), isTrue);
        expect(file.name, contains(file.sha256.substring(0, 12)), reason: '文件名带内容哈希');
      }
    }
  });

  test('太阳高度：济南 11 月 26 日正午约 32°，午夜在地平线下很深', () {
    expect(sunAltitude(_jinan(11, 26, 12, 12)), closeTo(90 - skyLatitude - 21.1, 1));
    expect(sunAltitude(_jinan(11, 27, 0, 12)), lessThan(-60));
  });

  test('按济南真实的太阳高度分幕：白天、黄昏、夜、深夜、黎明各在该在的时候，之间是过渡', () {
    SkyMoment at(int hour, int minute) => skyMoment(_jinan(11, 26, hour, minute));
    expect(at(12, 0), const SkyMoment(SkyPhase.day));
    expect((at(16, 40).from, at(16, 40).to), (SkyPhase.day, SkyPhase.dusk), reason: '日落前（太阳约 2°）白天过渡到黄昏');
    expect(at(17, 20), const SkyMoment(SkyPhase.dusk));
    expect((at(17, 45).from, at(17, 45).to), (SkyPhase.dusk, SkyPhase.night));
    expect(at(20, 0), const SkyMoment(SkyPhase.night));
    expect((at(23, 50).from, at(23, 50).to), (SkyPhase.night, SkyPhase.late), reason: '午夜前后由夜过渡到深夜');
    expect(at(2, 0), const SkyMoment(SkyPhase.late));
    expect((at(5, 50).from, at(5, 50).to), (SkyPhase.late, SkyPhase.dawn), reason: '天快亮时由深夜过渡到黎明');
    expect(at(6, 30), const SkyMoment(SkyPhase.dawn));
    expect((at(7, 10).from, at(7, 10).to), (SkyPhase.dawn, SkyPhase.day));
    // 一天里每分钟看一次：画面是两幕按比例混的，相邻两分钟之间变化很小（没有突然换幕）；夏至也一样。
    for (final (month, day) in [(11, 26), (6, 21)]) {
      Map<SkyPhase, double> weights(SkyMoment moment) => {for (final phase in SkyPhase.values) phase: (moment.from == phase ? 1 - moment.mix : 0) + (moment.to == phase ? moment.mix : 0)};
      var last = weights(skyMoment(_jinan(month, day, 0, 0)));
      for (var minute = 1; minute < 24 * 60; minute++) {
        final next = weights(skyMoment(_jinan(month, day, minute ~/ 60, minute % 60)));
        for (final phase in SkyPhase.values) {
          expect((next[phase]! - last[phase]!).abs(), lessThan(.08), reason: '$month-$day ${minute ~/ 60}:${minute % 60} $phase');
        }
        last = next;
      }
    }
  });

  test('显示设置：选星空先下好那一套再换上，没装好时照旧用原来的背景；换回云雾或图片就不是星空；删掉正在用的先换回云雾；v9 升上来没选星空', () async {
    final root = await Directory.systemTemp.createTemp('sky-');
    final library = _library(root, _FakeSource());
    final settings = DisplaySettings.memory(skyPacks: library);
    expect((settings.skyStyle, settings.skyInUse), (null, null));
    await settings.chooseSky('shinkai');
    expect((settings.skyStyle, settings.skyInUse, library.ready('shinkai')), ('shinkai', 'shinkai', true));
    await settings.clearWallpaper();
    expect(settings.skyStyle, isNull, reason: '回到默认云雾');
    await settings.chooseSky('shinkai');
    await settings.deleteSkyPack('shinkai');
    expect((settings.skyStyle, library.hasFiles('shinkai')), (null, false));
    settings.dispose();

    final path = '${root.path}/display.db';
    final old = await openDatabase(path, version: 9, onCreate: (db, _) => db.execute(
      "CREATE TABLE display_settings (id INTEGER PRIMARY KEY CHECK(id=1), text_scale REAL NOT NULL, palette_id TEXT NOT NULL DEFAULT 'mist', font_id TEXT NOT NULL DEFAULT 'maple', theme_mode TEXT NOT NULL DEFAULT 'system', glass_mode TEXT NOT NULL DEFAULT 'auto', wallpaper_file TEXT, wallpaper_tone TEXT, wallpaper_blur INTEGER NOT NULL DEFAULT 27, wallpaper_fade INTEGER NOT NULL DEFAULT 0, class_now_collapsed INTEGER NOT NULL DEFAULT 0)",
    ));
    await old.insert('display_settings', {'id': 1, 'text_scale': 1.2, 'palette_id': 'dusk', 'class_now_collapsed': 1});
    await old.close();
    final packs = _library(Directory('${root.path}/packs'), _FakeSource());
    var opened = await DisplaySettings.open(databasePath: path, skyPacks: packs);
    expect((opened.skyStyle, opened.paletteId, opened.classNowCollapsed.value), (null, 'dusk', true));
    await opened.chooseSky('real');
    await opened.close();
    // 重开：选着的星空素材在本机，首帧之前核对好直接用，不联网。
    final offline = _library(Directory('${root.path}/packs'), null);
    opened = await DisplaySettings.open(databasePath: path, skyPacks: offline);
    expect((opened.skyStyle, opened.skyInUse), ('real', 'real'));
    await opened.close();
    await root.delete(recursive: true);
  });

  testWidgets('界面页：背景选星空原地下载、可取消，下好才换上并写明固定深色；画风可换；⋯里删除先确认、正在用就换回云雾', (tester) async {
    final root = (await tester.runAsync(() => Directory.systemTemp.createTemp('sky-page-')))!;
    addTearDown(() => root.delete(recursive: true));
    final source = _FakeSource(hold: true);
    final library = _library(root, source);
    final settings = DisplaySettings.memory(wallpaperDirectory: Directory('${root.path}/wallpaper'), skyPacks: library);
    await tester.pumpWidget(MaterialApp(
      theme: campusTheme(),
      builder: (context, child) => DisplayScope(settings: settings, child: TextSizeComfort(builder: (_, _) => child!)),
      home: const AppearancePage(),
    ));
    await tester.pumpAndSettle();
    Future<void> until(bool Function() done) async {
      for (var attempt = 0; attempt < 200 && !done(); attempt++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(done(), isTrue);
    }

    await tester.scrollUntilVisible(find.text('星空'), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('星空'));
    await until(() => source.held.isCompleted);
    await tester.pump();
    expect(find.text('真实'), findsOneWidget);
    expect(find.text('新海诚'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(settings.skyStyle, isNull, reason: '下好之前不换');
    await tester.tap(find.byTooltip('取消下载'));
    await until(() => library.statusOf('real').phase == PackPhase.missing);
    await tester.pumpAndSettle();
    expect((find.text('真实').evaluate().length, settings.skyStyle), (0, null), reason: '取消后回到原来的背景');

    source.hold = false;
    await tester.tap(find.text('星空'));
    await until(() => settings.skyInUse == 'real');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('星空背景固定深色'), -200, scrollable: find.byType(Scrollable).first);
    expect(find.text('星空背景固定深色'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('新海诚'), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('新海诚'));
    await until(() => settings.skyInUse == 'shinkai');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除星空素材'));
    await tester.pumpAndSettle();
    expect(find.text('先换回云雾，再删除本机的新海诚星空素材，之后可以再下载。'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await until(() => settings.skyStyle == null && find.text('已删除星空素材').evaluate().isNotEmpty);
    expect((library.hasFiles('shinkai'), library.hasFiles('real')), (false, true));
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  });

  testWidgets('星空背景铺上：应用固定深色、卡片透到 65%、背景拿到这一刻的画面；换回云雾就恢复', (tester) async {
    final root = (await tester.runAsync(() => Directory.systemTemp.createTemp('sky-shell-')))!;
    addTearDown(() => root.delete(recursive: true));
    final library = _library(root, _FakeSource());
    final display = DisplaySettings.memory(skyPacks: library);
    await display.setThemeMode(ThemeMode.light);
    final session = AppSession(FixtureAccounts(FixtureCampusGateway(readText: (name) async => pageFixtures()[name]!), signedIn: false));
    await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(display: display)));
    await tester.pumpAndSettle();
    BuildContext page() => tester.element(find.text('SuperXD').first);
    expect((Theme.of(page()).brightness, CampusSurfaceScope.opacityOf(page())), (Brightness.light, CampusSurfaceScope.standard));

    await tester.runAsync(() => display.chooseSky('real'));
    for (var attempt = 0; attempt < 100 && tester.widget<CampusAtmosphere>(find.byType(CampusAtmosphere)).sky?.value == null; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    final scene = tester.widget<CampusAtmosphere>(find.byType(CampusAtmosphere)).sky!.value!;
    final moment = skyMoment(DateTime.now());
    expect(((scene.from.image as FileImage).file.path, scene.mix), (library.fileOf(_packs['real']!.fileOf(moment.from)).path, moment.mix));
    expect((Theme.of(page()).brightness, CampusSurfaceScope.opacityOf(page())), (Brightness.dark, .65));

    await tester.runAsync(display.clearWallpaper);
    await tester.pumpAndSettle();
    expect(tester.widget<CampusAtmosphere>(find.byType(CampusAtmosphere)).sky?.value, isNull);
    expect((Theme.of(page()).brightness, CampusSurfaceScope.opacityOf(page())), (Brightness.light, CampusSurfaceScope.standard));
    // 图片在真实时间里读文件：等读完再收尾，临时目录才删得干净。
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });
}
