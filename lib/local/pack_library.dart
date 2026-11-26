import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/download_pack.dart';

// 按需下载的文件包的本机文件、核对与下载状态（字体包、星空素材包共用，模型见 domain/download_pack.dart）：
// 文件放应用支持目录下各自的文件夹（排除出系统备份与换机迁移，可重新下载），只留登记表里现有的文件，打开时删掉别的（旧版本、下载残留）；
// 下载经组合根注入的 PackSource（device 层的自建中转实现），没配中转时为空，只能用已经下好的。
// 每个文件都核对大小与 SHA-256 才用：下载完核对一次，装好前读文件时再核对一次（在后台 isolate 里读与算，不卡界面）。
// 下载失败时已下好、核对过的文件留着，重试只下缺的；取消与删除则把这个包的文件全删掉。
// onReady 在一个包的文件全部核对通过后拿到各文件的内容（字体包在这里注册给引擎）；为空时只核对。
class PackLibrary<P extends DownloadPack> extends ChangeNotifier {
  PackLibrary({required this.directory, required this.packs, required this.tag, required this.noun, this.source, this.onReady});
  final Directory directory;
  final PackSource? source;
  final Map<String, P> packs;
  // 日志模块名（如 FontPack），noun 是给用户看的东西（如「字体」），用在失败说明里。
  final String tag;
  final String noun;
  final Future<void> Function(P pack, List<Uint8List> files)? onReady;
  final _status = <String, PackStatus>{};
  final _withFiles = <String>{};
  final _installing = <String, Future<bool>>{};
  final _aborts = <String, Completer<void>>{};

  bool contains(String id) => packs.containsKey(id);
  bool get downloadable => source != null;
  PackStatus statusOf(String id) => _status[id] ?? PackStatus.missing;
  bool ready(String id) => statusOf(id).phase == PackPhase.ready;
  // 本机有这个包的文件（含没下全的）：界面页据此给「删除」。
  bool hasFiles(String id) => _withFiles.contains(id);
  // 包里一个文件在本机的位置（装好之后才可读）。
  File fileOf(PackFile file) => File(path.join(directory.path, file.name));

  // 启动时调（显示设置打开时，首帧之前）：清掉登记表外的文件，看各包的文件齐不齐；selected 是登记过的包时核对并装好。
  Future<void> open(String? selected) async {
    try {
      await _prune();
      for (final pack in packs.values) {
        await _scan(pack);
      }
    } catch (error, stack) {
      campusLog('[$tag] action=open errorType=${error.runtimeType}\n$stack');
    }
    // 启动时只用本机文件，不联网（缺了或坏了按没下载处理，由组合根在同意协议与政策之后再下）。
    if (selected != null && contains(selected) && statusOf(selected).phase == PackPhase.stored) await install(selected, download: false);
  }

  // 装好这个包：本机文件核对通过的直接用，缺的或坏的经中转下载、核对后再用，最后交给 onReady；同一个包同时只装一份（再调拿到同一个结果）。
  // download 为假时只用本机文件，缺了就当没下载。返回是否装好，失败的原因在 statusOf 里。
  // 收尾时用块体：remove 返回的正是这个 Future，箭头函数把它交回 whenComplete 会自己等自己。
  Future<bool> install(String id, {bool download = true}) => _installing[id] ??= _install(id, download).whenComplete(() {
    _installing.remove(id);
  });

  Future<bool> _install(String id, bool download) async {
    final pack = packs[id]!;
    if (ready(id)) return true;
    final abort = _aborts[id] = Completer<void>();
    final total = packSize(pack);
    var done = 0;
    try {
      await directory.create(recursive: true);
      final contents = <Uint8List>[];
      for (final file in pack.files) {
        var bytes = await _verified(file);
        if (bytes == null) {
          if (!download) {
            await _scan(pack);
            return false;
          }
          final source = this.source;
          if (source == null) throw PackException('这个版本不能下载$noun');
          if (done == 0) campusLog('[$tag] action=download_start id=$id');
          final partial = path.join(directory.path, '${file.name}.part');
          var shown = -1;
          void progress(int received) {
            // 进度按整百分比通知，不每收一块就让界面重建。
            final percent = (done + received) * 100 ~/ total;
            if (percent == shown) return;
            shown = percent;
            _set(id, PackStatus(PackPhase.downloading, received: done + received, total: total));
          }
          progress(0);
          await source.download(file, partial, abort: abort.future, onProgress: progress);
          if (abort.isCompleted) throw const PackCancelled();
          bytes = await _check(partial, file);
          if (bytes == null) throw PackException('下载的$noun文件不完整，请重试');
          await File(partial).rename(path.join(directory.path, file.name));
          _withFiles.add(id);
        }
        done += file.size;
        contents.add(bytes);
      }
      await onReady?.call(pack, contents);
      _set(id, PackStatus.ready);
      campusLog('[$tag] action=install id=$id');
      return true;
    } on PackCancelled {
      campusLog('[$tag] action=install_cancel id=$id');
      await _deleteFiles(pack);
      _set(id, PackStatus.missing);
      return false;
    } on PackException catch (error) {
      campusLog('[$tag] action=install id=$id errorType=PackException message=${error.message}');
      await _deletePartials(pack);
      await _scan(pack, failure: error.message);
      return false;
    } catch (error, stack) {
      campusLog('[$tag] action=install id=$id errorType=${error.runtimeType}\n$stack');
      await _deletePartials(pack);
      await _scan(pack, failure: '保存$noun没成功，请重试');
      return false;
    } finally {
      _aborts.remove(id);
    }
  }

  // 取消正在下的包：停在当前这块，删掉这个包已下的文件，回到未下载。
  void cancel(String id) {
    final abort = _aborts[id];
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  // 删除下载的包：先停下正在装的，再删本机文件，回到未下载。
  Future<void> delete(String id) async {
    final pack = packs[id]!;
    cancel(id);
    await _installing[id];
    await _deleteFiles(pack);
    _set(id, PackStatus.missing);
    campusLog('[$tag] action=delete id=$id');
  }

  void _set(String id, PackStatus status) {
    _status[id] = status;
    notifyListeners();
  }

  // 按文件在不在、大小对不对定状态（不读内容）：齐全是 stored，否则 missing；failure 不为空时是失败。已装好的保持 ready。
  Future<void> _scan(P pack, {String? failure}) async {
    var present = 0, complete = 0;
    for (final file in pack.files) {
      final target = fileOf(file);
      if (!await target.exists()) continue;
      present++;
      if (await target.length() == file.size) complete++;
    }
    present > 0 ? _withFiles.add(pack.id) : _withFiles.remove(pack.id);
    if (ready(pack.id)) return;
    _set(pack.id, failure != null ? PackStatus(PackPhase.failed, error: failure) : complete == pack.files.length ? PackStatus.stored : PackStatus.missing);
  }

  Future<Uint8List?> _verified(PackFile file) async {
    final target = fileOf(file).path;
    if (!await File(target).exists()) return null;
    final bytes = await _check(target, file);
    if (bytes == null) {
      campusLog('[$tag] action=verify file=${file.name} errorType=PackCorrupt');
      await _delete(File(target));
    }
    return bytes;
  }

  // 在后台 isolate 里读文件、核对大小与 SHA-256，对得上才交回内容（结果经 Isolate.exit 转交，不复制）。
  static Future<Uint8List?> _check(String file, PackFile expected) {
    final size = expected.size, digest = expected.sha256;
    return Isolate.run(() {
      final bytes = File(file).readAsBytesSync();
      if (bytes.length != size || sha256.convert(bytes).toString() != digest) return null;
      return bytes;
    });
  }

  Future<void> _deleteFiles(P pack) async {
    for (final file in pack.files) {
      await _delete(fileOf(file));
    }
    await _deletePartials(pack);
    _withFiles.remove(pack.id);
  }

  Future<void> _deletePartials(P pack) async {
    for (final file in pack.files) {
      await _delete(File('${fileOf(file).path}.part'));
    }
  }

  static Future<void> _delete(File file) async {
    if (await file.exists()) await file.delete();
  }

  Future<void> _prune() async {
    if (!await directory.exists()) return;
    final keep = {for (final pack in packs.values) for (final file in pack.files) file.name};
    await for (final entity in directory.list()) {
      if (keep.contains(path.basename(entity.path))) continue;
      await entity.delete(recursive: true);
      campusLog('[$tag] action=prune file=${path.basename(entity.path)}');
    }
  }
}
