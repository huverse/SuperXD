import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/device/relay_font_pack_source.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/font_pack.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/local/font_packs.dart';

import 'font_pack_support.dart';

void main() {
  late Directory root;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async => root = await Directory.systemTemp.createTemp('font-pack-'));
  tearDown(() async => root.delete(recursive: true));

  group('字体包本机文件', () {
    test('下载、逐个核对、注册；进度按整百分比通知，已有的文件不重下', () async {
      final source = FakeFontPackSource();
      final registered = <String, List<Uint8List>>{};
      final library = FontPackLibrary(directory: root, source: source, packs: testFontPacks, register: (family, fonts) async => registered[family] = fonts);
      final seen = <FontPackStatus>[];
      library.addListener(() => seen.add(library.statusOf('serif')));
      expect(await library.install('serif'), isTrue);
      expect(library.ready('serif'), isTrue);
      expect(library.hasFiles('serif'), isTrue);
      expect(source.requested, testFontPack.files.map((file) => file.name));
      expect(registered[testFontPack.family]!.map((bytes) => sha256.convert(bytes).toString()), testFontPack.files.map((file) => file.sha256));
      final downloading = seen.where((status) => status.phase == FontPackPhase.downloading).toList();
      expect(downloading.first.received, 0);
      expect(downloading.map((status) => status.received), orderedEquals([...downloading.map((status) => status.received)]..sort()));
      expect(downloading.length, lessThanOrEqualTo(102), reason: '按整百分比通知，不每收一块就通知');
      expect(seen.last.phase, FontPackPhase.ready);
      for (final file in testFontPack.files) {
        expect(File('${root.path}/${file.name}').existsSync(), isTrue);
        expect(File('${root.path}/${file.name}.part').existsSync(), isFalse);
      }
      // 删掉其中一个字重：重装只下缺的那一个。
      File('${root.path}/${testFontPack.files[1].name}').deleteSync();
      final again = FontPackLibrary(directory: root, source: source..requested.clear(), packs: testFontPacks, register: (_, _) async {});
      await again.open(null);
      expect(again.statusOf('serif').phase, FontPackPhase.missing);
      expect(again.hasFiles('serif'), isTrue);
      expect(await again.install('serif'), isTrue);
      expect(source.requested, [testFontPack.files[1].name]);
    });

    test('启动时只用本机文件：齐全且核对通过就注册，坏了的删掉按没下载处理，不联网；登记表外的文件清掉', () async {
      writeTestFontPack(root);
      File('${root.path}/old-version.ttf').writeAsBytesSync([1, 2, 3]);
      File('${root.path}/${testFontPack.files[0].name}.part').writeAsBytesSync([1]);
      final source = FakeFontPackSource();
      var registrations = 0;
      final library = FontPackLibrary(directory: root, source: source, packs: testFontPacks, register: (_, _) async => registrations++);
      await library.open('serif');
      expect(library.ready('serif'), isTrue);
      expect(registrations, 1);
      expect(source.requested, isEmpty);
      expect(root.listSync().map((entity) => entity.uri.pathSegments.last).toSet(), testFontPack.files.map((file) => file.name).toSet());

      // 没选它时只看文件齐不齐（stored），不读内容、不注册。
      final idle = FontPackLibrary(directory: root, source: source, packs: testFontPacks, register: (_, _) async => registrations++);
      await idle.open('maple');
      expect(idle.statusOf('serif').phase, FontPackPhase.stored);
      expect(registrations, 1);

      // 内容坏了（大小对、哈希不对）：删掉，按没下载处理，启动时不去下载。
      final broken = File('${root.path}/${testFontPack.files[2].name}');
      broken.writeAsBytesSync(Uint8List(testFontPack.files[2].size));
      final corrupt = FontPackLibrary(directory: root, source: source, packs: testFontPacks, register: (_, _) async => registrations++);
      await corrupt.open('serif');
      expect(corrupt.ready('serif'), isFalse);
      expect(corrupt.statusOf('serif').phase, FontPackPhase.missing);
      expect(broken.existsSync(), isFalse);
      expect(source.requested, isEmpty);
    });

    test('取消：停下并删掉这个包已下的文件，回到未下载', () async {
      final source = FakeFontPackSource(holdAt: 1);
      final library = FontPackLibrary(directory: root, source: source, packs: testFontPacks, register: (_, _) async {});
      final installing = library.install('serif');
      await source.held.future;
      expect(library.statusOf('serif').phase, FontPackPhase.downloading);
      expect(library.install('serif'), same(installing), reason: '同一个包同时只装一份');
      library.cancel('serif');
      expect(await installing, isFalse);
      expect(library.statusOf('serif').phase, FontPackPhase.missing);
      expect(library.hasFiles('serif'), isFalse);
      expect(root.listSync(), isEmpty);
    });

    test('下载失败写明原因、留着已下好的字重；下回来的内容不对算失败；没配中转时说明下不了', () async {
      final failing = FakeFontPackSource(failAt: 2, error: const FontPackException('连不上服务器，请检查网络后重试'));
      final library = FontPackLibrary(directory: root, source: failing, packs: testFontPacks, register: (_, _) async {});
      expect(await library.install('serif'), isFalse);
      expect(library.statusOf('serif').phase, FontPackPhase.failed);
      expect(library.statusOf('serif').error, '连不上服务器，请检查网络后重试');
      expect(library.hasFiles('serif'), isTrue);
      expect(File('${root.path}/${testFontPack.files[0].name}').existsSync(), isTrue);
      expect(File('${root.path}/${testFontPack.files[2].name}.part').existsSync(), isFalse);

      final tampered = FontPackLibrary(directory: root, source: FakeFontPackSource(tamper: true), packs: testFontPacks, register: (_, _) async {});
      expect(await tampered.install('serif'), isFalse);
      expect(tampered.statusOf('serif').error, '下载的字体文件不完整，请重试');

      final offline = FontPackLibrary(directory: await Directory.systemTemp.createTemp('font-pack-offline-'), packs: testFontPacks, register: (_, _) async {});
      expect(offline.downloadable, isFalse);
      expect(await offline.install('serif'), isFalse);
      expect(offline.statusOf('serif').error, '这个版本不能下载字体');
      await offline.directory.delete(recursive: true);
    });

    test('删除：停下正在装的、删掉文件，回到未下载，可以再下', () async {
      final source = FakeFontPackSource();
      final library = FontPackLibrary(directory: root, source: source, packs: testFontPacks, register: (_, _) async {});
      await library.install('serif');
      await library.delete('serif');
      expect(library.statusOf('serif').phase, FontPackPhase.missing);
      expect(library.hasFiles('serif'), isFalse);
      expect(root.listSync(), isEmpty);
      expect(await library.install('serif'), isTrue);
    });
  });

  group('显示设置接上字体包', () {
    Future<(DisplaySettings, FontPackLibrary, FakeFontPackSource)> open({FakeFontPackSource? source, String? stored, bool downloadable = true}) async {
      final fake = source ?? FakeFontPackSource();
      final library = FontPackLibrary(directory: Directory('${root.path}/packs'), source: downloadable ? fake : null, packs: testFontPacks, register: (_, _) async {});
      final path = '${root.path}/display.db';
      if (stored != null) {
        final first = await DisplaySettings.open(databasePath: path, systemTextScale: 1);
        await first.setFont(stored);
        await first.close();
      }
      return (await DisplaySettings.open(databasePath: path, systemTextScale: 1, fontPacks: library), library, fake);
    }

    test('升级上来选着衬线、本机没有：先用默认字体并保留选择，同意后下回来就换过去；只在用的字体变了才通知', () async {
      final (settings, library, source) = await open(stored: 'serif');
      expect(settings.fontId, 'serif');
      expect(settings.fontInUse, 'maple');
      expect(settings.fontFamily, 'Maple Mono NF CN');
      var notified = 0;
      settings.addListener(() => notified++);
      await settings.ensureFontPack();
      expect(source.requested, hasLength(testFontPack.files.length));
      expect(settings.fontFamily, testFontPack.family);
      expect(notified, 1, reason: '下载进度不让整个应用重建');
      // 重开：首帧前就注册好，不联网。
      await settings.close();
      final (reopened, reopenedLibrary, reopenedSource) = await open();
      expect(reopenedLibrary.ready('serif'), isTrue);
      expect(reopened.fontFamily, testFontPack.family);
      expect(reopenedSource.requested, isEmpty);
      await reopened.close();
      library.dispose();
    });

    test('界面页点选衬线：下好才换上；下载中又点了别的就作罢；失败或取消时选择不变', () async {
      final source = FakeFontPackSource(holdAt: 0);
      final (settings, library, _) = await open(source: source);
      final choosing = settings.chooseFont('serif');
      await source.held.future;
      expect(settings.fontId, 'maple', reason: '没下好之前不换');
      await settings.chooseFont(DisplaySettings.systemFont);
      await choosing;
      expect(settings.fontId, DisplaySettings.systemFont);
      expect(library.statusOf('serif').phase, FontPackPhase.missing);

      source.holdAt = null;
      await settings.chooseFont('serif');
      expect(settings.fontId, 'serif');
      expect(settings.fontFamily, testFontPack.family);
      await settings.close();
    });

    test('删除正在用的字体包：先换回默认字体再删文件，之后回到未下载', () async {
      final (settings, library, _) = await open();
      await settings.chooseFont('serif');
      expect(settings.fontFamily, testFontPack.family);
      final order = <String>[];
      settings.addListener(() => order.add('font:${settings.fontId}'));
      library.addListener(() => order.add('pack:${library.statusOf('serif').phase.name}'));
      await settings.deleteFontPack('serif');
      expect(order.first, 'font:maple');
      expect(order.last, 'pack:missing');
      expect(settings.fontFamily, 'Maple Mono NF CN');
      expect(library.hasFiles('serif'), isFalse);
      await settings.close();
    });

    test('套用好友的界面配置：衬线没装时照样选上并开始下载；这个版本下不了时按不支持跳过；安卓也认系统字体', () async {
      final (settings, library, source) = await open();
      AppearanceShare share(String font) => AppearanceShare(paletteId: 'rose', fontId: font, scale: 0, themeMode: 'system', glassMode: 'auto', wallpaperBlur: 27, wallpaperFade: 0);
      expect(await settings.applyAppearance(share('serif')), isEmpty);
      expect(settings.fontId, 'serif');
      await library.install('serif');
      expect(source.requested, hasLength(testFontPack.files.length));
      expect(settings.fontFamily, testFontPack.family);
      expect(await settings.applyAppearance(share(DisplaySettings.systemFont)), isEmpty);
      expect(settings.fontId, DisplaySettings.systemFont);
      await settings.close();

      // 本机也没有文件、又下不了：才按不支持跳过。
      await Directory('${root.path}/packs').delete(recursive: true);
      final (offline, _, _) = await open(downloadable: false);
      expect(await offline.applyAppearance(share('serif')), ['字体']);
      expect(offline.fontId, DisplaySettings.systemFont, reason: '字体保持原来选的');
      await offline.close();
    });
  });

  group('经中转下载字体文件', () {
    final file = testFontPack.files.first;
    late List<String> logs;
    late void Function(String) original;
    setUp(() {
      logs = [];
      original = campusLog;
      campusLog = logs.add;
      campusDiagnostics = true;
    });
    tearDown(() {
      campusLog = original;
      campusDiagnostics = false;
    });

    test('流式写进目标文件并报进度，请求路径与字节数进开发者模式的记录', () async {
      final bytes = testFontBytes[file.name]!;
      final target = '${root.path}/out.part';
      late Uri requested;
      final received = <int>[];
      final source = RelayFontPackSource('http://relay.test', client: () => MockClient.streaming((request, _) async {
        requested = request.url;
        return http.StreamedResponse(Stream.fromIterable([bytes.sublist(0, 100), bytes.sublist(100)]), 200, contentLength: bytes.length);
      }));
      await source.download(file, target, onProgress: received.add, abort: Completer<void>().future);
      expect(requested.toString(), 'http://relay.test/v1/app/files/${file.name}');
      expect(received, [100, bytes.length]);
      expect(File(target).readAsBytesSync(), bytes);
      expect(logs.where((line) => line.contains('module=font_pack') && line.contains('status=200')), hasLength(1));
    });

    test('404、限流、大小不对与超时都换成给用户看的原因；取消抛 FontPackCancelled', () async {
      Future<Object?> failure(MockClient client, {Future<void>? abort, Duration idle = const Duration(seconds: 30)}) async {
        try {
          await RelayFontPackSource('http://relay.test', client: () => client, idle: idle).download(file, '${root.path}/x.part', onProgress: (_) {}, abort: abort ?? Completer<void>().future);
          return null;
        } catch (error) {
          return error;
        }
      }
      String? message(Object? error) => error is FontPackException ? error.message : null;
      expect(message(await failure(MockClient((_) async => http.Response('{"code":"RELEASE_NOT_FOUND"}', 404)))), '服务器上还没有这个字体，请稍后再试');
      expect(message(await failure(MockClient((_) async => http.Response('{"code":"RATE_LIMITED"}', 429)))), '下载的人太多，请稍后再试');
      expect(message(await failure(MockClient((_) async => http.Response.bytes(Uint8List(file.size + 1), 200)))), '字体文件不对，请稍后再试');
      expect(message(await failure(MockClient.streaming((_, _) async => http.StreamedResponse(Stream.value(Uint8List(file.size + 1)), 200)))), '字体文件不对，请稍后再试');
      expect(message(await failure(MockClient.streaming((_, _) async => http.StreamedResponse(StreamController<List<int>>().stream, 200)), idle: const Duration(milliseconds: 50))), '连不上服务器，请检查网络后重试');
      final abort = Completer<void>();
      final chunks = StreamController<List<int>>();
      final cancelled = failure(MockClient.streaming((_, _) async => http.StreamedResponse(chunks.stream, 200)), abort: abort.future);
      chunks.add([1, 2, 3]);
      await Future<void>.delayed(Duration.zero);
      abort.complete();
      await Future<void>.delayed(Duration.zero);
      chunks.add([4]);
      expect(await cancelled, isA<FontPackCancelled>());
      await chunks.close();
      expect(logs.where((line) => line.contains('errorType=') && line.contains('[FontPack]')), hasLength(1), reason: '只有超时那次是没预料到的错误，带堆栈记一条');
    });
  });
}
