import 'dart:math' as math;

// 谜题规则的公共契约（纯 Dart，不依赖 Flutter）：自由模式在本机出题与判定，挑战模式的题库由 tool 下的工具用同一份规则离线生成，
// 服务器按同一份编码核对答案（TS 核对器与这里共用测试向量，挑战阶段再加）。所以出题只许用 PuzzleRandom，不用 dart:math 的 Random。
// [人工决策-2026-11-12 21:00:20] 游乐场的长期架构（用户提出、选项选定，见 lib/playground/CLAUDE.md）：每个游戏 = 规则 + 页面，
// 规则按种子出题、给出参考解、判定答案、给难度分并能编解码，挑战模式（服务器逐关核对、按上一关的结果出下一关）直接复用，不另写一套。
// [人工决策-2026-11-14 23:11:48] 用户选「预计用时做标尺」：每道题给一般玩家的预计用时（秒），难度分 1–10 一律按预计用时取对数（puzzleDifficulty），
// 跨游戏可比；各游戏原来的打分改叫 complexity，只在同一个游戏里分档、排难易，再乘上这个游戏的节奏换成秒（puzzlePace）。
// 系数先按常见的人工解题速度定（各游戏写在 expectedSeconds 旁），挑战上线后服务器按真实过关用时回调各游戏的倍数（server 的 challenge_pace.ts）。

// 五档难度：自由模式按档出题，挑战模式的关卡也按档从题库里挑。档位名字发出后不改（本机记录与题库都按 name 存）。
enum PuzzleTier {
  entry('入门'),
  easy('简单'),
  normal('普通'),
  hard('困难'),
  expert('专家');

  const PuzzleTier(this.label);
  final String label;

  static PuzzleTier? named(String name) => values.where((tier) => tier.name == name).firstOrNull;
}

// 出一道题的结果：题面与一份参考解（挑战题库存参考解给服务器核对与取结果；页面不显示它，只在测试与工具里用）。
class PuzzleDraw<P, A> {
  const PuzzleDraw(this.puzzle, this.solution);
  final P puzzle;
  final A solution;
}

// 题面与答案编码成 JSON 可表示的值；decode 是外部输入的边界（题库、存档），不合法抛 FormatException。
abstract class PuzzleRules<P, A> {
  const PuzzleRules();

  // 同一个种子、同一档出同一道题。
  PuzzleDraw<P, A> generate(int seed, PuzzleTier tier);

  // 答案是否解开这道题：按规则判定，不和参考解逐项比（有多解的题，任何一个合规的解都算）。
  bool solved(P puzzle, A answer);

  // 这个游戏里的难易 1–10：按求解要走的步数、推理深度算，只在同一个游戏的题之间比（档与档单调上升），预计用时由它换算。
  int complexity(P puzzle);

  // 一般玩家解这道题的预计用时（秒）。
  int expectedSeconds(P puzzle);

  // 难度分 1–10：按预计用时取对数，跨游戏可比（挑战的计分与参考用时用它）。
  int difficulty(P puzzle) => puzzleDifficulty(expectedSeconds(puzzle));

  // 题面写法的版本（从 1 起）：改了 encodePuzzle 与 decodePuzzle 的写法，就在这个游戏的规则里覆写它加一（挑战按「游戏@版本」下发，
  // 没更新的应用照旧拿认得的版本；样例钉在 test/challenge_vectors_test.dart，人工决策见 challenge/challenge_rules.dart 的 11-15 19:18 那条）。
  int get puzzleVersion => 1;

  Object encodePuzzle(P puzzle);
  P decodePuzzle(Object? json);
  Object encodeAnswer(A answer);
  A decodeAnswer(Object? json);
}

// 预计用时换难度分：10 秒以内 1 分，往后每翻一倍加 1.4 分（约 25 秒 2 分、1 分钟 4 分、2 分钟 5 分、5 分钟 7 分、10 分钟 8 分、20 分钟起 10 分）。
int puzzleDifficulty(int seconds) => seconds <= 10 ? 1 : (1.4 * math.log(seconds / 10) / math.ln2).round().clamp(1, 10);

// 按这个游戏里的难易估预计用时：complexity 为 1 时约 base 秒，每高 1 级乘 growth（解题用时近似对数正态，难易每高一级用时按固定倍数涨）。
int puzzlePace(int complexity, {required double base, required double growth}) => (base * math.pow(growth, complexity - 1)).round();

// 外部输入解码的小工具：取 Map 里的整数、整数列表，类型或范围不对抛 FormatException。
int puzzleInt(Object? json, String key, {required int min, required int max}) {
  final value = json is Map ? json[key] : null;
  if (value is! int || value < min || value > max) throw FormatException('题目字段 $key 不合法');
  return value;
}

List<int> puzzleInts(Object? value, {required int maxLength, required int min, required int max}) {
  if (value is! List || value.length > maxLength) throw const FormatException('题目列表不合法');
  return [
    for (final item in value)
      if (item is int && item >= min && item <= max) item else throw const FormatException('题目列表不合法'),
  ];
}

// 可复现的随机数（xoshiro128**，种子经 splitmix32 展开）：只用 32 位运算，换语言（TS 题库工具、服务器）也能逐位复现。
class PuzzleRandom {
  PuzzleRandom(int seed) {
    var state = seed & _mask;
    int next() {
      state = (state + 0x9E3779B9) & _mask;
      var z = state;
      z = ((z ^ (z >> 16)) * 0x85EBCA6B) & _mask;
      z = ((z ^ (z >> 13)) * 0xC2B2AE35) & _mask;
      return (z ^ (z >> 16)) & _mask;
    }

    _s = [next(), next(), next(), next()];
    if (_s.every((word) => word == 0)) _s[0] = 1;
  }

  static const _mask = 0xFFFFFFFF;
  late final List<int> _s;

  static int _rotl(int value, int bits) => ((value << bits) | (value >> (32 - bits))) & _mask;

  // 下一个 32 位无符号整数。
  int nextUint32() {
    final result = (_rotl((_s[1] * 5) & _mask, 7) * 9) & _mask;
    final shifted = (_s[1] << 9) & _mask;
    _s[2] ^= _s[0];
    _s[3] ^= _s[1];
    _s[1] ^= _s[2];
    _s[0] ^= _s[3];
    _s[2] ^= shifted;
    _s[3] = _rotl(_s[3], 11);
    return result;
  }

  // [0, bound) 里的整数，拒绝采样去掉取模偏差。
  int nextInt(int bound) {
    if (bound <= 0 || bound > _mask) throw ArgumentError.value(bound, 'bound');
    final limit = (_mask + 1) - (_mask + 1) % bound;
    while (true) {
      final value = nextUint32();
      if (value < limit) return value % bound;
    }
  }

  // [0, 1) 的小数（精度 2^-32，出题够用）。
  double nextDouble() => nextUint32() / (_mask + 1);

  bool chance(double probability) => nextDouble() < probability;

  T pick<T>(List<T> items) => items[nextInt(items.length)];

  void shuffle<T>(List<T> items) {
    for (var index = items.length - 1; index > 0; index--) {
      final other = nextInt(index + 1);
      final item = items[index];
      items[index] = items[other];
      items[other] = item;
    }
  }
}
