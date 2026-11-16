import 'dart:convert';

// [人工决策-2026-11-16 13:28:21] 同步记录（用户嫌自动同步「只知道同步了一次、不知道同步了什么，也不能像手动同步那样覆盖或选择性覆盖」，
// 选「记录 + 通知 + 随时处理」）：每一轮同步（自动、手动）都留一条记录，写清课表哪几门新增、删除、改了什么，新出、改了哪几门成绩；
// 自动同步有变化时发一条系统通知，点开看记录；和你改过的课表冲突的教务课表放进学业页的「待处理」，随时打开同样的逐项合并、整份替换页；
// 自动落库的课表变化在记录里可以一键撤回（恢复同步前那一版，存成新版本）。记录只在本机账号库，最多 syncRecordLimit 条，新的进来挤掉最旧的。
const syncRecordLimit = 50;
// 一条记录里每一类最多记这么多门课的名字（再多只计数），整条的大小有上限。
const syncRecordNames = 30;

enum SyncTrigger { manual, auto }

// 一个学期的一类变化。first 是这台手机第一次同步到这个学期的这类数据（全是新的，不算「有变化」，不发通知）。
sealed class SyncChange {
  const SyncChange({required this.termKey, required this.termLabel});
  final String termKey;
  final String termLabel;
}

// 课表：落了库的变化（before 是同步前那一版，撤回就恢复它；held 为真是和你改过的课表冲突、还没落库、等你来选）。
class ScheduleSyncChange extends SyncChange {
  const ScheduleSyncChange({required super.termKey, required super.termLabel, this.added = const [], this.removed = const [], this.changed = const [], this.counts = (0, 0, 0), this.first = false, this.held = false, this.before});
  final List<String> added;
  final List<String> removed;
  // 「课名：改了哪些」。
  final List<String> changed;
  // 新增、删除、改动的门数（名字只记前 syncRecordNames 个）。
  final (int, int, int) counts;
  final bool first;
  final bool held;
  final String? before;
}

// 成绩：新出的与分数变了的（「课名 分数」）。
class GradeSyncChange extends SyncChange {
  const GradeSyncChange({required super.termKey, required super.termLabel, this.added = const [], this.changed = const [], this.counts = (0, 0), this.first = false});
  final List<String> added;
  final List<String> changed;
  final (int, int) counts;
  final bool first;
}

class SyncRecord {
  const SyncRecord({this.id, required this.at, required this.trigger, this.changes = const [], this.failures = const [], this.cancelled = false});
  // 本机库里的编号，写入前为空。
  final int? id;
  final DateTime at;
  final SyncTrigger trigger;
  final List<SyncChange> changes;
  // 「项目：原因」。
  final List<String> failures;
  final bool cancelled;

  // 有值得告诉用户的变化：不算第一次同步到的。
  bool get changed => changes.any((change) => switch (change) {
    ScheduleSyncChange(:final first) => !first,
    GradeSyncChange(:final first) => !first,
  });

  Map<String, Object?> toJson() => {
    'changes': [
      for (final change in changes.take(40))
        switch (change) {
          ScheduleSyncChange() => {'kind': 'schedule', 'term': change.termKey, 'label': change.termLabel, 'added': _names(change.added), 'removed': _names(change.removed), 'changed': _names(change.changed),
            'counts': [change.counts.$1, change.counts.$2, change.counts.$3], 'first': change.first, 'held': change.held, 'before': ?change.before},
          GradeSyncChange() => {'kind': 'grades', 'term': change.termKey, 'label': change.termLabel, 'added': _names(change.added), 'changed': _names(change.changed),
            'counts': [change.counts.$1, change.counts.$2], 'first': change.first},
        },
    ],
    'failures': _names(failures),
    if (cancelled) 'cancelled': true,
  };

  // 库里读出来：认不出的项跳过，不让一条坏记录挡住整个列表。
  static SyncRecord fromRow({required int id, required String at, required String trigger, required String payload}) {
    final json = jsonDecode(payload);
    final map = json is Map ? json : const <String, Object?>{};
    List<String> strings(Object? value) => [if (value is List) for (final item in value) if (item is String) item];
    int count(Object? value, int index) => value is List && value.length > index && value[index] is int ? value[index] as int : 0;
    return SyncRecord(
      id: id,
      at: DateTime.parse(at),
      trigger: SyncTrigger.values.asNameMap()[trigger] ?? SyncTrigger.manual,
      failures: strings(map['failures']),
      cancelled: map['cancelled'] == true,
      changes: [
        if (map['changes'] case final List<Object?> list)
          for (final item in list)
            if (item is Map && item['term'] is String && item['label'] is String)
              if (item['kind'] == 'schedule')
                ScheduleSyncChange(termKey: item['term'] as String, termLabel: item['label'] as String, added: strings(item['added']), removed: strings(item['removed']), changed: strings(item['changed']),
                  counts: (count(item['counts'], 0), count(item['counts'], 1), count(item['counts'], 2)), first: item['first'] == true, held: item['held'] == true, before: item['before'] is String ? item['before'] as String : null)
              else if (item['kind'] == 'grades')
                GradeSyncChange(termKey: item['term'] as String, termLabel: item['label'] as String, added: strings(item['added']), changed: strings(item['changed']),
                  counts: (count(item['counts'], 0), count(item['counts'], 1)), first: item['first'] == true),
      ],
    );
  }

  static List<String> _names(List<String> names) => [for (final name in names.take(syncRecordNames)) name.length > 60 ? name.substring(0, 60) : name];
}

// 一类变化写成一句：「课表 · 2026-2027学年第一学期：新增 1 门、改动 2 门」。
String syncChangeLine(SyncChange change) {
  final label = change.termLabel.isEmpty ? change.termKey : change.termLabel;
  switch (change) {
    case ScheduleSyncChange(first: true):
      return '课表 · $label：第一次同步';
    case ScheduleSyncChange(:final counts, :final held):
      final parts = [if (counts.$1 > 0) '新增 ${counts.$1} 门', if (counts.$2 > 0) '删除 ${counts.$2} 门', if (counts.$3 > 0) '改动 ${counts.$3} 门'];
      return held ? '课表 · $label：教务有改动，和你改过的不一样，等你来选' : '课表 · $label：${parts.join('、')}';
    case GradeSyncChange(first: true):
      return '成绩 · $label：第一次同步';
    case GradeSyncChange(:final counts):
      return '成绩 · $label：${[if (counts.$1 > 0) '新出 ${counts.$1} 门', if (counts.$2 > 0) '改了 ${counts.$2} 门'].join('、')}';
  }
}

// 一类变化涉及的课：「新增：甲、乙；删除：丙」（第一次同步不列）。
String syncChangeNames(SyncChange change) {
  String group(String head, List<String> names) => names.isEmpty ? '' : '$head：${names.join('、')}';
  final groups = switch (change) {
    ScheduleSyncChange(first: true) || GradeSyncChange(first: true) => const <String>[],
    ScheduleSyncChange(:final added, :final removed, :final changed) => [group('新增', added), group('删除', removed), group('改动', changed)],
    GradeSyncChange(:final added, :final changed) => [group('新出', added), group('改了', changed)],
  };
  return groups.where((text) => text.isNotEmpty).join('；');
}

// 一条记录的一句话概括（列表里用）。
String syncRecordHeadline(SyncRecord record) {
  if (record.changed) {
    final schedules = record.changes.whereType<ScheduleSyncChange>().where((change) => !change.first);
    final grades = record.changes.whereType<GradeSyncChange>().where((change) => !change.first);
    final newGrades = grades.fold(0, (sum, change) => sum + change.counts.$1), changedGrades = grades.fold(0, (sum, change) => sum + change.counts.$2);
    return [
      if (schedules.any((change) => change.held)) '课表有改动等你来选',
      if (schedules.any((change) => !change.held)) '课表有变化',
      if (newGrades > 0) '新出 $newGrades 门成绩',
      if (changedGrades > 0) '$changedGrades 门成绩有改动',
    ].join(' · ');
  }
  if (record.failures.isNotEmpty) return '没有同步完：${record.failures.first}';
  if (record.cancelled) return '没有同步完';
  if (record.changes.isNotEmpty) return '第一次同步';
  return '没有变化';
}

// 自动同步有变化时的系统通知（标题与正文）；没有值得通知的为空。
({String title, String body})? syncRecordNotice(SyncRecord record) {
  if (record.trigger != SyncTrigger.auto || !record.changed) return null;
  final grades = [for (final change in record.changes.whereType<GradeSyncChange>()) if (!change.first) ...change.added];
  final held = record.changes.whereType<ScheduleSyncChange>().any((change) => !change.first && change.held);
  final title = grades.isNotEmpty ? '新出了 ${record.changes.whereType<GradeSyncChange>().where((change) => !change.first).fold(0, (sum, change) => sum + change.counts.$1)} 门成绩' : held ? '教务课表有改动，等你来选' : '课表、成绩有更新';
  final body = grades.isNotEmpty ? grades.take(3).join('、') : syncRecordHeadline(record);
  return (title: title, body: body);
}

// 自动同步的结果通知（device 层实现）：点开进学业页的同步记录。没有通知权限时什么也不做。
abstract interface class SyncNotices {
  Future<void> show(SyncRecord record);
  // 打开自动同步时申请通知权限（只在用户打开时问）；给了返回真。
  Future<bool> request();
}
