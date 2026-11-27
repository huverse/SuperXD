import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/app_health.dart';
import 'package:superxd/domain/campus_log.dart';

// 分批更新的健康回报与意见的本机记录（人工决策见 domain/app_health.dart）：应用支持目录下的 health.json，属于设备，切换账号保留。
// 最近 healthReportDays 天每天每个用过的版本一项（版本、有没有致命错误、发过没有、这个版本这天第一次记下的时刻），最多 healthEntryLimit 项，
// 与当前版本第一次打开的那天、意见交过没有；大小固定有界。
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

// 性能档位的原始数（11-17 加）：坏的或超出范围的当没有（最坏是少报这一项）。
int _count(Object? value) => value is int && value >= 0 && value <= 1 << 31 ? value : 0;
DateTime? _since(Object? value) => switch (value) {
  final String text => DateTime.tryParse(text)?.toUtc(),
  _ => null,
};
List<int> _launches(Object? value) => value is List && value.length == healthLaunchBounds.length + 1 && value.every((count) => count is int && count >= 0 && count <= 100000) ? List<int>.of(value.cast<int>()) : const [];

Map<String, Object?> encodeHealthRecord(HealthRecord record) => {
  'days': [
    for (final day in record.days)
      {
        'day': day.day,
        'versionCode': day.versionCode,
        'fatal': day.fatal,
        'reported': day.reported,
        if (day.launches.isNotEmpty) 'launches': day.launches,
        if (day.frames > 0) 'frames': day.frames,
        if (day.frames > 0) 'slowFrames': day.slowFrames,
        'since': ?day.since?.toIso8601String(),
      },
  ],
  'versionCode': ?record.versionCode,
  'versionSince': ?record.versionSince,
  'feedbackSent': record.feedbackSent,
};

HealthRecord decodeHealthRecord(Object? json) {
  if (json is! Map) return const HealthRecord();
  final days = <HealthDay>[
    if (json['days'] is List)
      for (final item in (json['days'] as List).take(healthEntryLimit))
        if (item case {'day': final String day, 'versionCode': final int versionCode, 'fatal': final bool fatal, 'reported': final bool reported} when _dayPattern.hasMatch(day) && versionCode > 0)
          HealthDay(day: day, versionCode: versionCode, fatal: fatal, reported: reported, launches: _launches(item['launches']), frames: _count(item['frames']), slowFrames: math.min(_count(item['slowFrames']), _count(item['frames'])), since: _since(item['since'])),
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
