import 'dart:typed_data';

import 'package:superxd/playground/puzzle_rules.dart';

// 密码破译：密码是几位各不相同的数字，题面给几行线索，每行是一组数字和它对照密码的提示
// （几个数字对且位置也对、几个数字对但位置不对），只靠推理推出唯一的密码（同常见的「破解密码锁」推理题）。
// 不是来回猜的游戏（1A2B 被用户否决过）：题面一次给全，玩家不能拿猜测去换新提示。
// 密码与每行线索的数字都各不相同；候选密码全部枚举（最多 5 位取自 0–9，共 30240 个），求解器筛到第 2 个就停。

// 位数与数字个数的上下限（外部输入的边界）：数字取 0 到 digits − 1，digits 最多 10（0–9）。
const cipherMinLength = 3;
const cipherMaxLength = 5;
const cipherMaxDigits = 10;
// 一道题最多几行线索（外部输入的上限；出题时各档自己的上限更小，见 _plans）。
const cipherMaxRows = 12;

// 一行线索的提示：exact 是数字对且位置也对的个数，misplaced 是数字对但位置不对的个数。
typedef CipherHint = ({int exact, int misplaced});

// 一行线索：一组数字（与密码同样位数、各不相同）和它对照密码的提示。
class CipherRow {
  const CipherRow(this.guess, this.exact, this.misplaced);
  final List<int> guess;
  final int exact, misplaced;
  CipherHint get hint => (exact: exact, misplaced: misplaced);
}

class CipherPuzzle {
  const CipherPuzzle({required this.length, required this.digits, required this.rows});
  // 密码位数与数字个数（数字取 0 到 digits − 1）。
  final int length, digits;
  final List<CipherRow> rows;
}

// 一组数字对照密码的提示（同 Mastermind 的记法）：位置对的先数；剩下的「数字对」按每个数字在两边出现次数的较小值合计，
// 再减去位置对的。所以有重复数字时不会多算：密码 1 2 3 对 1 1 4 是一个位置对、没有位置不对的（第二个 1 没有可配的）。
// 题目里密码与线索都没有重复数字，这条只管外部输入与玩家答案；两边对调算出的提示相同。
CipherHint cipherHint(List<int> code, List<int> guess) {
  var exact = 0, common = 0;
  final counts = <int, int>{};
  for (var position = 0; position < code.length && position < guess.length; position++) {
    if (code[position] == guess[position]) exact++;
  }
  for (final digit in code) {
    counts[digit] = (counts[digit] ?? 0) + 1;
  }
  for (final digit in guess) {
    final left = counts[digit] ?? 0;
    if (left == 0) continue;
    counts[digit] = left - 1;
    common++;
  }
  return (exact: exact, misplaced: common - exact);
}

// 答案是否是一个合规的密码：位数对、每位在数字范围里、各不相同。
bool cipherValidCode(CipherPuzzle puzzle, List<int> code) =>
    code.length == puzzle.length && code.every((digit) => digit >= 0 && digit < puzzle.digits) && code.toSet().length == code.length;

// 和答案对不上的线索行（这组数字对照答案算出的提示与线索写的不同）；对局页判错时标出这些行，不给答案。
List<int> cipherConflicts(CipherPuzzle puzzle, List<int> code) => [
  for (final (index, row) in puzzle.rows.indexed)
    if (cipherHint(code, row.guess) != row.hint) index,
];

int _bits(int value) {
  var count = 0;
  for (var rest = value; rest != 0; rest &= rest - 1) {
    count++;
  }
  return count;
}

// 某个位数与数字个数下的全部候选密码（按字典序）：digitsAt 按候选依次存每位数字，masks 是每个候选用到的数字（第 d 位是 1 表示有 d）。
// 同一组参数只算一次（档位只有四组参数，最大 30240 个候选、几百 KB）。
class _Space {
  _Space(this.length, this.digits) {
    final codes = <int>[];
    final current = <int>[];
    void walk(int used) {
      if (current.length == length) {
        codes.addAll(current);
        return;
      }
      for (var digit = 0; digit < digits; digit++) {
        if (used >> digit & 1 == 1) continue;
        current.add(digit);
        walk(used | 1 << digit);
        current.removeLast();
      }
    }

    walk(0);
    digitsAt = Uint8List.fromList(codes);
    count = codes.length ~/ length;
    masks = Int32List(count);
    for (var code = 0; code < count; code++) {
      for (var position = 0; position < length; position++) {
        masks[code] |= 1 << digitsAt[code * length + position];
      }
    }
  }

  final int length, digits;
  late final Uint8List digitsAt;
  late final int count;
  late final Int32List masks;

  static final _cache = <int, _Space>{};
  static _Space of(int length, int digits) => _cache.putIfAbsent(length * 16 + digits, () => _Space(length, digits));

  List<int> code(int index) => List.unmodifiable(digitsAt.sublist(index * length, (index + 1) * length));

  // 第 code 个候选对照这一行是否成立（提示与线索写的一样）：没有重复数字时「数字对」的个数就是两边数字集合交集的大小。
  bool fit(int code, CipherRow row, int guessMask) {
    var exact = 0;
    for (var position = 0; position < length; position++) {
      if (digitsAt[code * length + position] == row.guess[position]) exact++;
    }
    return exact == row.exact && _bits(masks[code] & guessMask) - exact == row.misplaced;
  }

  static int maskOf(List<int> digits) => digits.fold(0, (mask, digit) => mask | 1 << digit);

  // 全部候选对照这一行是否成立（1 是成立）。
  Uint8List fits(CipherRow row) {
    final guessMask = maskOf(row.guess);
    final result = Uint8List(count);
    for (var code = 0; code < count; code++) {
      if (fit(code, row, guessMask)) result[code] = 1;
    }
    return result;
  }
}

typedef CipherSolveResult = ({int count, List<int>? first});

// 筛出和每一行线索都对得上的候选密码，数到 limit 个就停（出题与解码只关心是不是唯一，默认数到第 2 个）。
CipherSolveResult cipherSolve(CipherPuzzle puzzle, {int limit = 2}) {
  final space = _Space.of(puzzle.length, puzzle.digits);
  final fits = [for (final row in puzzle.rows) space.fits(row)];
  var count = 0;
  int? first;
  for (var code = 0; code < space.count && count < limit; code++) {
    if (fits.every((fit) => fit[code] == 1)) {
      count++;
      first ??= code;
    }
  }
  return (count: count, first: first == null ? null : space.code(first));
}

// 推理过程：模拟人一步步推。人手上记的是一张「数字 × 位置」的表（哪个数字还可能在哪一位）加上「哪些数字一定在密码里」，
// 对局页的记号（排除、确定）就是它的简化。
// - 单行：拿一行线索加上手上已有的结论，看能不能多划掉表里的格、或确定某个数字在密码里（「没有一个对」→ 这几个数字都不在；
//   已知 3 不在、「3 5 7 有两个对但位置都不对」→ 5、7 在密码里，5 不在第二位、7 不在第三位），推到推不动为止。
//   每次有了新结论都顺手做表上的直接推论（某一位只剩一个数字可选、某个数字只剩一位可放）。
// - 联合：单行推不动了，就同时看两行（还不行看三行……），哪组线索合起来能推出新结论就先记下，再回到单行接着推。
// 「推出」= 和这几行线索、手上结论都对得上的候选密码里，某个数字都不在某一位，或某个数字都在。
// direct：一开始什么都不知道时，单凭一行就能推出东西的行数；rounds：单行推的轮数（一轮把各行看一遍，有新结论就再来一轮）；
// depth：整个过程里最多同时看几行（全靠单行推完是 1）；joined：每次联合推理记「联合的行数 − 1」，加起来。
typedef CipherReasoning = ({int direct, int rounds, int depth, int joined});

CipherReasoning cipherReasoning(CipherPuzzle puzzle) {
  final space = _Space.of(puzzle.length, puzzle.digits);
  final fits = [for (final row in puzzle.rows) space.fits(row)];
  return _reason(space, fits);
}

CipherReasoning _reason(_Space space, List<Uint8List> fits) {
  final length = space.length, rows = fits.length;
  final all = (1 << length) - 1;
  // places[d] 的第 p 位是 1 表示数字 d 还可能在第 p 位；present 的第 d 位是 1 表示数字 d 一定在密码里。
  var places = List.filled(space.digits, all), present = 0;
  var known = [for (var code = 0; code < space.count; code++) code];

  bool allowed(int code, List<int> places, int present) {
    if (present & ~space.masks[code] != 0) return false;
    for (var position = 0; position < length; position++) {
      if (places[space.digitsAt[code * length + position]] >> position & 1 == 0) return false;
    }
    return true;
  }

  // 一组候选落到表上：每个数字可能在哪几位、哪些数字都在。
  (List<int>, int) project(Iterable<int> codes) {
    final projected = List.filled(space.digits, 0);
    var always = -1;
    for (final code in codes) {
      for (var position = 0; position < length; position++) {
        projected[space.digitsAt[code * length + position]] |= 1 << position;
      }
      always &= space.masks[code];
    }
    return (projected, always == -1 ? 0 : always);
  }

  bool same(List<int> projected, int always) {
    if (always != present) return false;
    for (var digit = 0; digit < space.digits; digit++) {
      if (projected[digit] != places[digit]) return false;
    }
    return true;
  }

  // 记下一组候选推出的结论；有新结论返回真，并把表上的直接推论做到底。
  bool settle(Iterable<int> codes) {
    var (projected, always) = project(codes);
    if (same(projected, always)) return false;
    while (!same(projected, always)) {
      places = projected;
      present = always;
      known = [for (final code in known) if (allowed(code, places, present)) code];
      (projected, always) = project(known);
    }
    return true;
  }

  final initial = List.filled(space.digits, all);
  var direct = 0;
  for (final fit in fits) {
    final (projected, always) = project([for (var code = 0; code < space.count; code++) if (fit[code] == 1) code]);
    if (always != 0 || [for (var digit = 0; digit < space.digits; digit++) projected[digit] != initial[digit]].contains(true)) direct++;
  }
  var rounds = 0, depth = 1, joined = 0;
  search:
  while (known.length > 1) {
    for (var width = 1; width <= rows; width++) {
      var found = false;
      for (var group = 1; group < 1 << rows; group++) {
        if (_bits(group) != width) continue;
        final members = [for (var row = 0; row < rows; row++) if (group >> row & 1 == 1) fits[row]];
        final selected = <int>[];
        candidates:
        for (final code in known) {
          for (final fit in members) {
            if (fit[code] == 0) continue candidates;
          }
          selected.add(code);
        }
        if (settle(selected)) found = true;
        // 单行：同一轮里后面的行接着用刚推出的结论；联合：推出一次就回到单行。
        if (found && width > 1) break;
      }
      if (!found) continue;
      if (width == 1) {
        rounds++;
      } else {
        joined += width - 1;
        if (width > depth) depth = width;
      }
      continue search;
    }
    // 全部线索合起来也推不出唯一的密码：不是唯一解的题（出题与解码都会拦下，这里只是兜底）。
    break;
  }
  return (direct: direct, rounds: rounds, depth: depth, joined: joined);
}

// 每档的出题方案：位数、数字个数、线索行数的区间与对推理过程的要求（量法见 cipherReasoning）；pool 是出几道合格的候选留推理最深的。
class _Plan {
  const _Plan({required this.length, required this.digits, required this.rows, required this.depth, this.joined = (0, 0), this.pool = 1});
  final int length, digits;
  final (int, int) rows, depth, joined;
  final int pool;
}

class CipherRules extends PuzzleRules<CipherPuzzle, List<int>> {
  const CipherRules();

  // 入门 3 位取自 0–5（候选 120 个，两三行线索）；简单 3 位取自 0–9；这两档与普通（4 位）都只靠单行一路推完。
  // 困难 4 位、专家 5 位，必须有一步要联合两行（最多三行）才推得下去，各出三道合格的候选留联合推理最多的；
  // 联合推理量设上限，免得同档里冒出要把一堆线索放在一起试的题。实测各档行数：入门 2–4、简单 3–6、普通 4–6、困难 4–7、专家 5–7。
  static const _plans = {
    PuzzleTier.entry: _Plan(length: 3, digits: 6, rows: (2, 4), depth: (1, 1)),
    PuzzleTier.easy: _Plan(length: 3, digits: 10, rows: (3, 6), depth: (1, 1)),
    PuzzleTier.normal: _Plan(length: 4, digits: 10, rows: (4, 7), depth: (1, 1)),
    PuzzleTier.hard: _Plan(length: 4, digits: 10, rows: (4, 7), depth: (2, 3), joined: (1, 6), pool: 3),
    PuzzleTier.expert: _Plan(length: 5, digits: 10, rows: (5, 8), depth: (2, 3), joined: (2, 9), pool: 3),
  };

  @override
  PuzzleDraw<CipherPuzzle, List<int>> generate(int seed, PuzzleTier tier) {
    final plan = _plans[tier]!;
    final random = PuzzleRandom(seed);
    final space = _Space.of(plan.length, plan.digits);
    PuzzleDraw<CipherPuzzle, List<int>>? best;
    var bestJoined = -1;
    for (var drawn = 0; drawn < plan.pool;) {
      final candidate = _draw(space, plan, random);
      if (candidate == null) continue;
      drawn++;
      final (draw, reasoning) = candidate;
      if (reasoning.joined > bestJoined) (best, bestJoined) = (draw, reasoning.joined);
    }
    return best!;
  }

  // 一道候选：随机定密码，随机出线索行（各不相同的数字，提示由密码算出；全对的不要，筛不掉候选的不要），加到候选只剩一个；
  // 再按随机顺序试着删掉每一行（删了仍唯一就删），剩下的每行都少不了。行数与推理过程不合这一档的要求返回 null，整道重来。
  static (PuzzleDraw<CipherPuzzle, List<int>>, CipherReasoning)? _draw(_Space space, _Plan plan, PuzzleRandom random) {
    final length = plan.length;
    final secret = space.code(random.nextInt(space.count));
    final rows = <CipherRow>[];
    final fits = <Uint8List>[];
    var survivors = [for (var code = 0; code < space.count; code++) code];
    final pool = [for (var digit = 0; digit < plan.digits; digit++) digit];
    while (survivors.length > 1) {
      if (rows.length >= cipherMaxRows) return null;
      random.shuffle(pool);
      final guess = List<int>.unmodifiable(pool.sublist(0, length));
      final hint = cipherHint(secret, guess);
      if (hint.exact == length) continue;
      final row = CipherRow(guess, hint.exact, hint.misplaced);
      // 先只在剩下的候选里试（剩得少时大多数随机行筛不掉什么），留下的行再对全部候选算一遍。
      final guessMask = _Space.maskOf(guess);
      final narrowed = [for (final code in survivors) if (space.fit(code, row, guessMask)) code];
      if (narrowed.length == survivors.length) continue;
      rows.add(row);
      fits.add(space.fits(row));
      survivors = narrowed;
    }
    final order = [for (var index = 0; index < rows.length; index++) index];
    random.shuffle(order);
    final kept = List.filled(rows.length, true);
    bool unique() {
      var count = 0;
      for (var code = 0; code < space.count && count < 2; code++) {
        var fitsAll = true;
        for (var index = 0; index < rows.length && fitsAll; index++) {
          if (kept[index] && fits[index][code] == 0) fitsAll = false;
        }
        if (fitsAll) count++;
      }
      return count == 1;
    }

    for (final index in order) {
      kept[index] = false;
      if (!unique()) kept[index] = true;
    }
    final keptRows = [for (final (index, row) in rows.indexed) if (kept[index]) row];
    final (minRows, maxRows) = plan.rows;
    if (keptRows.length < minRows || keptRows.length > maxRows) return null;
    final reasoning = _reason(space, [for (final (index, fit) in fits.indexed) if (kept[index]) fit]);
    final ((minDepth, maxDepth), (minJoined, maxJoined)) = (plan.depth, plan.joined);
    if (reasoning.depth < minDepth || reasoning.depth > maxDepth || reasoning.joined < minJoined || reasoning.joined > maxJoined) return null;
    final puzzle = CipherPuzzle(length: length, digits: plan.digits, rows: List.unmodifiable(keptRows));
    return (PuzzleDraw(puzzle, secret), reasoning);
  }

  // 按规则判：答案是合规的密码（位数对、在数字范围里、各不相同），并且和每一行线索的提示都对得上。题目唯一，所以等价于答对，但不和参考解比。
  @override
  bool solved(CipherPuzzle puzzle, List<int> answer) => cipherValidCode(puzzle, answer) && cipherConflicts(puzzle, answer).isEmpty;

  // 难度分口径：先看候选有多少（位数与数字个数）：3 位 0–5 记 1，3 位 0–9 记 3，4 位记 5，5 位记 7；必须联合几行才推得下去的再加 2；
  // 单行要来回推三轮以上（前面推出的结论要拿回去再用一遍）的再加 1。按各档的方案出题，同档最多差 1 分、下一档最低高过上一档最高：
  // 入门 1–2、简单 3–4、普通 5–6、困难 7–8、专家 9–10。不是唯一解的题面不会出、也解码不进来，按 10 分算。
  @override
  int difficulty(CipherPuzzle puzzle) {
    if (cipherSolve(puzzle).count != 1) return 10;
    final reasoning = cipherReasoning(puzzle);
    final base = 2 * (puzzle.length - 3) + (puzzle.digits > 6 ? 3 : 1) + (reasoning.depth > 1 ? 2 : 0);
    return (base + (reasoning.rounds > 2 ? 1 : 0)).clamp(1, 10);
  }

  // 题面编成 {'length': 位数, 'digits': 数字个数, 'rows': [[[数字…], 位置对的个数, 位置不对的个数], …]}。
  @override
  Object encodePuzzle(CipherPuzzle puzzle) => {
    'length': puzzle.length,
    'digits': puzzle.digits,
    'rows': [
      for (final row in puzzle.rows) [row.guess, row.exact, row.misplaced],
    ],
  };

  @override
  CipherPuzzle decodePuzzle(Object? json) {
    final length = puzzleInt(json, 'length', min: cipherMinLength, max: cipherMaxLength);
    final digits = puzzleInt(json, 'digits', min: length + 1, max: cipherMaxDigits);
    final raw = (json as Map)['rows'];
    if (raw is! List || raw.isEmpty || raw.length > cipherMaxRows) throw const FormatException('线索行数不合法');
    final rows = [
      for (final item in raw)
        if (item is List && item.length == 3) _decodeRow(item, length, digits) else throw const FormatException('线索不合法'),
    ];
    final puzzle = CipherPuzzle(length: length, digits: digits, rows: List.unmodifiable(rows));
    // 没有一个密码对得上、或不止一个对得上的不是题（题库里不该有）。
    if (cipherSolve(puzzle).count != 1) throw const FormatException('题目不是唯一解');
    return puzzle;
  }

  static CipherRow _decodeRow(List<Object?> item, int length, int digits) {
    final guess = puzzleInts(item[0], maxLength: length, min: 0, max: digits - 1);
    if (guess.length != length || guess.toSet().length != length) throw const FormatException('线索的数字不合法');
    final (exact, misplaced) = (item[1], item[2]);
    if (exact is! int || misplaced is! int || exact < 0 || misplaced < 0 || exact + misplaced > length) throw const FormatException('线索的提示不合法');
    return CipherRow(List.unmodifiable(guess), exact, misplaced);
  }

  // 答案是密码的数字列表。
  @override
  Object encodeAnswer(List<int> answer) => answer;

  @override
  List<int> decodeAnswer(Object? json) {
    final answer = puzzleInts(json, maxLength: cipherMaxLength, min: 0, max: cipherMaxDigits - 1);
    if (answer.length < cipherMinLength) throw const FormatException('答案不合法');
    return List.unmodifiable(answer);
  }
}
