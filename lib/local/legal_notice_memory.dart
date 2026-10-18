import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:superxd/domain/campus_log.dart';

// 用户协议与隐私政策看过了哪一版（修订号由 page/legal_page.dart 的 legalRevision 给）：应用支持目录下固定大小的 legal_notice.json，
// 属于设备，切换账号保留。先写临时文件再改名；读到坏文件当没看过（大不了多提示一次）。
class LegalNoticeMemory extends ChangeNotifier {
  LegalNoticeMemory._(this._file, this._seenRevision);
  final File? _file;
  int? _seenRevision;
  int? _pending;

  static Future<LegalNoticeMemory> open(File file) async {
    if (!await file.exists()) return LegalNoticeMemory._(file, null);
    try {
      final json = jsonDecode(await file.readAsString());
      return LegalNoticeMemory._(file, json is Map && json['seenRevision'] is int ? json['seenRevision'] as int : null);
    } catch (error, stack) {
      campusLog('[Legal] action=memory_read errorType=${error.runtimeType}\n$stack');
      return LegalNoticeMemory._(file, null);
    }
  }

  // 测试用：只在内存里。
  LegalNoticeMemory.memory({int? seenRevision}) : this._(null, seenRevision);

  int? get seenRevision => _seenRevision;

  // [人工决策-2026-10-18 18:07:31] 协议与政策更新后「打开时提示一次」（用户选定，同大厂的更新告知）：看过这一版不提示；
  // 新装的（系统记的首次安装与最近更新是同一时刻）直接记下、不提示，他们在登录页勾选同意；从旧版升级来的待提示一次，点「知道了」才记下。
  Future<void> check(int revision, {required bool freshInstall}) async {
    if (_seenRevision == revision) return;
    if (_seenRevision == null && freshInstall) return markSeen(revision);
    _pending = revision;
    notifyListeners();
  }

  // 取走待提示的修订号：一次运行只弹一次。
  int? takePending() {
    final pending = _pending;
    _pending = null;
    return pending;
  }

  Future<void> markSeen(int revision) async {
    _seenRevision = revision;
    final file = _file;
    if (file == null) return;
    await file.parent.create(recursive: true);
    final pending = File('${file.path}.tmp');
    await pending.writeAsString(jsonEncode({'seenRevision': revision}), flush: true);
    await pending.rename(file.path);
  }
}
