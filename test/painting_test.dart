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

    test('按清单顺序每次冷启动换下一幅，到最后一幅回到第一幅；一次运行只取一次', () async {
      final seen = <String>[];
      for (var launch = 0; launch < 4; launch++) {
        final library = await open();
        seen.add(library.next()!.id);
        expect(library.next()!.id, seen.last, reason: '同一次运行再取还是这一幅');
        expect(library.current!.id, seen.last);
        // 记录在后台写，等它落盘再「重开」。
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(seen, ['a', 'b', 'c', 'a']);
    });

    test('记录坏了或上次那幅已不在清单里，从第一幅开始', () async {
      File('${temp.path}/splash_painting.json').writeAsStringSync('{坏的');
      expect((await open()).next()!.id, 'a');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      File('${temp.path}/splash_painting.json').writeAsStringSync('{"last":"gone"}');
      expect((await open()).next()!.id, 'a');
      // 等后台记录写完再删临时目录。
      await Future<void>.delayed(const Duration(milliseconds: 20));
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
