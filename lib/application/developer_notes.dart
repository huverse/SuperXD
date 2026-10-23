import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/developer_note.dart';

// 自动拉取的最小间隔：启动与每次回到前台都看一眼，间隔不到一小时的不再联网（下拉刷新不受限）。
const developerNoteRefreshGap = Duration(hours: 1);

// 开发者的话的编排（设备级，切换账号不重建；人工决策见 domain/developer_note.dart）：拉取、离线缓存、已读与弹信。
// 拉取失败只记日志，照旧显示上次拉到的；同一时刻只有一次拉取。
class DeveloperNotes extends ChangeNotifier {
  DeveloperNotes({required this._feed, required this._memory, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final DeveloperNoteFeed _feed;
  final DeveloperNoteMemory _memory;
  final DateTime Function() _clock;
  Future<void>? _fetching;

  List<DeveloperNote> get notes => _memory.record.notes;
  bool isRead(DeveloperNote note) => _memory.record.read.contains(note.id);
  bool get unread => notes.any((note) => !isRead(note));

  // 自动拉取（启动、回到前台）：距上次成功不到 developerNoteRefreshGap 就不联网；失败只记日志。
  Future<void> autoRefresh() async {
    final fetchedAt = _memory.record.fetchedAt;
    if (fetchedAt != null && _clock().toUtc().difference(fetchedAt) < developerNoteRefreshGap) return;
    try {
      await refresh();
    } on DeveloperNoteException catch (error) {
      campusLog('[DeveloperNotes] action=auto_refresh errorType=DeveloperNoteException message=$error');
    } catch (error, stack) {
      campusLog('[DeveloperNotes] action=auto_refresh errorType=${error.runtimeType}\n$stack');
    }
  }

  // 下拉刷新：不受间隔限制，失败抛 DeveloperNoteException 给页面提示。
  Future<void> refresh() => _fetching ??= _fetch().whenComplete(() => _fetching = null);

  Future<void> _fetch() async {
    final notes = await _feed.fetch();
    final record = _memory.record;
    final changed = !listEquals([for (final note in notes) note.id], [for (final note in record.notes) note.id]);
    await _memory.save(DeveloperNoteRecord(notes: notes, read: record.read, shown: record.shown, fetchedAt: _clock().toUtc()));
    campusLog('[DeveloperNotes] action=fetched count=${notes.length} changed=$changed');
    notifyListeners();
  }

  // 该弹的那封（见 developerNoteLetter）；弹不弹、什么时候弹由 app_moments.dart 决定。
  DeveloperNote? get letter => developerNoteLetter(notes, _memory.record.shown, _clock().toUtc());

  // 弹出了一封：当时所有的信都记成弹过（其余没读的只在入口标出），弹出的这封记成读过。
  Future<void> markLetterShown(DeveloperNote note) => _update(read: {note.id}, shown: {for (final item in notes) item.id});

  Future<void> markRead(DeveloperNote note) => isRead(note) ? Future.value() : _update(read: {note.id});

  // 写本机记录失败只记日志：标记丢了，大不了下次还标没读、再弹一次。
  Future<void> _update({Set<String> read = const {}, Set<String> shown = const {}}) async {
    final record = _memory.record;
    final saving = _memory.save(DeveloperNoteRecord(notes: record.notes, read: {...record.read, ...read}, shown: {...record.shown, ...shown}, fetchedAt: record.fetchedAt));
    notifyListeners();
    try {
      await saving;
    } catch (error, stack) {
      campusLog('[DeveloperNotes] action=mark errorType=${error.runtimeType}\n$stack');
    }
  }
}
