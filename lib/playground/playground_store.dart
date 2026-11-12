import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/playground/puzzle_rules.dart';

// 一档里的最好成绩：最快用时与那一局的步数（不计步数的游戏为空）、完成的时刻。
class PlaygroundBest {
  const PlaygroundBest({required this.millis, required this.moves, required this.at});
  final int millis;
  final int? moves;
  final DateTime at;
}

// 游乐场的本机记录（设备级，切换教务账号保留）：每个游戏每档的最好成绩、每个游戏上次选的档、最近玩过的游戏。
// 存在应用支持目录 playground/playground.json，先写临时文件再改名，写入排队；读到坏文件当没有记录。
// 大小有上限：游戏数 × 五档的最好成绩，最近玩过最多 playgroundRecentLimit 个，不随玩的次数增长。
// 不排除出云备份：只有成绩，换机恢复了也无妨。
class PlaygroundStore extends ChangeNotifier {
  PlaygroundStore(Future<File> Function() locate) : _locate = locate;

  // 默认放在应用支持目录（组合根用）。
  PlaygroundStore.inSupportDirectory() : _locate = (() async => File(path.join((await getApplicationSupportDirectory()).path, 'playground', 'playground.json')));

  // 测试用：只在内存里。
  PlaygroundStore.memory() : _locate = null;

  final Future<File> Function()? _locate;
  File? _file;
  final _best = <String, Map<PuzzleTier, PlaygroundBest>>{};
  final _tiers = <String, PuzzleTier>{};
  final _recent = <String>[];
  final _saveLock = Lock();
  late final Future<void> ready = _load();

  static const playgroundRecentLimit = 6;

  List<String> get recent => List.unmodifiable(_recent);
  PlaygroundBest? best(String gameId, PuzzleTier tier) => _best[gameId]?[tier];
  PuzzleTier tierOf(String gameId) => _tiers[gameId] ?? PuzzleTier.entry;

  // 这个游戏所有档里难度最高的一档最好成绩（首页卡片上显示）。
  ({PuzzleTier tier, PlaygroundBest best})? topBest(String gameId) {
    final records = _best[gameId];
    if (records == null || records.isEmpty) return null;
    final tier = records.keys.reduce((left, right) => left.index >= right.index ? left : right);
    return (tier: tier, best: records[tier]!);
  }

  Future<void> _load() async {
    final locate = _locate;
    if (locate == null) return;
    final file = _file = await locate();
    if (!await file.exists()) return;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return;
      if (json['best'] case final Map<Object?, Object?> best) {
        for (final MapEntry(key: game, value: tiers) in best.entries) {
          if (game is! String || tiers is! Map) continue;
          for (final MapEntry(key: name, value: record) in tiers.entries) {
            final tier = name is String ? PuzzleTier.named(name) : null;
            if (tier == null || record is! Map) continue;
            final millis = record['millis'], moves = record['moves'], at = DateTime.tryParse('${record['at']}');
            if (millis is! int || millis < 0 || (moves != null && moves is! int) || at == null) continue;
            (_best[game] ??= {})[tier] = PlaygroundBest(millis: millis, moves: moves as int?, at: at.toUtc());
          }
        }
      }
      if (json['tiers'] case final Map<Object?, Object?> tiers) {
        for (final MapEntry(:key, :value) in tiers.entries) {
          final tier = value is String ? PuzzleTier.named(value) : null;
          if (key is String && tier != null) _tiers[key] = tier;
        }
      }
      if (json['recent'] case final List<Object?> recent) _recent.addAll(recent.whereType<String>().take(playgroundRecentLimit));
    } catch (error, stack) {
      campusLog('[Playground] action=records_read errorType=${error.runtimeType}\n$stack');
    }
  }

  // 打开一个游戏：排到最近玩过的最前面。
  Future<void> opened(String gameId) async {
    await ready;
    _recent
      ..remove(gameId)
      ..insert(0, gameId);
    if (_recent.length > playgroundRecentLimit) _recent.removeRange(playgroundRecentLimit, _recent.length);
    notifyListeners();
    await _write();
  }

  Future<void> chooseTier(String gameId, PuzzleTier tier) async {
    await ready;
    _tiers[gameId] = tier;
    notifyListeners();
    await _write();
  }

  // 记一局完成：比这一档的最好用时快才更新，返回是不是新纪录（这一档第一次完成也算）。
  Future<bool> finish(String gameId, PuzzleTier tier, {required int millis, int? moves, required DateTime at}) async {
    await ready;
    final previous = best(gameId, tier);
    if (previous != null && previous.millis <= millis) return false;
    (_best[gameId] ??= {})[tier] = PlaygroundBest(millis: millis, moves: moves, at: at.toUtc());
    notifyListeners();
    await _write();
    return true;
  }

  Future<void> _write() => _saveLock.synchronized(() async {
    final file = _file;
    if (file == null) return;
    await file.parent.create(recursive: true);
    final pending = File('${file.path}.tmp');
    await pending.writeAsString(jsonEncode({
      'best': {
        for (final MapEntry(key: game, value: tiers) in _best.entries)
          game: {for (final MapEntry(key: tier, value: record) in tiers.entries) tier.name: {'millis': record.millis, 'moves': record.moves, 'at': record.at.toIso8601String()}},
      },
      'tiers': {for (final MapEntry(:key, :value) in _tiers.entries) key: value.name},
      'recent': _recent,
    }), flush: true);
    await pending.rename(file.path);
  });
}
