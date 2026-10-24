import 'dart:convert';
import 'dart:io';

import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/festival.dart';

// 节日的本机记录（人工决策见 domain/festival.dart）：应用支持目录下的 festival.json，属于设备，切换账号保留。
// 参与号、近 30 天打开过的校园日、播过与抽过签的节日、抽中的奖品；各项都有上限（见 FestivalRecord），文件大小有界。
// 先写临时文件再改名，写入经锁一个接一个；读到坏文件当没有记录（最坏是重播一次动画、换一个参与号）。
class FileFestivalMemory implements FestivalMemory {
  FileFestivalMemory._(this._file, this._record);
  final File? _file;
  FestivalRecord _record;
  final _lock = Lock();

  static Future<FileFestivalMemory> open(File file) async {
    if (!await file.exists()) return FileFestivalMemory._(file, const FestivalRecord());
    try {
      return FileFestivalMemory._(file, decodeFestivalRecord(jsonDecode(await file.readAsString())));
    } catch (error, stack) {
      campusLog('[Festival] action=memory_read errorType=${error.runtimeType}\n$stack');
      return FileFestivalMemory._(file, const FestivalRecord());
    }
  }

  // 测试用：只在内存里。
  FileFestivalMemory.memory([FestivalRecord record = const FestivalRecord()]) : this._(null, record);

  @override
  FestivalRecord get record => _record;

  @override
  Future<void> save(FestivalRecord record) {
    List<String> recent(List<String> ids) => ids.length > festivalHistoryLimit ? ids.sublist(ids.length - festivalHistoryLimit) : ids;
    _record = FestivalRecord(participant: record.participant, activeDays: record.activeDays, played: recent(record.played), drawn: recent(record.drawn), prizes: record.prizes);
    final snapshot = _record;
    return _lock.synchronized(() async {
      final file = _file;
      if (file == null) return;
      await file.parent.create(recursive: true);
      final pending = File('${file.path}.tmp');
      await pending.writeAsString(jsonEncode(encodeFestivalRecord(snapshot)), flush: true);
      await pending.rename(file.path);
    });
  }
}

Map<String, Object?> encodeFestivalRecord(FestivalRecord record) => {
  'participant': record.participant,
  'activeDays': (record.activeDays.toList()..sort()),
  'played': record.played,
  'drawn': record.drawn,
  'prizes': [
    for (final prize in record.prizes)
      {'occasion': prize.occasion, 'kind': prize.kind.name, 'content': prize.content, 'note': prize.note, 'wonAt': prize.wonAt.toUtc().toIso8601String(), 'revealed': prize.revealed},
  ],
};

// 本机文件也按外部输入读：认不出的项丢掉，不让一项坏数据拖垮整份记录。
FestivalRecord decodeFestivalRecord(Object? json) {
  if (json is! Map) throw const FormatException('不是节日记录');
  List<String> strings(String key) => json[key] is List ? [...(json[key] as List).whereType<String>()] : [];
  final participant = json['participant'];
  return FestivalRecord(
    participant: participant is String && RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(participant) ? participant : null,
    activeDays: {...strings('activeDays').where(RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch)},
    played: strings('played'),
    drawn: strings('drawn'),
    prizes: [
      if (json['prizes'] is List)
        for (final item in json['prizes'] as List)
          if (item case {'occasion': final String occasion, 'kind': final String kind, 'content': final String content, 'note': final String note, 'wonAt': final String wonAt, 'revealed': final bool revealed}
              when DateTime.tryParse(wonAt) != null && FestivalPrizeKind.values.any((value) => value.name == kind))
            FestivalPrize(occasion: occasion, kind: FestivalPrizeKind.values.byName(kind), content: content, note: note, wonAt: DateTime.parse(wonAt).toUtc(), revealed: revealed),
    ],
  );
}
