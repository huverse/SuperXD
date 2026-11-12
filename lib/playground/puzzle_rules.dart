// 谜题规则的公共契约（纯 Dart，不依赖 Flutter）：自由模式在本机出题与判定，挑战模式的题库由 tool 下的工具用同一份规则离线生成，
// 服务器按同一份编码核对答案（TS 核对器与这里共用测试向量，挑战阶段再加）。所以出题只许用 PuzzleRandom，不用 dart:math 的 Random。
// [人工决策-2026-11-12 21:00:20] 游乐场的长期架构（用户提出、选项选定，见 lib/playground/CLAUDE.md）：每个游戏 = 规则 + 页面，
// 规则按种子出题、给出参考解、判定答案、给难度分并能编解码，挑战模式（服务器逐关核对、按上一关的结果出下一关）直接复用，不另写一套。

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

  // 难度分 1–10：按这道题求解要走的步数、推理深度算，挑战模式计分用（规则见 lib/playground/CLAUDE.md）。
  int difficulty(P puzzle);

  Object encodePuzzle(P puzzle);
  P decodePuzzle(Object? json);
  Object encodeAnswer(A answer);
  A decodeAnswer(Object? json);
}

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
