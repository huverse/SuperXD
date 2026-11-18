import 'dart:convert';
import 'dart:io';

import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/developer_note.dart';

// 开发者的话的本机记录：应用支持目录下的 developer_notes.json，属于设备，切换账号保留。
// 存上次拉到的信（离线也能看）、读过与弹过的编号、上次拉取成功的时刻；信最多 developerNoteLimit 封，编号只留还在清单里的，文件大小有上限。
// 先写临时文件再改名，写入经锁一个接一个；读到坏文件当没有记录（大不了没读的再标一次）。
// [人工决策-2026-11-18 23:24:41] 弹过的编号存在 closed（用户关掉了才算），旧版本记在 shown 里的不认：旧版一弹出就记，
// 11-18 欢迎信在旧版里刚弹出就被强制更新盖住、用户直接去更新，新版就再也不弹（alpha.28 也不认红包）。用户选定让这些信在新版里再弹一次。
class FileDeveloperNoteMemory implements DeveloperNoteMemory {
  FileDeveloperNoteMemory._(this._file, this._record);
  final File? _file;
  DeveloperNoteRecord _record;
  final _lock = Lock();

  static Future<FileDeveloperNoteMemory> open(File file) async {
    if (!await file.exists()) return FileDeveloperNoteMemory._(file, const DeveloperNoteRecord());
    try {
      final json = jsonDecode(await file.readAsString());
      Set<String> ids(String key) => json is Map && json[key] is List ? {...(json[key] as List).whereType<String>()} : {};
      return FileDeveloperNoteMemory._(file, DeveloperNoteRecord(
        notes: decodeDeveloperNotes(json),
        read: ids('read'),
        shown: ids('closed'),
        fetchedAt: json is Map && json['fetchedAt'] is String ? DateTime.tryParse(json['fetchedAt'] as String)?.toUtc() : null,
        fetchedBuild: json is Map && json['build'] is int ? json['build'] as int : null,
      ));
    } catch (error, stack) {
      campusLog('[DeveloperNotes] action=memory_read errorType=${error.runtimeType}\n$stack');
      return FileDeveloperNoteMemory._(file, const DeveloperNoteRecord());
    }
  }

  // 测试用：只在内存里。
  FileDeveloperNoteMemory.memory([DeveloperNoteRecord record = const DeveloperNoteRecord()]) : this._(null, record);

  @override
  DeveloperNoteRecord get record => _record;

  @override
  Future<void> save(DeveloperNoteRecord record) {
    final present = {for (final note in record.notes) note.id};
    _record = DeveloperNoteRecord(notes: record.notes, read: record.read.intersection(present), shown: record.shown.intersection(present), fetchedAt: record.fetchedAt, fetchedBuild: record.fetchedBuild);
    final snapshot = _record;
    return _lock.synchronized(() async {
      final file = _file;
      if (file == null) return;
      await file.parent.create(recursive: true);
      final pending = File('${file.path}.tmp');
      await pending.writeAsString(jsonEncode({
        ...encodeDeveloperNotes(snapshot.notes),
        'read': snapshot.read.toList(),
        'closed': snapshot.shown.toList(),
        'fetchedAt': snapshot.fetchedAt?.toUtc().toIso8601String(),
        'build': snapshot.fetchedBuild,
      }), flush: true);
      await pending.rename(file.path);
    });
  }
}
