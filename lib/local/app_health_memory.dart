import 'dart:convert';
import 'dart:io';

import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/app_health.dart';
import 'package:superxd/domain/campus_log.dart';

// 分批更新的健康回报与意见的本机记录（人工决策见 domain/app_health.dart）：应用支持目录下的 health.json，属于设备，切换账号保留。
// 最近 healthReportDays 天每天一项（版本、有没有致命错误、发过没有）与当前版本第一次打开的那天、意见交过没有；大小固定有界。
// 先写临时文件再改名，写入经锁一个接一个；读到坏文件或坏项当没有（最坏是少报一天）。
class FileAppHealthMemory implements AppHealthMemory {
  FileAppHealthMemory._(this._file, this._record);
  final File? _file;
  HealthRecord _record;
  final _lock = Lock();

  static Future<FileAppHealthMemory> open(File file) async {
    if (!await file.exists()) return FileAppHealthMemory._(file, const HealthRecord());
    try {
      return FileAppHealthMemory._(file, decodeHealthRecord(jsonDecode(await file.readAsString())));
    } catch (error, stack) {
      campusLog('[AppHealth] action=memory_read errorType=${error.runtimeType}\n$stack');
      return FileAppHealthMemory._(file, const HealthRecord());
    }
  }

  // 测试用：只在内存里。
  FileAppHealthMemory.memory([HealthRecord record = const HealthRecord()]) : this._(null, record);

  @override
  HealthRecord get record => _record;

  @override
  Future<void> save(HealthRecord record) {
    _record = record;
    return _lock.synchronized(() async {
      final file = _file;
      if (file == null) return;
      await file.parent.create(recursive: true);
      final pending = File('${file.path}.tmp');
      await pending.writeAsString(jsonEncode(encodeHealthRecord(record)), flush: true);
      await pending.rename(file.path);
    });
  }
}

final _dayPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

Map<String, Object?> encodeHealthRecord(HealthRecord record) => {
  'days': [for (final day in record.days) {'day': day.day, 'versionCode': day.versionCode, 'fatal': day.fatal, 'reported': day.reported}],
  'versionCode': ?record.versionCode,
  'versionSince': ?record.versionSince,
  'feedbackSent': record.feedbackSent,
};

HealthRecord decodeHealthRecord(Object? json) {
  if (json is! Map) return const HealthRecord();
  final days = <HealthDay>[
    if (json['days'] is List)
      for (final item in (json['days'] as List).take(healthReportDays * 2))
        if (item case {'day': final String day, 'versionCode': final int versionCode, 'fatal': final bool fatal, 'reported': final bool reported} when _dayPattern.hasMatch(day) && versionCode > 0)
          HealthDay(day: day, versionCode: versionCode, fatal: fatal, reported: reported),
  ];
  return HealthRecord(
    days: days,
    versionCode: switch (json['versionCode']) {
      final int code when code > 0 => code,
      _ => null,
    },
    versionSince: switch (json['versionSince']) {
      final String day when _dayPattern.hasMatch(day) => day,
      _ => null,
    },
    feedbackSent: json['feedbackSent'] == true,
  );
}
