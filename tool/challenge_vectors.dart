import 'dart:convert';
import 'dart:io';

import 'package:superxd/playground/challenge/challenge_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';

// 挑战判定的双端测试向量（人工决策见 lib/playground/challenge/challenge_rules.dart）：每个能进挑战的游戏、每档出几道题，
// 参考解与按固定种子改坏的答案各判一次，结果写进 server/test/vectors/challenge_judge_v1.json；服务端 TS 判定（test/challenge_judge.test.ts）
// 与客户端（test/challenge_vectors_test.dart）读同一份文件，结果必须一条不差。规则改了口径就重跑本工具，两端测试都要过。
// 运行：dart run tool/challenge_vectors.dart [--out <文件>]；本机对拍可加 --seeds <每档几道> --seed <种子>（只写到 --out，不进仓库）。
const challengeVectorsPath = 'server/test/vectors/challenge_judge_v1.json';

// 一条判定结果：solved（附答案里自带的失误数）、unsolved 或 invalid（答案解码不了）。
Map<String, Object> challengeVerdict(String game, Object? puzzleJson, Object? answerJson) {
  final rules = challengeRules[game]!;
  final puzzle = rules.decodePuzzle(puzzleJson);
  final Object? answer;
  try {
    answer = rules.decodeAnswer(answerJson);
  } on FormatException {
    return {'kind': 'invalid'};
  }
  if (!rules.solved(puzzle, answer)) return {'kind': 'unsolved'};
  return {'kind': 'solved', 'penalties': game == 'flash' ? flashPenalties(puzzle, answer) : 0};
}

int flashPenalties(Object? puzzle, Object? answer) {
  final attempts = (answer as List).length;
  final rounds = (challengeRules['flash']!.encodePuzzle(puzzle) as Map)['rounds'] as List;
  return attempts - rounds.length;
}

// JSON 里的一个叶子（整数、布尔、字符串）与它的路径。
List<List<Object>> _leaves(Object? json, [List<Object> path = const []]) => switch (json) {
  final Map<String, Object?> map => [for (final entry in map.entries) ..._leaves(entry.value, [...path, entry.key])],
  final List<Object?> list => [for (final (index, item) in list.indexed) ..._leaves(item, [...path, index])],
  _ => [path],
};

Object? _replace(Object? json, List<Object> path, Object? Function(Object? old) change) {
  if (path.isEmpty) return change(json);
  final head = path.first, rest = path.sublist(1);
  if (json is Map<String, Object?>) return {...json, head as String: _replace(json[head], rest, change)};
  final list = [...json as List<Object?>];
  list[head as int] = _replace(list[head], rest, change);
  return list;
}

Object? _bump(Object? leaf) => switch (leaf) {
  final int value => value + 1,
  final bool value => !value,
  final String value when value.isNotEmpty => (value.substring(0, value.length - 1)) + (value.endsWith('1') ? '0' : '1'),
  _ => 'x',
};

// 按固定种子把参考解改坏几种：改一个叶子、去掉最后一项、复制第一项接在末尾、整体倒过来、换成类型不对的值、空的。
// 改坏的答案有的仍然解得开（如换了等价的走法），结果一律以 Dart 规则判的为准。
List<Object?> _mutations(Object? answer, PuzzleRandom random) {
  final mutated = <Object?>[];
  final leaves = _leaves(answer);
  for (var round = 0; round < 3 && leaves.isNotEmpty; round++) {
    mutated.add(_replace(answer, leaves[random.nextInt(leaves.length)], _bump));
  }
  switch (answer) {
    case final List<Object?> list when list.isNotEmpty:
      mutated.addAll([list.sublist(0, list.length - 1), [...list, list.first], list.reversed.toList(), []]);
    case final String text when text.isNotEmpty:
      mutated.addAll([text.substring(0, text.length - 1), '${text}1', text.split('').reversed.join(), '']);
    case final Map<String, Object?> map:
      mutated.addAll([{...map}..remove(map.keys.last), {...map, 'extra': 1}]);
  }
  mutated.addAll(['oops', 7, null, {'answer': answer}]);
  return mutated;
}

// 记忆闪光：第一轮先点错一次（换下一组图案），再照参考解点完，解得开、失误 1 次。
Object? _flashWithMistake(Object? puzzleJson, Object? reference) {
  final rounds = (puzzleJson as Map)['rounds'] as List;
  final first = (rounds.first as List).cast<List<Object?>>();
  final side = puzzleJson['side'] as int;
  final wrong = [for (var cell = 0; cell < side * side; cell++) cell].firstWhere((cell) => !first.first.contains(cell));
  final answer = [...(reference as List)];
  answer[0] = first[1 % first.length];
  return [[wrong], ...answer];
}

Map<String, Object?> buildChallengeVectors({int seedsPerTier = 2, int seed = 0x5EED2026}) {
  final random = PuzzleRandom(seed);
  final games = <String, Object?>{};
  for (final MapEntry(key: game, value: rules) in challengeRules.entries) {
    final cases = <Map<String, Object?>>[];
    for (final tier in PuzzleTier.values) {
      for (var index = 0; index < seedsPerTier; index++) {
        final draw = rules.generate(random.nextUint32(), tier);
        final puzzle = rules.encodePuzzle(draw.puzzle);
        final reference = rules.encodeAnswer(draw.solution);
        final answers = [reference, ..._mutations(reference, random), if (game == 'flash') _flashWithMistake(puzzle, reference)];
        cases.add({
          'tier': tier.name,
          'puzzle': puzzle,
          'answers': [for (final answer in answers) {'answer': answer, 'expect': challengeVerdict(game, puzzle, answer)}],
        });
      }
    }
    games[game] = cases;
  }
  return {'version': 1, 'games': games};
}

Future<void> main(List<String> arguments) async {
  String? option(String name) {
    final index = arguments.indexOf(name);
    return index >= 0 && index + 1 < arguments.length ? arguments[index + 1] : null;
  }

  final out = option('--out') ?? challengeVectorsPath;
  final vectors = buildChallengeVectors(seedsPerTier: int.parse(option('--seeds') ?? '2'), seed: int.parse(option('--seed') ?? '${0x5EED2026}'));
  await File(out).writeAsString('${jsonEncode(vectors)}\n');
  stdout.writeln('已写入 $out');
}
