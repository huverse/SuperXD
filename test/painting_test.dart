import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/domain/painting.dart';
import 'package:superxd/local/painting_library.dart';

// 只给清单与图片字节的内存资源包（不经引擎的资源清单）。
class _Bundle extends CachingAssetBundle {
  _Bundle(this.files);
  final Map<String, List<int>> files;

  @override
  Future<ByteData> load(String key) async {
    final bytes = files[key];
    if (bytes == null) throw StateError('没有 $key');
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}

Map<String, Object?> _entry(String id, {String? sky}) => {
  'id': id,
  'file': '$id.jpg',
  'title': '合成画作$id',
  'note': '测试',
  'width': 160,
  'height': 90,
  'focus': .5,
  'horizon': ['#112233', '#445566'],
  'sky': sky ?? '#AABBCC',
};

void main() {
  test('随安装包的清单读得出来：每幅的图片都在、尺寸与文件一致、id 不重复', () {
    final paintings = decodePaintings(File(paintingManifest).readAsStringSync());
    expect(paintings, isNotEmpty);
    expect(paintings.map((painting) => painting.id).toSet(), hasLength(paintings.length));
    for (final painting in paintings) {
      expect(File(painting.asset).existsSync(), isTrue, reason: painting.asset);
      expect(painting.horizon, isNotEmpty);
      expect(painting.title, isNotEmpty);
    }
    // pubspec 登记了整个画作目录，加画不用改 pubspec。
    expect(File('pubspec.yaml').readAsStringSync(), contains('- assets/paintings/'));
  });

  test('清单逐项校验：颜色、文件名、重复 id 不对就整份报错', () {
    String manifest(List<Map<String, Object?>> entries) => jsonEncode({'paintings': entries});
    expect(decodePaintings(manifest([_entry('a')])).single.sky, 0xFFAABBCC);
    expect(() => decodePaintings(manifest([_entry('a', sky: 'blue')])), throwsA(isA<PaintingFormatException>()));
    expect(() => decodePaintings(manifest([_entry('a'), _entry('a')])), throwsA(isA<PaintingFormatException>()));
    expect(() => decodePaintings(manifest([{..._entry('a'), 'file': '../secret.db'}])), throwsA(isA<PaintingFormatException>()));
    expect(() => decodePaintings('{"paintings": 3}'), throwsA(isA<PaintingFormatException>()));
  });

  group('轮换与保存', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('painting_test'));
    tearDown(() => temp.deleteSync(recursive: true));

    Future<PaintingLibrary> open({PaintingPublish? publish}) => PaintingLibrary.open(
      bundle: _Bundle({
        paintingManifest: utf8.encode(jsonEncode({'paintings': [_entry('a'), _entry('b'), _entry('c')]})),
        'assets/paintings/a.jpg': [1, 2, 3],
      }),
      memory: File('${temp.path}/splash_painting.json'),
      temporary: Directory('${temp.path}/cache'),
      publish: publish ?? (_, _) async => true,
    );

    // 记录在后台写：等文件里写着这一幅再往下走。以前固定等 20ms，慢的 CI 上记录还没落盘就「重开」，读到旧记录（10-25 main CI 偶发红）。
    Future<void> written(String id) async {
      final memory = File('${temp.path}/splash_painting.json');
      while (!memory.existsSync() || !memory.readAsStringSync().contains('"last":"$id"')) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('按清单顺序每次冷启动换下一幅，到最后一幅回到第一幅；一次运行只取一次', () async {
      final seen = <String>[];
      for (var launch = 0; launch < 4; launch++) {
        final library = await open();
        seen.add(library.next()!.id);
        expect(library.next()!.id, seen.last, reason: '同一次运行再取还是这一幅');
        expect(library.current!.id, seen.last);
        await written(seen.last);
      }
      expect(seen, ['a', 'b', 'c', 'a']);
    });

    // 11-16 用户要求开屏画作可以自己排顺序、选播哪几幅（人工决策见 domain/painting.dart）。
    test('播放顺序：按用户排的顺序轮换、跳过不播的；刚关掉的那幅从它的位置往后找；重开还在；至少留一幅', () async {
      final first = await open();
      expect([for (final painting in first.arranged) painting.id], ['a', 'b', 'c']);
      await first.arrange(['c', 'a', 'b'], {'a'});
      expect([for (final painting in first.arranged) painting.id], ['c', 'a', 'b']);
      expect([for (final painting in first.arranged) first.plays(painting)], [true, false, true]);
      await expectLater(first.arrange(['a', 'b', 'c'], {'a', 'b', 'c'}), throwsArgumentError, reason: '一幅都不播不存');
      final seen = <String>[];
      for (var launch = 0; launch < 3; launch++) {
        final library = await open();
        seen.add(library.next()!.id);
        await written(seen.last);
      }
      expect(seen, ['c', 'b', 'c'], reason: '没有上次记录从头找第一幅要播的，不播的 a 跳过');
      final again = await open();
      expect([for (final painting in again.arranged) painting.id], ['c', 'a', 'b'], reason: '顺序与不播的重开还在');
      // 上次开屏是 c，把 c 关掉：从 c 的位置往后找，是 b，不回到开头。
      await again.arrange(['c', 'a', 'b'], {'a', 'c'});
      expect(again.next()!.id, 'b');
      await written('b');
    });

    test('播放顺序：清单新加的接在后面、默认播；记录里不认识的 id 丢掉；记录里一幅都不播时当全都播', () async {
      File('${temp.path}/splash_painting.json').writeAsStringSync('{"last":"a","order":["b","gone","b"],"muted":["c","gone"]}');
      final library = await open();
      expect([for (final painting in library.arranged) painting.id], ['b', 'a', 'c']);
      expect([for (final painting in library.arranged) library.plays(painting)], [true, true, false]);
      File('${temp.path}/splash_painting.json').writeAsStringSync('{"muted":["a","b","c"]}');
      final muted = await open();
      expect([for (final painting in muted.arranged) muted.plays(painting)], [true, true, true]);
    });

    test('记录坏了或上次那幅已不在清单里，从第一幅开始', () async {
      File('${temp.path}/splash_painting.json').writeAsStringSync('{坏的');
      expect((await open()).next()!.id, 'a');
      await written('a');
      File('${temp.path}/splash_painting.json').writeAsStringSync('{"last":"gone"}');
      expect((await open()).next()!.id, 'a');
      // 等后台记录写完再删临时目录。
      await written('a');
    });

    test('保存：原图拷到缓存交给导出，文件名写画作名，临时文件用完即删；没存上返回 false', () async {
      String? name;
      List<int>? bytes;
      final library = await open(publish: (picture, filename) async {
        name = filename;
        bytes = picture.readAsBytesSync();
        return true;
      });
      expect(await library.save(library.paintings.first), isTrue);
      expect(name, 'SuperXD-合成画作a.jpg');
      expect(bytes, [1, 2, 3]);
      expect(Directory('${temp.path}/cache').listSync(), isEmpty);
      final failing = await open(publish: (_, _) async => false);
      expect(await failing.save(failing.paintings.first), isFalse);
      // 安装包里没有这张图：记日志、返回 false，不抛出。
      expect(await failing.save(failing.paintings[1]), isFalse);
    });
  });
}
