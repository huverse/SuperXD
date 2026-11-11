import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:superxd/domain/font_pack.dart';

// 测试用的小字体包：同衬线的 id 与族名，三个字重各几 KB 的合成内容（只测下载、核对与状态，不真的注册给引擎）。
final testFontBytes = {
  for (final (index, weight) in [400, 500, 600].indexed) 'test_serif_$weight.ttf': Uint8List.fromList(List.generate(3000 + index * 500, (offset) => (offset * (index + 3)) % 251)),
};
final testFontPack = FontPack(id: 'serif', family: 'Noto Serif SC', files: [
  for (final (index, entry) in testFontBytes.entries.indexed)
    FontPackFile(name: entry.key, weight: 400 + index * 100, size: entry.value.length, sha256: sha256.convert(entry.value).toString()),
]);
final testFontPacks = {'serif': testFontPack};

void writeTestFontPack(Directory directory) {
  directory.createSync(recursive: true);
  for (final entry in testFontBytes.entries) {
    File('${directory.path}/${entry.key}').writeAsBytesSync(entry.value);
  }
}

// 假的中转下载：按块写进目标文件并报进度。holdAt 指定第几个文件下到一半停住（held 完成）等取消；failAt 指定第几个文件抛 error；tamper 写进不对的内容。
class FakeFontPackSource implements FontPackSource {
  FakeFontPackSource({this.holdAt, this.failAt, this.error, this.tamper = false});
  int? holdAt;
  final int? failAt;
  final Object? error;
  final bool tamper;
  final requested = <String>[];
  Completer<void> held = Completer<void>();

  @override
  Future<void> download(FontPackFile file, String target, {required void Function(int received) onProgress, required Future<void> abort}) async {
    final index = requested.length;
    requested.add(file.name);
    if (index == failAt) throw error!;
    final bytes = testFontBytes[file.name]!;
    final sink = File(target).openWrite();
    try {
      for (var offset = 0; offset < bytes.length; offset += 256) {
        final end = (offset + 256).clamp(0, bytes.length);
        sink.add(tamper ? Uint8List(end - offset) : bytes.sublist(offset, end));
        onProgress(end);
        if (index == holdAt && offset == 0) {
          if (!held.isCompleted) held.complete();
          await abort;
          throw const FontPackCancelled();
        }
      }
    } finally {
      await sink.close();
    }
  }
}
