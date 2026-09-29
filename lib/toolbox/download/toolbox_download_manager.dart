import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import 'package:superxd/toolbox/media_resource.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_resource_manager.dart';
import 'package:superxd/toolbox/toolbox_store.dart';
import 'package:superxd/toolbox/toolbox_url.dart';
import 'package:superxd/domain/campus_log.dart';

class ToolboxDownloadManager extends ChangeNotifier {
  ToolboxDownloadManager({
    required this.store,
    required this.transfer,
    required this.publisher,
    required this.directory,
    required this.resources,
  });
  final ToolboxStore store;
  final ToolboxTransfer transfer;
  final ToolboxFilePublisher publisher;
  final Directory directory;
  final ToolboxResourceManager resources;
  final _downloads = <String, ToolboxDownload>{};
  final _locks = <String, Lock>{};
  final _enqueueLock = Lock();
  final _pumpLock = Lock();
  final _publishing = Lock();
  final _buffer = <String, ToolboxTransferUpdate>{};
  final _stoppingJobs = <String>{};
  final _pendingOperations = <Future<void>>{};
  StreamSubscription<ToolboxTransferUpdate>? _subscription;
  bool _closed = false;
  bool _ready = false;
  bool foreground = true;
  List<ToolboxDownload> forTool(String toolId) =>
      _downloads.values.where((item) => item.toolId == toolId).toList()..sort(
        (a, b) => a.terminal != b.terminal
            ? (a.terminal ? 1 : -1)
            : b.createdAt.compareTo(a.createdAt),
      );
  ToolboxDownload? byId(String id) => _downloads[id];
  List<ToolboxDownload> job(String id) =>
      _downloads.values.where((item) => item.jobId == id).toList();
  File file(ToolboxDownload download) =>
      File(path.join(directory.path, download.filename));
  Lock _lock(String id) => _locks.putIfAbsent(id, Lock.new);
  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> _save(ToolboxDownload download) async {
    await store.putDownload(download);
    _downloads[download.id] = download;
    _notify();
  }

  Future<void> initialize() async {
    await directory.create(recursive: true);
    for (final item in await store.downloads()) {
      _downloads[item.id] = item;
    }
    _subscription = transfer.updates.listen((update) {
      if (!_downloads.containsKey(update.id)) return;
      if (!_ready) {
        _buffer[update.id] = update;
        return;
      }
      late final Future<void> operation;
      operation = _onUpdate(update)
          .then((_) => _pump())
          .catchError((Object error, StackTrace stack) {
            campusLog(
              '[ToolboxDownload] action=update errorType=${error.runtimeType}\n$stack',
            );
          })
          .whenComplete(() => _pendingOperations.remove(operation));
      _pendingOperations.add(operation);
    });
    await transfer.initialize();
    await resources.restore();
    for (final snapshot in List<ToolboxDownload>.of(_downloads.values)) {
      final item = _downloads[snapshot.id]!;
      if (item.terminal) {
        await _clean(item);
        continue;
      }
      if (item.createdAt.isBefore(
        DateTime.now().toUtc().subtract(const Duration(hours: 24)),
      )) {
        await cancel(item.id);
        continue;
      }
      if (item.state == ToolboxDownloadState.cancelling) {
        await cancel(item.id);
        continue;
      }
      if ((item.state == ToolboxDownloadState.queued ||
              item.state == ToolboxDownloadState.paused) &&
          !item.submitted) {
        continue;
      }
      if (item.transferring ||
          item.state == ToolboxDownloadState.paused ||
          item.state == ToolboxDownloadState.pausing) {
        final update =
            _buffer.remove(item.id) ?? await transfer.lookup(item.id);
        if (update != null) {
          await _onUpdate(update);
        } else {
          await _save(
            item.change(
              state: ToolboxDownloadState.failed,
              error: '下载已中断，请重新解析后下载',
              clearUrl: true,
            ),
          );
          await _clean(item);
        }
      } else {
        await _save(item.change(state: ToolboxDownloadState.verifying));
        await _onUpdate(
          ToolboxTransferUpdate(item.id, ToolboxDownloadState.verifying),
        );
      }
    }
    _ready = true;
    for (final update in List<ToolboxTransferUpdate>.of(_buffer.values)) {
      await _onUpdate(update);
    }
    _buffer.clear();
    final active = _downloads.values
        .where((item) => !item.terminal)
        .map((item) => item.filename)
        .toSet();
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && !active.contains(path.basename(entity.path))) {
        await entity.delete();
      }
    }
    await _prune();
    await _pump();
    _notify();
  }

  Future<List<String>> downloadMedia({
    required String title,
    required String identity,
    required Uri sourceUrl,
    required String providerId,
    required List<MediaResource> media,
  }) => _enqueueLock.synchronized(() async {
    if (media.isEmpty || media.length > 100) {
      throw const ToolboxException('每次请选择1至100项媒体');
    }
    final existing = <String>[];
    final fresh = <MediaResource>[];
    final selected = <String>{};
    for (final resource in media) {
      toolboxPublicUrl(resource.url.toString(), httpsOnly: true);
      if (!selected.add(resource.id)) continue;
      final duplicate = _downloads.values
          .where(
            (item) =>
                item.identity == identity &&
                item.resourceId == resource.id &&
                (!item.terminal || item.state == ToolboxDownloadState.saved),
          )
          .firstOrNull;
      if (duplicate != null) {
        existing.add(duplicate.id);
      } else {
        fresh.add(resource);
      }
    }
    if (fresh.isEmpty) return existing;
    if (_downloads.values
            .where((item) => !item.terminal)
            .map((item) => item.jobId)
            .toSet()
            .length >=
        10) {
      throw const ToolboxException('待处理任务已满，请先完成或取消现有任务');
    }
    await transfer.requestNotifications();
    final groupId = const Uuid().v4();
    final now = DateTime.now().toUtc();
    final additions = <ToolboxDownload>[];
    for (final resource in fresh) {
      final id = const Uuid().v4();
      final item = ToolboxDownload(
        id: id,
        toolId: 'short_video',
        kind: switch (resource.kind) {
          MediaKind.video => ToolboxDownloadKind.video,
          MediaKind.image => ToolboxDownloadKind.image,
          MediaKind.audio => ToolboxDownloadKind.audio,
        },
        filename: '$id.part',
        createdAt: now,
        updatedAt: now,
        state: ToolboxDownloadState.queued,
        url: resource.url,
        title: title,
        groupId: groupId,
        groupTotal: fresh.length,
        resourceId: resource.id,
        identity: identity,
        sourceUrl: sourceUrl,
        providerId: providerId,
      );
      additions.add(item);
    }
    await store.putDownloads(additions);
    for (final item in additions) {
      _downloads[item.id] = item;
    }
    _notify();
    await _prune();
    await _pump();
    return [...existing, ...additions.map((item) => item.id)];
  });

  Future<String> downloadResource(String toolId) =>
      _enqueueLock.synchronized(() async {
        final spec = resources.specifications[toolId]!;
        final duplicate = _downloads.values
            .where((item) => item.toolId == toolId && !item.terminal)
            .firstOrNull;
        if (duplicate != null) return duplicate.id;
        if (_downloads.values
                .where((item) => !item.terminal)
                .map((item) => item.jobId)
                .toSet()
                .length >=
            10) {
          throw const ToolboxException('待处理任务已满');
        }
        toolboxPublicUrl(spec.url.toString(), httpsOnly: true);
        await transfer.requestNotifications();
        final id = const Uuid().v4();
        final now = DateTime.now().toUtc();
        await _save(
          ToolboxDownload(
            id: id,
            toolId: toolId,
            kind: ToolboxDownloadKind.resource,
            filename: '$id.part',
            createdAt: now,
            updatedAt: now,
            state: ToolboxDownloadState.queued,
            url: spec.url,
            title: '工具资源',
            resourceVersion: spec.version,
            resourceBytes: spec.bytes,
            resourceHash: spec.sha256,
          ),
        );
        await _pump();
        return id;
      });

  Future<void> _pump() => _pumpLock.synchronized(() async {
    if (!_ready || _closed) return;
    var count = _downloads.values
        .where(
          (item) =>
              item.submitted &&
              (item.transferring ||
                  item.state == ToolboxDownloadState.pausing ||
                  item.state == ToolboxDownloadState.cancelling),
        )
        .length;
    final queued = _downloads.values
        .where(
          (item) =>
              item.state == ToolboxDownloadState.queued &&
              !item.submitted &&
              !_stoppingJobs.contains(item.jobId),
        )
        .toList();
    for (final snapshot in queued) {
      if (count >= 2) break;
      await _lock(snapshot.id).synchronized(() async {
        final item = _downloads[snapshot.id];
        if (item == null ||
            item.state != ToolboxDownloadState.queued ||
            item.submitted) {
          return;
        }
        await _save(item.change(submitted: true));
        try {
          await transfer.enqueue(_downloads[item.id]!);
          count++;
        } catch (error, stack) {
          campusLog(
            '[ToolboxDownload] action=enqueue errorType=${error.runtimeType}\n$stack',
          );
          await _save(
            item.change(
              state: ToolboxDownloadState.failed,
              error: '未能启动下载，请重新解析',
              clearUrl: true,
            ),
          );
        }
      });
    }
  });

  Future<void> _onUpdate(ToolboxTransferUpdate update) async {
    if (!_downloads.containsKey(update.id)) return;
    await _lock(update.id).synchronized(() async {
      final previous = _downloads[update.id];
      if (previous == null ||
          previous.terminal ||
          previous.state == ToolboxDownloadState.cancelling) {
        return;
      }
      if (update.state == ToolboxDownloadState.queued ||
          update.state == ToolboxDownloadState.downloading) {
        if (!previous.transferring) return;
        _downloads[update.id] = previous.change(
          state: update.state,
          progress: update.progress,
          totalBytes: update.totalBytes,
        );
        _notify();
        return;
      }
      if (update.state == ToolboxDownloadState.paused) {
        if (previous.transferring ||
            previous.state == ToolboxDownloadState.pausing) {
          await _save(previous.change(state: ToolboxDownloadState.paused));
        }
        return;
      }
      if (update.state == ToolboxDownloadState.verifying) {
        if (previous.state == ToolboxDownloadState.saving ||
            previous.state == ToolboxDownloadState.awaitingSave) {
          return;
        }
        await _finish(
          previous.change(
            state: ToolboxDownloadState.verifying,
            mimeType: update.mimeType,
          ),
        );
      } else {
        await _save(
          previous.change(
            state: update.state,
            error: update.error,
            clearUrl: true,
          ),
        );
        await _clean(previous);
      }
    });
  }

  Future<void> _finish(ToolboxDownload item) async {
    await _save(item);
    try {
      final source = file(item);
      if (!await source.exists() || await source.length() == 0) {
        throw const ToolboxException('下载文件不完整，请重试');
      }
      if (item.kind == ToolboxDownloadKind.resource) {
        final spec = resources.specifications[item.toolId];
        if (spec == null ||
            spec.version != item.resourceVersion ||
            spec.sha256 != item.resourceHash) {
          throw const ToolboxException('资源版本已变更，请重新下载');
        }
        await resources.install(item.toolId, source);
        await _save(
          item.change(
            state: ToolboxDownloadState.installed,
            progress: 1,
            clearUrl: true,
          ),
        );
        await transfer.forget(item.id);
      } else {
        final handle = await source.open();
        late final List<int> header;
        try {
          header = await handle.read(512);
        } finally {
          await handle.close();
        }
        final mime = lookupMimeType('download', headerBytes: header);
        final allowed = switch (item.kind) {
          ToolboxDownloadKind.image => const {
            'image/jpeg',
            'image/png',
            'image/webp',
            'image/gif',
          },
          ToolboxDownloadKind.audio => const {
            'audio/mpeg',
            'audio/mp4',
            'audio/aac',
            'audio/ogg',
            'audio/wav',
          },
          _ => const {
            'video/mp4',
            'video/webm',
            'video/quicktime',
            'video/x-matroska',
            'video/x-msvideo',
          },
        };
        if (mime == null ||
            !allowed.contains(mime) ||
            (item.mimeType != null &&
                (item.mimeType!.contains('text/') ||
                    item.mimeType!.contains('json') ||
                    item.mimeType!.contains('mpegurl')))) {
          throw const ToolboxException('下载结果不是可保存的媒体文件');
        }
        final ready = item.change(
          state: ToolboxDownloadState.awaitingSave,
          mimeType: mime,
          progress: 1,
        );
        await _save(ready);
        await transfer.forget(item.id);
        if (foreground) await _publish(ready);
      }
    } catch (error, stack) {
      campusLog(
        '[ToolboxDownload] action=finish errorType=${error.runtimeType}\n$stack',
      );
      await _save(
        item.change(
          state: ToolboxDownloadState.failed,
          error: error is ToolboxException ? error.message : '文件处理失败，请重试',
          clearUrl: true,
        ),
      );
      await _clean(item);
    }
    await _prune();
  }

  Future<void> save(String id) => _lock(id).synchronized(() async {
    final item = _downloads[id];
    if (item?.state == ToolboxDownloadState.awaitingSave) await _publish(item!);
  });
  Future<void> _publish(
    ToolboxDownload item,
  ) => _publishing.synchronized(() async {
    if (!foreground) return;
    await _save(item.change(state: ToolboxDownloadState.saving));
    try {
      final extension = switch (item.mimeType) {
        'video/webm' => 'webm',
        'video/quicktime' => 'mov',
        'video/x-matroska' => 'mkv',
        'video/x-msvideo' => 'avi',
        'image/jpeg' => 'jpg',
        'image/png' => 'png',
        'image/webp' => 'webp',
        'image/gif' => 'gif',
        'audio/mpeg' => 'mp3',
        'audio/mp4' => 'm4a',
        'audio/aac' => 'aac',
        'audio/ogg' => 'ogg',
        'audio/wav' => 'wav',
        _ => 'mp4',
      };
      final uri = await publisher.publish(
        id: item.id,
        source: file(item).path,
        filename: 'SuperXD_${item.id}.$extension',
        mimeType: item.mimeType!,
      );
      if (uri == null) {
        await _save(item.change(state: ToolboxDownloadState.awaitingSave));
        return;
      }
      await _save(
        item.change(
          state: ToolboxDownloadState.saved,
          savedUri: uri,
          clearUrl: true,
        ),
      );
      campusLog('[ToolboxDownload] action=saved');
    } catch (error, stack) {
      campusLog(
        '[ToolboxDownload] action=publish errorType=${error.runtimeType}\n$stack',
      );
      await _save(
        item.change(
          state: ToolboxDownloadState.awaitingSave,
          error: '保存未完成，可重试保存',
        ),
      );
      return;
    }
    try {
      await _clean(item);
    } catch (error, stack) {
      campusLog(
        '[ToolboxDownload] action=clean_saved errorType=${error.runtimeType}\n$stack',
      );
    }
  });

  Future<void> resume() async {
    foreground = true;
    for (final item in List<ToolboxDownload>.of(_downloads.values)) {
      if (!item.terminal &&
          item.createdAt.isBefore(
            DateTime.now().toUtc().subtract(const Duration(hours: 24)),
          )) {
        await cancel(item.id);
        continue;
      }
      if (item.state == ToolboxDownloadState.awaitingSave) await save(item.id);
    }
    await _pump();
  }

  Future<void> pauseTask(String id) async {
    await _lock(id).synchronized(() async {
      final item = _downloads[id];
      if (item == null || !item.transferring) return;
      if (!item.submitted) {
        await _save(item.change(state: ToolboxDownloadState.paused));
        return;
      }
      await _save(item.change(state: ToolboxDownloadState.pausing));
      if (!await transfer.pause(id)) {
        await _save(item);
        throw const ToolboxException('该资源不支持暂停，可取消后重新解析');
      }
      await _save(item.change(state: ToolboxDownloadState.paused));
    });
    await _pump();
  }

  Future<void> resumeTask(String id) async {
    await _pumpLock.synchronized(
      () => _lock(id).synchronized(() async {
        final item = _downloads[id];
        if (item == null || item.state != ToolboxDownloadState.paused) return;
        if (!item.submitted) {
          await _save(item.change(state: ToolboxDownloadState.queued));
          return;
        }
        if (_downloads.values
                .where((other) => other.submitted && other.transferring)
                .length >=
            2) {
          throw const ToolboxException('已有两个传输任务，请稍后继续');
        }
        if (!await transfer.resume(id)) {
          throw const ToolboxException('无法继续下载，请重新解析');
        }
        await _save(item.change(state: ToolboxDownloadState.queued));
      }),
    );
    await _pump();
  }

  Future<void> cancel(String id, {bool dispatch = true}) async {
    await _lock(id).synchronized(() async {
      final item = _downloads[id];
      if (item == null || item.terminal) return;
      await _save(item.change(state: ToolboxDownloadState.cancelling));
      try {
        if (item.submitted) await transfer.cancel(id);
        await _clean(item);
        await _save(
          item.change(state: ToolboxDownloadState.cancelled, clearUrl: true),
        );
      } catch (error, stack) {
        campusLog(
          '[ToolboxDownload] action=cancel errorType=${error.runtimeType}\n$stack',
        );
        await _save(
          item.change(
            state: ToolboxDownloadState.cancelling,
            error: '任务仍在停止，请重试取消',
          ),
        );
        rethrow;
      }
    });
    if (dispatch) await _pump();
  }

  Future<void> cancelJob(String groupId) async {
    _stoppingJobs.add(groupId);
    try {
      for (final item in job(groupId).where((item) => !item.terminal)) {
        await cancel(item.id, dispatch: false);
      }
    } finally {
      _stoppingJobs.remove(groupId);
    }
    await _pump();
  }

  Future<void> deleteJob(String groupId) => _enqueueLock.synchronized(() async {
    final items = job(groupId);
    if (items.any((item) => !item.terminal)) {
      throw const ToolboxException('请先取消进行中的任务');
    }
    for (final item in items) {
      await _lock(item.id).synchronized(() async {
        await _clean(item);
        await store.removeDownload(item.id);
        _downloads.remove(item.id);
      });
      _locks.remove(item.id);
    }
    _notify();
  });
  Future<void> uninstall(String toolId) => _enqueueLock.synchronized(() async {
    for (final item in forTool(toolId).where((item) => !item.terminal)) {
      await cancel(item.id, dispatch: false);
    }
    await resources.uninstall(toolId);
    _notify();
    await _pump();
  });
  Future<void> open(String id) async {
    final item = _downloads[id]!;
    try {
      await publisher.open(item.savedUri!, item.mimeType!);
    } catch (error, stack) {
      campusLog(
        '[ToolboxDownload] action=open errorType=${error.runtimeType}\n$stack',
      );
      throw const ToolboxException('本地文件无法打开，可在下载管理删除记录后重新下载');
    }
  }

  Future<void> _clean(ToolboxDownload item) async {
    final source = file(item);
    if (await source.exists()) await source.delete();
    await transfer.forget(item.id);
  }

  Future<void> _prune() async {
    final groups = <String, List<ToolboxDownload>>{};
    for (final item in _downloads.values) {
      groups.putIfAbsent(item.jobId, () => []).add(item);
    }
    final done =
        groups.values
            .where((items) => items.every((item) => item.terminal))
            .toList()
          ..sort((a, b) => b.first.updatedAt.compareTo(a.first.updatedAt));
    var retained = 0;
    final obsolete = <ToolboxDownload>[];
    final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 30));
    for (final items in done) {
      retained += items.length;
      if (retained > 100 ||
          items.every((item) => item.updatedAt.isBefore(cutoff))) {
        obsolete.addAll(items);
      }
    }
    for (final item in obsolete) {
      await _clean(item);
      _downloads.remove(item.id);
      _locks.remove(item.id);
    }
    await store.removeDownloads(obsolete.map((item) => item.id).toList());
  }

  Future<void> close() async {
    _closed = true;
    await _subscription?.cancel();
    await Future.wait(_pendingOperations);
    await transfer.close();
    super.dispose();
  }
}
