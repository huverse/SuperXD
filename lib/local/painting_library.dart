import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/painting.dart';

const paintingManifest = 'assets/paintings/paintings.json';

// 把一张图存进本机公共目录（Download/SuperXD，相册里可见），由组合根接上原生一次性导出；同名的已经存过时直接算存好。
typedef PaintingPublish = Future<bool> Function(File picture, String filename);

// 开屏画作的来源（实现 domain 的 PaintingGallery）：随安装包的清单与图片，加上轮换记录——应用支持目录下固定大小的 splash_painting.json，
// 只记上次开屏用的哪一幅（设备级，切换账号保留）；先写临时文件再改名，读到坏文件当没有记录（从第一幅开始）。
class PaintingLibrary implements PaintingGallery {
  PaintingLibrary._(this.paintings, this._bundle, this._memory, this._temporary, this._publish, this._last);
  @override
  final List<Painting> paintings;
  final AssetBundle _bundle;
  final File? _memory;
  final Directory? _temporary;
  final PaintingPublish? _publish;
  String? _last;
  Painting? _current;

  static Future<PaintingLibrary> open({required AssetBundle bundle, required File memory, required Directory temporary, required PaintingPublish publish}) async {
    var paintings = const <Painting>[];
    try {
      paintings = decodePaintings(await bundle.loadString(paintingManifest));
    } catch (error, stack) {
      campusLog('[Painting] action=manifest errorType=${error.runtimeType}\n$stack');
    }
    String? last;
    try {
      if (await memory.exists()) {
        final json = jsonDecode(await memory.readAsString());
        if (json is Map && json['last'] is String) last = json['last'] as String;
      }
    } catch (error, stack) {
      campusLog('[Painting] action=memory_read errorType=${error.runtimeType}\n$stack');
    }
    return PaintingLibrary._(paintings, bundle, memory, temporary, publish, last);
  }

  // 测试用：轮换记录只在内存里；不给 publish 时不存图。
  PaintingLibrary.memory(List<Painting> paintings, {String? last, AssetBundle? bundle, Directory? temporary, PaintingPublish? publish})
    : this._(paintings, bundle ?? rootBundle, null, temporary, publish, last);

  @override
  Painting? get current => _current;

  // 这次冷启动开屏用哪一幅：按清单顺序接着上次的下一幅（上次那幅已不在清单里就从第一幅起），一次运行只取一次；记录在后台写，失败只记日志。
  Painting? next() {
    if (_current != null || paintings.isEmpty) return _current;
    final index = paintings.indexWhere((painting) => painting.id == _last);
    final painting = paintings[(index + 1) % paintings.length];
    _current = painting;
    _last = painting.id;
    _write(painting.id).catchError((Object error, StackTrace stack) {
      campusLog('[Painting] action=memory_write errorType=${error.runtimeType}\n$stack');
    });
    return painting;
  }

  Future<void> _write(String id) async {
    final file = _memory;
    if (file == null) return;
    await file.parent.create(recursive: true);
    final pending = File('${file.path}.tmp');
    await pending.writeAsString(jsonEncode({'last': id}), flush: true);
    await pending.rename(file.path);
  }

  // 原图从安装包里拷到缓存，交原生存进公共目录，用完即删；文件名「SuperXD-画作名.jpg」，同名不重复存。
  @override
  Future<bool> save(Painting painting) async {
    final publish = _publish, temporary = _temporary;
    if (publish == null || temporary == null) return false;
    final extension = painting.asset.substring(painting.asset.lastIndexOf('.'));
    final picture = File('${temporary.path}/painting-${painting.id}-${DateTime.now().microsecondsSinceEpoch}$extension');
    try {
      final data = await _bundle.load(painting.asset);
      await temporary.create(recursive: true);
      await picture.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      return await publish(picture, 'SuperXD-${painting.title}$extension');
    } catch (error, stack) {
      campusLog('[Painting] action=save errorType=${error.runtimeType}\n$stack');
      return false;
    } finally {
      try {
        if (await picture.exists()) await picture.delete();
      } catch (error, stack) {
        campusLog('[Painting] action=save_clean errorType=${error.runtimeType}\n$stack');
      }
    }
  }
}
