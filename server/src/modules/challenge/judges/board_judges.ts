import { answerBits, bitString, field, Judge, JudgeFormatError, puzzleInt, puzzleInts } from 'src/modules/challenge/judges/judge_input';
import { PuzzleRandom } from 'src/modules/challenge/judges/puzzle_random';

// 24 点、扫雷、记忆闪光、数回、天平称球（各自对应 lib/playground/puzzle 下同名的 _rules.dart）。

// ---------- 24 点 twentyfour ----------
// 有理数精确算：分母恒为正、约到最简；每步结果的分子分母绝对值不超过 twentyFourLimit（所以中间乘积不超过 10^12，双精度精确）。
type Fraction = { top: number; bottom: number };
type TwentyFourStep = { first: number; op: number; second: number };
type TwentyFourPuzzle = { numbers: number[]; ops: Set<number> };
const twentyFourLimit = 1000000, twentyFourMaxExponent = 10, twentyFourMaxSteps = 19, twentyFourCards = 4, twentyFourOps = 6, twentyFourRoot = 5;

const gcd = (left: number, right: number) => {
  let [a, b] = [Math.abs(left), Math.abs(right)];
  while (b !== 0) [a, b] = [b, a % b];
  return a;
};

const fraction = (top: number, bottom: number): Fraction => {
  const divisor = gcd(top, bottom) * (bottom < 0 ? -1 : 1);
  return { top: top / divisor + 0, bottom: bottom / divisor };
};

const squareRoot = (value: number) => {
  const root = Math.round(Math.sqrt(value));
  return root * root === value ? root : null;
};

const power = (base: Fraction, exponent: Fraction): Fraction | null => {
  if (exponent.top % exponent.bottom !== 0) return null;
  const times = exponent.top / exponent.bottom;
  if (Math.abs(times) > twentyFourMaxExponent || (base.top === 0 && times <= 0)) return null;
  let [up, down] = [base.top, base.bottom];
  if (times < 0) [up, down] = [down * Math.sign(up), Math.abs(up)];
  let [top, bottom] = [1, 1];
  for (let round = 0; round < Math.abs(times); round++) {
    top *= up;
    bottom *= down;
    if (Math.abs(top) > twentyFourLimit || bottom > twentyFourLimit) return null;
  }
  return fraction(top, bottom);
};

// 开方：大于 0、不是 1，约分后分子分母都是完全平方数才开得尽。
const root = (value: Fraction): Fraction | null => {
  if (value.top <= 0 || value.top === value.bottom) return null;
  const [top, bottom] = [squareRoot(value.top), squareRoot(value.bottom)];
  return top === null || bottom === null ? null : fraction(top, bottom);
};

const apply = (op: number, first: Fraction, second: Fraction): Fraction | null => {
  let value: Fraction | null;
  switch (op) {
    case 0:
      value = fraction(first.top * second.bottom + second.top * first.bottom, first.bottom * second.bottom);
      break;
    case 1:
      value = fraction(first.top * second.bottom - second.top * first.bottom, first.bottom * second.bottom);
      break;
    case 2:
      value = fraction(first.top * second.top, first.bottom * second.bottom);
      break;
    case 3:
      value = second.top === 0 ? null : fraction(first.top * second.bottom, first.bottom * second.top);
      break;
    default:
      value = power(first, second);
  }
  return value !== null && Math.abs(value.top) <= twentyFourLimit && value.bottom <= twentyFourLimit ? value : null;
};

export const twentyFourJudge: Judge<TwentyFourPuzzle, TwentyFourStep[]> = {
  decodePuzzle: (json) => {
    const numbers = puzzleInts(field(json, 'numbers'), twentyFourCards, 1, 13);
    if (numbers.length !== twentyFourCards) throw new JudgeFormatError('题目要四个数');
    return { numbers, ops: new Set(puzzleInts(field(json, 'ops'), twentyFourOps, 0, twentyFourOps - 1)) };
  },
  decodeAnswer: (json) => {
    if (!Array.isArray(json) || json.length > twentyFourMaxSteps) throw new JudgeFormatError('答案不合法');
    return json.map((raw) => {
      const parts = puzzleInts(raw, 3, 0, twentyFourOps - 1);
      if (parts.length !== 3 || parts[0] >= twentyFourCards || parts[2] >= twentyFourCards) throw new JudgeFormatError('答案的一步不合法');
      return { first: parts[0], op: parts[1], second: parts[2] };
    });
  },
  // 按规则重放：每步合规、运算是题面允许的，最后只剩一张而且是 24。二元结果进第二张的位置，开方两个位置相同、留在原位。
  solved: (puzzle, answer) => {
    if (answer.length > twentyFourMaxSteps) return false;
    const slots: (Fraction | null)[] = puzzle.numbers.map((number) => ({ top: number, bottom: 1 }));
    for (const step of answer) {
      if (!puzzle.ops.has(step.op)) return false;
      const [left, right] = [slots[step.first], slots[step.second]];
      const unary = step.op === twentyFourRoot;
      if (left === null || right === null || (step.first === step.second) !== unary) return false;
      const value = unary ? root(left) : apply(step.op, left, right);
      if (value === null) return false;
      slots[step.first] = null;
      slots[step.second] = value;
    }
    const left = slots.filter((slot) => slot !== null);
    return left.length === 1 && left[0].top === 24 && left[0].bottom === 1;
  },
};

// ---------- 扫雷 mines ----------
type MinesPuzzle = { width: number; height: number; mines: boolean[]; start: number };
const minesMinSide = 5, minesMaxSide = 24;

const around = (width: number, height: number, cell: number) => {
  const row = Math.trunc(cell / width), column = cell % width;
  const cells: number[] = [];
  for (let dy = -1; dy <= 1; dy++) {
    for (let dx = -1; dx <= 1; dx++) {
      if ((dy !== 0 || dx !== 0) && row + dy >= 0 && row + dy < height && column + dx >= 0 && column + dx < width) cells.push((row + dy) * width + column + dx);
    }
  }
  return cells;
};

export const minesJudge: Judge<MinesPuzzle, number[]> = {
  decodePuzzle: (json) => {
    const width = puzzleInt(json, 'width', minesMinSide, minesMaxSide), height = puzzleInt(json, 'height', minesMinSide, minesMaxSide);
    return { width, height, mines: bitString(field(json, 'mines'), width * height), start: puzzleInt(json, 'start', 0, width * height - 1) };
  },
  decodeAnswer: (json) => puzzleInts(json, minesMaxSide * minesMaxSide, 0, minesMaxSide * minesMaxSide - 1),
  // 按序重放：点未翻的格翻开（0 格连开），点已翻开的数字把周围不是雷的都翻开；越界、翻到雷、翻不出新格都不合法；最后不是雷的格都翻开了。
  solved: (puzzle, answer) => {
    const { width, height, mines } = puzzle;
    if (answer.length > mines.length) return false;
    const counts = mines.map((_, cell) => around(width, height, cell).filter((other) => mines[other]).length);
    const open = mines.map(() => false);
    const flood = (cell: number) => {
      if (open[cell]) return 0;
      open[cell] = true;
      const queue = [cell];
      for (let index = 0; index < queue.length; index++) {
        if (counts[queue[index]] !== 0) continue;
        for (const other of around(width, height, queue[index])) {
          if (open[other]) continue;
          open[other] = true;
          queue.push(other);
        }
      }
      return queue.length;
    };
    flood(puzzle.start);
    for (const cell of answer) {
      if (cell >= mines.length) return false;
      if (!open[cell]) {
        if (mines[cell]) return false;
        flood(cell);
        continue;
      }
      let opened = 0;
      for (const other of around(width, height, cell)) if (!open[other] && !mines[other]) opened += flood(other);
      if (opened === 0) return false;
    }
    return open.every((isOpen, cell) => isOpen || mines[cell]);
  },
};

// ---------- 记忆闪光 flash ----------
type FlashPuzzle = { side: number; rounds: number[][][] };
const flashMinSide = 3, flashMaxSide = 6, flashMaxRounds = 10, flashMaxPatterns = 8, flashMaxAttempts = 400;

// 按规则重放答案，返回点错的次数；不合规或没走完全部轮次返回 null（同 Dart 的 flashMistakes）。
export const flashMistakes = (puzzle: FlashPuzzle, attempts: number[][]): number | null => {
  if (attempts.length > flashMaxAttempts) return null;
  const count = puzzle.side * puzzle.side;
  let round = 0, tries = 0, mistakes = 0;
  for (const taps of attempts) {
    if (round === puzzle.rounds.length) return null;
    const patterns = puzzle.rounds[round];
    const pattern = patterns[tries % patterns.length];
    const hits = new Set<number>();
    let last: 'hit' | 'cleared' | 'missed' | null = null;
    for (const cell of taps) {
      if (last === 'cleared' || last === 'missed' || cell >= count || hits.has(cell)) return null;
      last = !pattern.includes(cell) ? 'missed' : hits.size + 1 === pattern.length ? 'cleared' : 'hit';
      hits.add(cell);
    }
    if (last === 'cleared') {
      round++;
      tries = 0;
    } else if (last === 'missed') {
      mistakes++;
      tries++;
    } else {
      return null;
    }
  }
  return round === puzzle.rounds.length ? mistakes : null;
};

export const flashJudge: Judge<FlashPuzzle, number[][]> = {
  decodePuzzle: (json) => {
    const side = puzzleInt(json, 'side', flashMinSide, flashMaxSide);
    const rounds = field(json, 'rounds');
    if (!Array.isArray(rounds) || rounds.length === 0 || rounds.length > flashMaxRounds) throw new JudgeFormatError('轮数不合法');
    return {
      side,
      rounds: rounds.map((patterns) => {
        if (!Array.isArray(patterns) || patterns.length === 0 || patterns.length > flashMaxPatterns) throw new JudgeFormatError('一轮的图案不合法');
        return patterns.map((pattern) => puzzleInts(pattern, Math.trunc((side * side) / 2), 0, side * side - 1));
      }),
    };
  },
  decodeAnswer: (json) => {
    if (!Array.isArray(json) || json.length > flashMaxAttempts) throw new JudgeFormatError('答案不合法');
    return json.map((taps) => puzzleInts(taps, flashMaxSide * flashMaxSide, 0, flashMaxSide * flashMaxSide - 1));
  },
  solved: (puzzle, answer) => flashMistakes(puzzle, answer) !== null,
};

// ---------- 数回 loop ----------
// 边的下标同 Dart 的 LoopGrid：先横边（第 r 条横线第 c 段是 r × 宽 + c），后竖边（横边总数 + r ×（宽 + 1）+ c）；点的下标是 r ×（宽 + 1）+ c。
type LoopPuzzle = { width: number; height: number; clues: number[] };
const loopMinSide = 2, loopMaxSide = 12;
const loopEdgeCount = (width: number, height: number) => (height + 1) * width + height * (width + 1);

export const loopJudge: Judge<LoopPuzzle, boolean[]> = {
  decodePuzzle: (json) => {
    const width = puzzleInt(json, 'width', loopMinSide, loopMaxSide), height = puzzleInt(json, 'height', loopMinSide, loopMaxSide);
    const clues = puzzleInts(field(json, 'clues'), loopMaxSide * loopMaxSide, -1, 3);
    if (clues.length !== width * height) throw new JudgeFormatError('数字的格数不对');
    return { width, height, clues };
  },
  decodeAnswer: (json) => answerBits(json, loopEdgeCount(loopMaxSide, loopMaxSide)),
  // 恰好一条闭合的回路（每个点连 0 或 2 条线，从一条线出发走一圈能走遍全部的线），并且每个数字格四周的线数对得上。
  solved: (puzzle, answer) => {
    const { width, height } = puzzle;
    const stride = width + 1, horizontals = (height + 1) * width;
    if (answer.length !== loopEdgeCount(width, height)) return false;
    for (let row = 0; row < height; row++) {
      for (let column = 0; column < width; column++) {
        const clue = puzzle.clues[row * width + column];
        if (clue < 0) continue;
        const edges = [row * width + column, horizontals + row * stride + column + 1, (row + 1) * width + column, horizontals + row * stride + column];
        if (edges.filter((edge) => answer[edge]).length !== clue) return false;
      }
    }
    const ends = (edge: number): [number, number] => {
      if (edge < horizontals) {
        const left = Math.trunc(edge / width) * stride + (edge % width);
        return [left, left + 1];
      }
      const top = edge - horizontals;
      return [top, top + stride];
    };
    const vertices = stride * (height + 1);
    const degree = new Array<number>(vertices).fill(0);
    const touching: number[][] = Array.from({ length: vertices }, () => []);
    let total = 0, start = -1;
    answer.forEach((line, edge) => {
      if (!line) return;
      total++;
      start = edge;
      for (const vertex of ends(edge)) {
        degree[vertex]++;
        touching[vertex].push(edge);
      }
    });
    if (total === 0 || degree.some((count) => count !== 0 && count !== 2)) return false;
    const [home, first] = ends(start);
    let vertex = first, previous = start, walked = 1;
    while (vertex !== home) {
      const next = touching[vertex].find((edge) => edge !== previous)!;
      const [from, to] = ends(next);
      vertex = from === vertex ? to : from;
      previous = next;
      walked++;
    }
    return walked === total;
  },
};

// ---------- 天平称球 balance ----------
// 秤不预定假球，按对手规则答（挑剩下的候选还要称最多次的结果，一样多按种子挑），同 Dart 的 balanceRespond。
type BalancePuzzle = { balls: number; weighings: number; knownHeavy: boolean; direction: boolean; seed: number };
type BalanceAnswer = { weighings: { left: number[]; right: number[] }[]; ball: number; heavy: boolean | null };
type Suspects = { heavy: number; light: number };
// 按类计数的局面：两种都可能、只可能偏重、只可能偏轻、已知是好球。
type CountState = [number, number, number, number];
const balanceMinBalls = 3, balanceMaxBalls = 13, balanceMaxWeighings = 3;

const bitCount = (mask: number) => {
  let count = 0;
  for (let rest = mask; rest !== 0; rest &= rest - 1) count++;
  return count;
};

const split = (suspects: Suspects, left: number, right: number): Suspects[] => [
  { heavy: suspects.heavy & left, light: suspects.light & right },
  { heavy: suspects.heavy & right, light: suspects.light & left },
  { heavy: suspects.heavy & ~(left | right), light: suspects.light & ~(left | right) },
];

const stateOf = (puzzle: BalancePuzzle, suspects: Suspects): CountState => {
  const both = bitCount(suspects.heavy & suspects.light);
  const heavy = bitCount(suspects.heavy & ~suspects.light), light = bitCount(suspects.light & ~suspects.heavy);
  return [both, heavy, light, puzzle.balls - both - heavy - light];
};

const measure = ([u, h, l]: CountState, direction: boolean) => (direction ? 2 * u + h + l : u + h + l);
const solvableMemo = new Map<string, boolean>();

const solvable = (state: CountState, rounds: number, direction: boolean): boolean => {
  if (measure(state, direction) <= 1) return true;
  if (rounds === 0 || measure(state, direction) > 3 ** rounds) return false;
  const key = `${state.join(',')}|${rounds}|${direction}`;
  const memo = solvableMemo.get(key);
  if (memo !== undefined) return memo;
  const [u, h, l, g] = state;
  const total = u + h + l + g;
  let found = false;
  // 同 Dart 的 _moves 加 _winning：左右两盘各放几个每类的球，好球补齐两边；有一种放法三种结果都还解得开就行（结果与放法顺序无关）。
  search: for (let uL = 0; uL <= u; uL++) {
    for (let uR = 0; uR <= u - uL; uR++) {
      for (let hL = 0; hL <= h; hL++) {
        for (let hR = 0; hR <= h - hL; hR++) {
          for (let lL = 0; lL <= l; lL++) {
            for (let lR = 0; lR <= l - lL; lR++) {
              const left = uL + hL + lL, right = uR + hR + lR;
              if (left + right === 0) continue;
              if (Math.max(0, right - left) + Math.max(0, left - right) > g) continue;
              const outcomes: CountState[] = [
                [0, uL + hL, uR + lR, total - (uL + hL) - (uR + lR)],
                [0, uR + hR, uL + lL, total - (uR + hR) - (uL + lL)],
                [u - uL - uR, h - hL - hR, l - lL - lR, total - (u - uL - uR) - (h - hL - hR) - (l - lL - lR)],
              ];
              if (outcomes.every((next) => next[0] + next[1] + next[2] === 0 || solvable(next, rounds - 1, direction))) {
                found = true;
                break search;
              }
            }
          }
        }
      }
    }
  }
  solvableMemo.set(key, found);
  return found;
};

const needed = (state: CountState, remaining: number, direction: boolean) => {
  for (let rounds = 0; rounds <= remaining; rounds++) if (solvable(state, rounds, direction)) return rounds;
  return remaining + 1;
};

const respond = (puzzle: BalancePuzzle, suspects: Suspects, left: number, right: number, index: number) => {
  const remaining = puzzle.weighings - index - 1;
  const keys = split(suspects, left, right).map((next) => ((next.heavy | next.light) === 0 ? -1 : needed(stateOf(puzzle, next), remaining, puzzle.direction)));
  const top = Math.max(...keys);
  const tied = keys.flatMap((key, tilt) => (key === top ? [tilt] : []));
  if (tied.length === 1) return tied[0];
  return tied[new PuzzleRandom((puzzle.seed ^ ((index + 1) * 0x9e3779b9)) >>> 0).nextInt(tied.length)];
};

export const balanceJudge: Judge<BalancePuzzle, BalanceAnswer> = {
  decodePuzzle: (json) => {
    const knownHeavy = field(json, 'knownHeavy'), direction = field(json, 'direction');
    if (typeof knownHeavy !== 'boolean' || typeof direction !== 'boolean') throw new JudgeFormatError('题目字段不合法');
    return { balls: puzzleInt(json, 'balls', balanceMinBalls, balanceMaxBalls), weighings: puzzleInt(json, 'weighings', 1, balanceMaxWeighings), knownHeavy, direction, seed: puzzleInt(json, 'seed', 0, 0xffffffff) };
  },
  decodeAnswer: (json) => {
    const raw = field(json, 'weighings');
    if (!Array.isArray(raw) || raw.length > balanceMaxWeighings) throw new JudgeFormatError('答案不合法');
    const weighings = raw.map((item) => {
      if (!Array.isArray(item) || item.length !== 2) throw new JudgeFormatError('答案不合法');
      const left = puzzleInts(item[0], balanceMaxBalls, 0, balanceMaxBalls - 1), right = puzzleInts(item[1], balanceMaxBalls, 0, balanceMaxBalls - 1);
      if (new Set([...left, ...right]).size !== left.length + right.length) throw new JudgeFormatError('答案不合法');
      return { left, right };
    });
    const ball = puzzleInt(json, 'ball', 0, balanceMaxBalls - 1);
    const heavy = field(json, 'heavy');
    if (heavy !== undefined && heavy !== null && typeof heavy !== 'boolean') throw new JudgeFormatError('答案不合法');
    return { weighings, ball, heavy: typeof heavy === 'boolean' ? heavy : null };
  },
  // 重放秤的回答（次数、两边球数都要合规），最后剩下的候选恰好是指认的那个（要说轻重的还要轻重对）才算。
  solved: (puzzle, answer) => {
    if ((answer.heavy !== null) !== puzzle.direction || answer.weighings.length > puzzle.weighings) return false;
    let suspects: Suspects = { heavy: (1 << puzzle.balls) - 1, light: puzzle.knownHeavy ? 0 : (1 << puzzle.balls) - 1 };
    for (const [index, weighing] of answer.weighings.entries()) {
      if ([...weighing.left, ...weighing.right].some((ball) => ball >= puzzle.balls)) return false;
      if (weighing.left.length === 0 || weighing.right.length === 0 || weighing.left.length !== weighing.right.length) return false;
      const left = weighing.left.reduce((mask, ball) => mask | (1 << ball), 0), right = weighing.right.reduce((mask, ball) => mask | (1 << ball), 0);
      suspects = split(suspects, left, right)[respond(puzzle, suspects, left, right, index)];
    }
    if (answer.ball >= puzzle.balls) return false;
    const bit = 1 << answer.ball;
    const pool = answer.heavy === null ? suspects.heavy | suspects.light : answer.heavy ? suspects.heavy : suspects.light;
    if ((pool & bit) === 0) return false;
    return answer.heavy === null ? (suspects.heavy | suspects.light) === bit : pool === bit && (answer.heavy ? suspects.light : suspects.heavy) === 0;
  },
};
