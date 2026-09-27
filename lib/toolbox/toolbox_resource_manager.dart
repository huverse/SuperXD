import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';

import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_store.dart';

Future<String> _hashFile(String source) async =>
    (await sha256.bind(File(source).openRead()).first).toString();

class ToolboxResourceManager {
  ToolboxResourceManager({
    required this.directory,
    required this.store,
    required this.specifications,
  });
  final Directory directory;
  final ToolboxStore store;
  final Map<String, ToolboxResource> specifications;
  final _installed = <String>{};
  final _locks = <String, Lock>{};
  bool installed(String toolId) => _installed.contains(toolId);
  File file(String toolId) => File(
    path.join(directory.path, toolId, '${specifications[toolId]!.sha256}.data'),
  );

  Future<void> restore() async {
    _installed.clear();
    for (final entry in specifications.entries) {
      final record = await store.resource(entry.key);
      final target = file(entry.key);
      if (record?['version'] == entry.value.version &&
          record?['hash'] == entry.value.sha256 &&
          await target.exists() &&
          await target.length() == entry.value.bytes) {
        _installed.add(entry.key);
      }
    }
  }

  Future<void> install(String toolId, File source) =>
      _locks.putIfAbsent(toolId, Lock.new).synchronized(() async {
        final resource = specifications[toolId]!;
        if (await source.length() != resource.bytes) {
          throw const ToolboxException('资源大小不匹配，请重新下载');
        }
        final digest = await compute(_hashFile, source.path);
        if (digest != resource.sha256) {
          throw const ToolboxException('资源校验失败，请重新下载');
        }
        final target = file(toolId);
        await target.parent.create(recursive: true);
        await source.rename(target.path);
        await store.putResource(toolId, resource);
        _installed.add(toolId);
        // 每个工具只保留当前资源版本，不保留随升级无限增长的副本。
        await for (final entity in target.parent.list(followLinks: false)) {
          if (entity.path != target.path) await entity.delete(recursive: true);
        }
      });

  // [人工决策-2026-09-27 20:12:08] 只卸载本工具按需资源；轻量内置代码不伪装可卸载，公共目录的视频始终归用户保留。
  Future<void> uninstall(String toolId) =>
      _locks.putIfAbsent(toolId, Lock.new).synchronized(() async {
        final target = Directory(path.join(directory.path, toolId));
        if (await target.exists()) await target.delete(recursive: true);
        await store.removeResource(toolId);
        _installed.remove(toolId);
      });
}
