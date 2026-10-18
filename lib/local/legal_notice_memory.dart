import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:superxd/domain/campus_log.dart';

// 用户协议与隐私政策：在首次启动的弹窗里同意过哪一版、看过了哪一版（修订号由 page/legal_page.dart 的 legalRevision 给）。
// 应用支持目录下固定大小的 legal_notice.json，属于设备，切换账号保留。先写临时文件再改名；读到坏文件当没同意过（大不了多问一次）。
class LegalNoticeMemory extends ChangeNotifier {
  LegalNoticeMemory._(this._file, this._seenRevision, this._agreedRevision) {
    if (_agreedRevision != null) _agreed.complete();
  }
  final File? _file;
  int? _seenRevision;
  int? _agreedRevision;
  ({int revision, bool consent})? _pending;
  final _agreed = Completer<void>();

  static Future<LegalNoticeMemory> open(File file) async {
    if (!await file.exists()) return LegalNoticeMemory._(file, null, null);
    try {
      final json = jsonDecode(await file.readAsString());
      int? revision(String key) => json is Map && json[key] is int ? json[key] as int : null;
      return LegalNoticeMemory._(file, revision('seenRevision'), revision('agreedRevision'));
    } catch (error, stack) {
      campusLog('[Legal] action=memory_read errorType=${error.runtimeType}\n$stack');
      return LegalNoticeMemory._(file, null, null);
    }
  }

  // 测试用：只在内存里。
  LegalNoticeMemory.memory({int? seenRevision, int? agreedRevision}) : this._(null, seenRevision, agreedRevision);

  int? get seenRevision => _seenRevision;
  int? get agreedRevision => _agreedRevision;

  // 同意之后才完成（已同意过的立即完成）：组合根等它再做会联网的事（自动检查更新、私信收取）。
  Future<void> get agreed => _agreed.future;

  // [人工决策-2026-10-18 21:08:22] 首次启动先征得同意（用户选定，同国内大厂与工信部要求）：没在弹窗里同意过的都先弹「同意 / 不同意」，
  // 新装与从旧版升级来的老用户都算（含 alpha.4 点过「知道了」的），同意前不联网；同意过的，协议与政策有实质变化时照旧提示一次，
  // 点「知道了」才记下。取代 18:07:31 的“新装直接记下、不提示”。不同意的处理见 page/legal_page.dart 的 askLegalConsent。
  void check(int revision) {
    if (_agreedRevision != null && _seenRevision == revision) return;
    _pending = (revision: revision, consent: _agreedRevision == null);
    notifyListeners();
  }

  // 取走待弹的提示：一次运行只弹一次。consent 为真时要征得同意，否则只是更新提示。
  ({int revision, bool consent})? takePending() {
    final pending = _pending;
    _pending = null;
    return pending;
  }

  Future<void> markSeen(int revision) async {
    _seenRevision = revision;
    await _write();
  }

  Future<void> markAgreed(int revision) async {
    _agreedRevision = revision;
    _seenRevision = revision;
    if (!_agreed.isCompleted) _agreed.complete();
    await _write();
  }

  Future<void> _write() async {
    final file = _file;
    if (file == null) return;
    await file.parent.create(recursive: true);
    final pending = File('${file.path}.tmp');
    await pending.writeAsString(jsonEncode({'seenRevision': _seenRevision, 'agreedRevision': _agreedRevision}), flush: true);
    await pending.rename(file.path);
  }
}
