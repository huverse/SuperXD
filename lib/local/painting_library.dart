import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/painting.dart';

const paintingManifest = 'assets/paintings/paintings.json';

// 把一张图存进本机公共目录（Download/SuperXD，相册里可见），由组合根接上原生一次性导出；同名的已经存过时直接算存好。
typedef PaintingPublish = Future<bool> Function(File picture, String filename);

// 开屏画作的来源（实现 domain 的 PaintingGallery）：随安装包的清单与图片，加上轮换记录——应用支持目录下的 splash_painting.json，
// 记上次开屏用的哪一幅、用户排的顺序与不播的几幅（设备级，切换账号保留；只记清单里有的 id，大小随清单封顶）；
// 先写临时文件再改名、一次写完一份，读到坏文件当没有记录（按清单顺序、全都播，从第一幅开始）。
class PaintingLibrary implements PaintingGallery {
  PaintingLibrary._(this.paintings, this._bundle, this._memory, this._temporary, this._publish, this._last, List<String> order, Set<String> muted)
    : _order = order, _muted = muted;
  @override
  final List<Painting> paintings;
  final AssetBundle _bundle;
  final File? _memory;
  final Directory? _temporary;
  final PaintingPublish? _publish;
  String? _last;
  List<String> _order;
  Set<String> _muted;
  Painting? _current;
  Future<void> _writing = Future.value();

  static Future<PaintingLibrary> open({required AssetBundle bundle, required File memory, required Directory temporary, required PaintingPublish publish}) async {
    var paintings = const <Painting>[];
    try {
      paintings = decodePaintings(await bundle.loadString(paintingManifest));
    } catch (error, stack) {
      campusLog('[Painting] action=manifest errorType=${error.runtimeType}\n$stack');
    }
    String? last;
    var order = const <String>[];
    var muted = const <String>{};
    try {
      if (await memory.exists()) {
        final json = jsonDecode(await memory.readAsString());
        if (json is Map) {
          if (json['last'] is String) last = json['last'] as String;
          final known = {for (final painting in paintings) painting.id};
          if (json['order'] case final List<Object?> list) order = [...{for (final id in list) if (id is String && known.contains(id)) id}];
          if (json['muted'] case final List<Object?> list) muted = {for (final id in list) if (id is String && known.contains(id)) id};
        }
      }
    } catch (error, stack) {
      campusLog('[Painting] action=memory_read errorType=${error.runtimeType}\n$stack');
    }
    // 记录里一幅都不播（坏记录或清单变了）时当全都播。
    if (paintings.every((painting) => muted.contains(painting.id))) muted = const {};
    return PaintingLibrary._(paintings, bundle, memory, temporary, publish, last, order, muted);
  }

  // 测试用：轮换记录只在内存里；不给 publish 时不存图。
  PaintingLibrary.memory(List<Painting> paintings, {String? last, List<String> order = const [], Set<String> muted = const {}, AssetBundle? bundle, Directory? temporary, PaintingPublish? publish})
    : this._(paintings, bundle ?? rootBundle, null, temporary, publish, last, order, muted);

  // 用户排的顺序在前，清单里新加的（没排过的）按清单顺序接在后面。
  @override
  List<Painting> get arranged {
    final byId = {for (final painting in paintings) painting.id: painting};
    return [for (final id in _order) ?byId[id], for (final painting in paintings) if (!_order.contains(painting.id)) painting];
  }

  @override
  bool plays(Painting painting) => !_muted.contains(painting.id);

  @override
  Future<void> arrange(List<String> order, Set<String> muted) async {
    final known = {for (final painting in paintings) painting.id};
    final ordered = [...{for (final id in order) if (known.contains(id)) id}];
    final kept = {for (final id in muted) if (known.contains(id)) id};
    if (known.every(kept.contains)) throw ArgumentError.value(muted, 'muted', '至少留一幅开屏时播');
    _order = ordered;
    _muted = kept;
    campusLog('[Painting] action=arrange order=${ordered.length} muted=${kept.length}');
    await _write();
  }

  @override
  Painting? get current => _current;

  // 这次冷启动开屏用哪一幅：按用户排的顺序从上次那幅往后找第一幅要播的（上次那幅刚关掉也从它的位置往后找，
  // 不在了就从头找），一次运行只取一次；记录在后台写，失败只记日志。
  Painting? next() {
    if (_current != null || paintings.isEmpty) return _current;
    final arranged = this.arranged;
    final start = arranged.indexWhere((painting) => painting.id == _last);
    final painting = [for (var step = 1; step <= arranged.length; step++) arranged[(start + step) % arranged.length]].firstWhere(plays, orElse: () => arranged.first);
    _current = painting;
    _last = painting.id;
    _write().catchError((Object error, StackTrace stack) {
      campusLog('[Painting] action=memory_write errorType=${error.runtimeType}\n$stack');
    });
    return painting;
  }

  // 写入排队：开屏记下这一幅与用户排顺序可能同时写，一次写完整份，后写的不被先写的盖掉。
  // 上一次写的失败已由它的调用方记过日志或抛给了调用方，这里只让队列接着往下走。
  Future<void> _write() => _writing = _writing.catchError((Object _) {}).then((_) async {
    final file = _memory;
    if (file == null) return;
    await file.parent.create(recursive: true);
    final pending = File('${file.path}.tmp');
    await pending.writeAsString(jsonEncode({'last': ?_last, 'order': _order, 'muted': _muted.toList()}), flush: true);
    await pending.rename(file.path);
  });

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
