import 'dart:convert';
import 'dart:io';

import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/pass.dart';

// 积分时长券的本机记录（人工决策见 domain/pass.dart）：应用支持目录下的 pass.json（上次拉到的清单与当前应用账号买到哪天，换了账号从头记），
// 写法同 legal_notice.json（先写临时文件再改名、写入排队），坏文件当没有记录；清单最多 passOfferLimit 项、只记一个账号，大小有界。
class FilePassMemory implements PassMemory {
  FilePassMemory._(this._file, this._offers, this._account, this._held);
  final File? _file;
  List<PassOffer> _offers;
  String? _account;
  Map<String, DateTime> _held;
  final _lock = Lock();

  static Future<FilePassMemory> open(File file) async {
    try {
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        if (json case {'offers': final Object? offers}) {
          final account = json['account'] is String ? json['account'] as String : null;
          final held = account == null ? const <String, DateTime>{} : decodePassHeld({'held': json['held']});
          return FilePassMemory._(file, decodePassOffers(offers), account, held);
        }
      }
    } on FormatException catch (error, stack) {
      campusLog('[Pass] action=memory_read errorType=${error.runtimeType}\n$stack');
    }
    return FilePassMemory._(file, const [], null, const {});
  }

  FilePassMemory.memory() : this._(null, const [], null, const {});

  @override
  List<PassOffer> get offers => _offers;

  @override
  Map<String, DateTime> heldOf(String accountId) => accountId == _account ? _held : const {};

  @override
  Future<void> saveOffers(List<PassOffer> offers) {
    _offers = offers;
    return _write();
  }

  @override
  Future<void> saveHeld(String accountId, Map<String, DateTime> held) {
    _account = accountId;
    _held = held;
    return _write();
  }

  Future<void> _write() {
    final snapshot = {
      'offers': encodePassOffers(_offers),
      if (_account case final account?) ...{
        'account': account,
        'held': [for (final entry in _held.entries) {'id': entry.key, 'until': entry.value.millisecondsSinceEpoch}],
      },
    };
    return _lock.synchronized(() async {
      final file = _file;
      if (file == null) return;
      await file.parent.create(recursive: true);
      final pending = File('${file.path}.tmp');
      await pending.writeAsString(jsonEncode(snapshot), flush: true);
      await pending.rename(file.path);
    });
  }
}
