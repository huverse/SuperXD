import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:superxd/playground/challenge/challenge_rules.dart';
import 'package:superxd/playground/puzzle/ice/ice_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';

// 挑战题库（人工决策见 lib/playground/challenge/challenge_rules.dart）：每个能进挑战的游戏每档出 count 道题，用的就是客户端自由模式的同一份规则；
// 每道记题面、预计用时（秒）、难度分、碎片（天平称球没有，按玩家指认的球给）、要最少步数的游戏的最少步数，补条件的游戏再记能写成 ? 的几处，
// 冰面滑行另记几个标号的出口（每个出口当终点时的最少步数、碎片与预计用时，服务器按碎片挑真的那个）。输出 <out>/bank/<游戏>@<题面写法版本>.<档位>.json
// （文件里也写着题面写法版本 puzzleVersion，人工决策见 challenge_rules.dart 的 11-15 19:18 那条），连同仓库的 challenge/config.json 一起
// 由流水线 .github/workflows/challenge.yml 传到中转发布目录的 challenge 下，中转按修改时间热加载；别的版本的题库文件流水线不删，留给还没更新的应用。
// 种子：每道题的种子由保密的题库种子推出（sha256），仓库公开也推不出线上题库；种子只在流水线机密 CHALLENGE_BANK_SEED 与开发者本机。
// 运行：CHALLENGE_BANK_SEED=<保密串> dart run tool/challenge_bank.dart --out build/challenge [--count 120]
//       本机试跑可用 --seed <任意串> 代替环境变量（只用于测试，不要上传）。
const challengeBankVersion = 2;

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
    final seed = challengeBankSeed(secret, game, tier, index);
    final draw = rules.generate(seed, tier);
    final puzzle = rules.encodePuzzle(draw.puzzle);
    if (!seen.add(jsonEncode(puzzle))) continue;
    // 只收这个版本的客户端自己解得开的题（解码对证明唯一的试探有上限，如数回的 loopDecodeBudget）：发下去的题不会被客户端拒收。
    try {
      rules.decodePuzzle(jsonDecode(jsonEncode(puzzle)));
    } on FormatException {
      continue;
    }
    entries.add({
      'id': '$game.${tier.name}.$index',
      'puzzle': puzzle,
      'expected': rules.expectedSeconds(draw.puzzle),
      'difficulty': rules.difficulty(draw.puzzle),
      'fragment': challengeFragment(game, draw.puzzle, draw.solution),
      'minimum': challengeMinimum(game, draw.puzzle),
      'slots': [for (final slot in challengeSlots(game, draw.puzzle)) slot.toJson()],
      if (draw.puzzle case final IcePuzzle ice) 'exits': _iceExits(ice, seed),
    });
  }
  return entries;
}

// 一个游戏一档的题库文件名与内容：文件名带题面写法版本，同一个游戏换了写法就是另一份文件，旧版本的那份照旧留给没更新的应用。
String challengeBankName(String game, PuzzleTier tier) => '$game@${challengeRules[game]!.puzzleVersion}.${tier.name}.json';

Map<String, Object?> challengeBankFile(String secret, String game, PuzzleTier tier, int count) => {
  'version': challengeBankVersion,
  'puzzleVersion': challengeRules[game]!.puzzleVersion,
  'entries': challengeBankEntries(secret, game, tier, count),
};

// 冰面滑行的几个出口：每个当终点时的最少步数、碎片与预计用时（出口按格号排，玩家看到的 ①②③ 就是这个顺序）。
List<Map<String, int>> _iceExits(IcePuzzle puzzle, int seed) => [
  for (final cell in iceExits(puzzle, PuzzleRandom(seed ^ 0x5bd1e995)))
    () {
      final goal = IcePuzzle(width: puzzle.width, height: puzzle.height, rocks: puzzle.rocks, start: puzzle.start, goal: cell);
      final least = iceMinMoves(goal)!;
      return {'cell': cell, 'minimum': least, 'fragment': least, 'expected': const IceRules().expectedSeconds(goal), 'difficulty': const IceRules().difficulty(goal)};
    }(),
];

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
      final file = challengeBankFile(secret, game, tier, count);
      final name = challengeBankName(game, tier);
      await File('${bank.path}/$name').writeAsString(jsonEncode(file));
      stdout.writeln('$name: ${(file['entries']! as List).length} 道，${watch.elapsedMilliseconds} ms');
    }
  }
}
