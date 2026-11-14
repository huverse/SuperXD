import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:superxd/playground/challenge/challenge_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';

// 挑战题库（人工决策见 lib/playground/challenge/challenge_rules.dart）：每个能进挑战的游戏每档出 count 道题，用的就是客户端自由模式的同一份规则；
// 每道记题面、难度分，收钥匙的游戏再记能挖掉换成钥匙的条件。输出 <out>/bank/<游戏>.<档位>.json，连同仓库的 challenge/config.json 一起
// 由流水线 .github/workflows/challenge.yml 传到中转发布目录的 challenge 下，中转按修改时间热加载。
// 种子：每道题的种子由保密的题库种子推出（sha256），仓库公开也推不出线上题库；种子只在流水线机密 CHALLENGE_BANK_SEED 与开发者本机。
// 运行：CHALLENGE_BANK_SEED=<保密串> dart run tool/challenge_bank.dart --out build/challenge [--count 120]
//       本机试跑可用 --seed <任意串> 代替环境变量（只用于测试，不要上传）。
const challengeBankVersion = 1;

int challengeBankSeed(String secret, String game, PuzzleTier tier, int index) {
  final digest = sha256.convert(utf8.encode('SXD1-challenge-bank\n$secret\n$game\n${tier.name}\n$index')).bytes;
  return digest[0] << 24 | digest[1] << 16 | digest[2] << 8 | digest[3];
}

// 一个游戏一档的题库条目：同一题面只留一道。
List<Map<String, Object?>> challengeBankEntries(String secret, String game, PuzzleTier tier, int count) {
  final rules = challengeRules[game]!;
  final seen = <String>{};
  final entries = <Map<String, Object?>>[];
  for (var index = 0; entries.length < count && index < count * 3; index++) {
    final draw = rules.generate(challengeBankSeed(secret, game, tier, index), tier);
    final puzzle = rules.encodePuzzle(draw.puzzle);
    if (!seen.add(jsonEncode(puzzle))) continue;
    entries.add({
      'id': '$game.${tier.name}.$index',
      'puzzle': puzzle,
      'difficulty': rules.difficulty(draw.puzzle),
      'slots': [for (final slot in challengeSlots(game, draw.puzzle)) slot.toJson()],
    });
  }
  return entries;
}

Future<void> main(List<String> arguments) async {
  String? option(String name) {
    final index = arguments.indexOf(name);
    return index >= 0 && index + 1 < arguments.length ? arguments[index + 1] : null;
  }

  final secret = option('--seed') ?? Platform.environment['CHALLENGE_BANK_SEED'];
  if (secret == null || secret.length < 16) {
    stderr.writeln('缺少题库种子：设 CHALLENGE_BANK_SEED（至少 16 个字符）或本机试跑时给 --seed');
    exit(2);
  }
  final out = Directory(option('--out') ?? 'build/challenge');
  final count = int.parse(option('--count') ?? '120');
  final bank = Directory('${out.path}/bank');
  if (await bank.exists()) await bank.delete(recursive: true);
  await bank.create(recursive: true);
  await File('challenge/config.json').copy('${out.path}/config.json');
  for (final game in challengeRules.keys) {
    for (final tier in PuzzleTier.values) {
      final watch = Stopwatch()..start();
      final entries = challengeBankEntries(secret, game, tier, count);
      await File('${bank.path}/$game.${tier.name}.json').writeAsString(jsonEncode({'version': challengeBankVersion, 'entries': entries}));
      stdout.writeln('$game.${tier.name}: ${entries.length} 道，${watch.elapsedMilliseconds} ms');
    }
  }
}
