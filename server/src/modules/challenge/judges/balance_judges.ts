import { field, Judge, JudgeFormatError, puzzleInt, puzzleInts } from 'src/modules/challenge/judges/judge_input';
import { PuzzleRandom } from 'src/modules/challenge/judges/puzzle_random';

// 天平称球第 2 版题面（同客户端 lib/playground/puzzle/balance/balance_rules.dart，puzzleVersion 2）：档内随机题型，
// 偏哪边（已知偏重、已知偏轻、不知道）、标准球、两个一样重的假球、可能根本没有假球（答「都是真的」是空列表）、最多称 4 次。
// 第 1 版的判定留在 board_judges.ts 给旧客户端。
// 秤不预定假球，按对手规则答：三种结果里挑剩下的候选还要称最多次的，一样多按种子挑（同 Dart 的 balanceRespond）。
type Weight = 'heavy' | 'light' | 'unknown';
type BalancePuzzle = { balls: number; standards: number; fakes: number; weight: Weight; direction: boolean; maybeNone: boolean; weighings: number; seed: number };
type BalanceAnswer = { weighings: { left: number[]; right: number[] }[]; balls: number[]; heavy: boolean | null };
// 一个假球时 heavy、light 是可能偏重、偏轻的球的位集，none 是还可能都是真的；两个假球时 pairs 是还可能的球对的位集（球对顺序同 Dart 的 balancePairs）。
type Suspects = { heavy: number; light: number; pairs: number; none: boolean };
// 一个假球按类计数的局面：两种都可能、只可能偏重、只可能偏轻、已知是好球（含标准球）、还可能都是真的（1 或 0）。
type CountState = [number, number, number, number, number];
const minBalls = 3, maxBalls = 16, maxStandards = 1, maxTotal = 16, maxPairBalls = 8, maxWeighings = 4;
const weights: readonly Weight[] = ['heavy', 'light', 'unknown'];

const bitCount = (mask: number) => {
  let count = 0;
  for (let rest = mask; rest !== 0; rest &= rest - 1) count++;
  return count;
};

const members = (mask: number) => {
  const list: number[] = [];
  for (let index = 0; mask >> index !== 0; index++) if ((mask & (1 << index)) !== 0) list.push(index);
  return list;
};

const maskOf = (balls: Iterable<number>) => {
  let mask = 0;
  for (const ball of balls) mask |= 1 << ball;
  return mask;
};

const pairLists = new Map<number, [number, number][]>();
const pairsOf = (balls: number) => {
  let list = pairLists.get(balls);
  if (list === undefined) {
    list = [];
    for (let first = 0; first < balls; first++) for (let second = first + 1; second < balls; second++) list.push([first, second]);
    pairLists.set(balls, list);
  }
  return list;
};

const pairIndex = (balls: number, first: number, second: number) => (first * (2 * balls - first - 1)) / 2 + second - first - 1;

const start = (puzzle: BalancePuzzle): Suspects => {
  if (puzzle.fakes === 2) return { heavy: 0, light: 0, pairs: (1 << pairsOf(puzzle.balls).length) - 1, none: false };
  const everyone = (1 << puzzle.balls) - 1;
  return { heavy: puzzle.weight === 'light' ? 0 : everyone, light: puzzle.weight === 'heavy' ? 0 : everyone, pairs: 0, none: puzzle.maybeNone };
};

// 球对按「多的一边」分三份：左边多、右边多、一样多。
const pairSplit = (balls: number, mask: number, left: number, right: number) => {
  const parts = [0, 0, 0];
  for (const [index, [first, second]] of pairsOf(balls).entries()) {
    if ((mask & (1 << index)) === 0) continue;
    const onLeft = ((left >> first) & 1) + ((left >> second) & 1), onRight = ((right >> first) & 1) + ((right >> second) & 1);
    parts[onLeft > onRight ? 0 : onLeft < onRight ? 1 : 2] |= 1 << index;
  }
  return parts;
};

// 三种结果各剩下哪些候选（左边重、右边重、平衡）：同 Dart 的 balanceSplit。
const split = (puzzle: BalancePuzzle, suspects: Suspects, left: number, right: number): Suspects[] => {
  if (puzzle.fakes !== 2) {
    return [
      { heavy: suspects.heavy & left, light: suspects.light & right, pairs: 0, none: false },
      { heavy: suspects.heavy & right, light: suspects.light & left, pairs: 0, none: false },
      { heavy: suspects.heavy & ~(left | right), light: suspects.light & ~(left | right), pairs: 0, none: suspects.none },
    ];
  }
  const parts = pairSplit(puzzle.balls, suspects.pairs, left, right);
  const [down, up] = puzzle.weight === 'light' ? [parts[1], parts[0]] : [parts[0], parts[1]];
  return [down, up, parts[2]].map((pairs) => ({ heavy: 0, light: 0, pairs, none: false }));
};

// ---------- 一个假球：按类计数的极小极大（同 Dart 的 _moves、_winning） ----------
const stateOf = (puzzle: BalancePuzzle, suspects: Suspects): CountState => {
  const both = bitCount(suspects.heavy & suspects.light);
  const heavy = bitCount(suspects.heavy & ~suspects.light), light = bitCount(suspects.light & ~suspects.heavy);
  return [both, heavy, light, puzzle.balls + puzzle.standards - both - heavy - light, suspects.none ? 1 : 0];
};

const measure = ([u, h, l, , z]: CountState, direction: boolean) => (direction ? 2 * u + h + l : u + h + l) + z;
const solvableMemo = new Map<string, boolean>();

const solvable = (state: CountState, rounds: number, direction: boolean): boolean => {
  if (measure(state, direction) <= 1) return true;
  if (rounds === 0 || measure(state, direction) > 3 ** rounds) return false;
  const key = `${state.join(',')}|${rounds}|${direction}`;
  const memo = solvableMemo.get(key);
  if (memo !== undefined) return memo;
  const [u, h, l, g, z] = state;
  const total = u + h + l + g;
  let found = false;
  // 左右两盘各放几个每类的球，好球补齐两边；有一种放法三种结果都还解得开就行（结果与放法顺序无关）。
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
                [0, uL + hL, uR + lR, total - (uL + hL) - (uR + lR), 0],
                [0, uR + hR, uL + lL, total - (uR + hR) - (uL + lL), 0],
                [u - uL - uR, h - hL - hR, l - lL - lR, total - (u - uL - uR) - (h - hL - hR) - (l - lL - lR), z],
              ];
              if (outcomes.every((next) => next[0] + next[1] + next[2] + next[4] === 0 || solvable(next, rounds - 1, direction))) {
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

// ---------- 两个假球：按球对位集的极小极大（同 Dart 的 _pairMoves、_pairWinning） ----------
// 对换两个球后位集不变的球归一类，称法只看每类各放几个；确定是真的球只补在少的一边，镜像只留一种。偏轻只是左右结果互换，按偏重算。
const pairSwap = (balls: number, mask: number, first: number, second: number) => {
  const image = (ball: number) => (ball === first ? second : ball === second ? first : ball);
  let swapped = 0;
  for (const [index, [one, other]] of pairsOf(balls).entries()) {
    if ((mask & (1 << index)) === 0) continue;
    swapped |= 1 << pairIndex(balls, Math.min(image(one), image(other)), Math.max(image(one), image(other)));
  }
  return swapped;
};

const pairMoves = (balls: number, mask: number) => {
  let involved = 0;
  for (const [index, [first, second]] of pairsOf(balls).entries()) if ((mask & (1 << index)) !== 0) involved |= (1 << first) | (1 << second);
  const classes: number[][] = [];
  for (const ball of members(involved)) {
    const home = classes.find((group) => pairSwap(balls, mask, group[0], ball) === mask);
    if (home === undefined) classes.push([ball]);
    else home.push(ball);
  }
  const good: number[] = [];
  for (let ball = 0; ball < balls; ball++) if ((involved & (1 << ball)) === 0) good.push(ball);
  const moves: { left: number; right: number }[] = [];
  const lefts: number[] = [], rights: number[] = [];
  const place = (depth: number) => {
    if (depth < classes.length) {
      for (let onLeft = 0; onLeft <= classes[depth].length; onLeft++) {
        for (let onRight = 0; onLeft + onRight <= classes[depth].length; onRight++) {
          lefts.push(onLeft);
          rights.push(onRight);
          place(depth + 1);
          lefts.pop();
          rights.pop();
        }
      }
      return;
    }
    const sizeLeft = lefts.reduce((sum, count) => sum + count, 0), sizeRight = rights.reduce((sum, count) => sum + count, 0);
    if (sizeLeft + sizeRight === 0) return;
    const goodLeft = Math.max(0, sizeRight - sizeLeft), goodRight = Math.max(0, sizeLeft - sizeRight);
    if (goodLeft + goodRight > good.length) return;
    const mirrored = [...lefts.map((count, index) => count - rights[index]), goodLeft - goodRight].find((difference) => difference !== 0) ?? 0;
    if (mirrored < 0) return;
    let left = 0, right = 0;
    for (const [index, group] of classes.entries()) {
      left |= maskOf(group.slice(0, lefts[index]));
      right |= maskOf(group.slice(lefts[index], lefts[index] + rights[index]));
    }
    left |= maskOf(good.slice(0, goodLeft));
    right |= maskOf(good.slice(goodLeft, goodLeft + goodRight));
    moves.push({ left, right });
  };
  place(0);
  return moves;
};

const pairMemo = new Map<string, boolean>();

const pairSolvable = (balls: number, mask: number, rounds: number): boolean => {
  const count = bitCount(mask);
  if (count <= 1) return true;
  if (rounds === 0 || count > 3 ** rounds) return false;
  const key = `${balls}|${mask}|${rounds}`;
  const memo = pairMemo.get(key);
  if (memo !== undefined) return memo;
  const found = pairMoves(balls, mask).some((move) => pairSplit(balls, mask, move.left, move.right).every((next) => next === 0 || pairSolvable(balls, next, rounds - 1)));
  pairMemo.set(key, found);
  return found;
};

const solvableFrom = (puzzle: BalancePuzzle, suspects: Suspects, rounds: number) =>
  puzzle.fakes === 2 ? pairSolvable(puzzle.balls, suspects.pairs, rounds) : solvable(stateOf(puzzle, suspects), rounds, puzzle.direction);

const needed = (puzzle: BalancePuzzle, suspects: Suspects, remaining: number) => {
  for (let rounds = 0; rounds <= remaining; rounds++) if (solvableFrom(puzzle, suspects, rounds)) return rounds;
  return remaining + 1;
};

const respond = (puzzle: BalancePuzzle, suspects: Suspects, left: number, right: number, index: number) => {
  const remaining = puzzle.weighings - index - 1;
  const keys = split(puzzle, suspects, left, right).map((next) => ((next.heavy | next.light | next.pairs) === 0 && !next.none ? -1 : needed(puzzle, next, remaining)));
  const top = Math.max(...keys);
  const tied = keys.flatMap((key, tilt) => (key === top ? [tilt] : []));
  if (tied.length === 1) return tied[0];
  return tied[new PuzzleRandom((puzzle.seed ^ ((index + 1) * 0x9e3779b9)) >>> 0).nextInt(tied.length)];
};

export const balanceJudgeV2: Judge<BalancePuzzle, BalanceAnswer> = {
  // 同 Dart 的 decodePuzzle 的结构校验（题面来自自己的题库，不重复做可解性检查）。
  decodePuzzle: (json) => {
    const balls = puzzleInt(json, 'balls', minBalls, maxBalls), standards = puzzleInt(json, 'standards', 0, maxStandards);
    const fakes = puzzleInt(json, 'fakes', 1, 2), weighings = puzzleInt(json, 'weighings', 1, maxWeighings), seed = puzzleInt(json, 'seed', 0, 0xffffffff);
    const weight = weights.find((name) => name === field(json, 'weight')), direction = field(json, 'direction'), maybeNone = field(json, 'maybeNone');
    if (weight === undefined || typeof direction !== 'boolean' || typeof maybeNone !== 'boolean' || balls + standards > maxTotal) throw new JudgeFormatError('题目字段不合法');
    if (direction && weight !== 'unknown') throw new JudgeFormatError('题目字段不合法');
    if (fakes === 2 && (weight === 'unknown' || standards > 0 || maybeNone || balls > maxPairBalls)) throw new JudgeFormatError('题目字段不合法');
    return { balls, standards, fakes, weight, direction, maybeNone, weighings, seed };
  },
  decodeAnswer: (json) => {
    const raw = field(json, 'weighings');
    if (!Array.isArray(raw) || raw.length > maxWeighings) throw new JudgeFormatError('答案不合法');
    const weighings = raw.map((item) => {
      if (!Array.isArray(item) || item.length !== 2) throw new JudgeFormatError('答案不合法');
      const left = puzzleInts(item[0], maxTotal, 0, maxTotal - 1), right = puzzleInts(item[1], maxTotal, 0, maxTotal - 1);
      if (new Set([...left, ...right]).size !== left.length + right.length) throw new JudgeFormatError('答案不合法');
      return { left, right };
    });
    const balls = puzzleInts(field(json, 'balls'), 2, 0, maxBalls - 1);
    if (new Set(balls).size !== balls.length) throw new JudgeFormatError('答案不合法');
    const heavy = field(json, 'heavy');
    if (heavy !== undefined && heavy !== null && typeof heavy !== 'boolean') throw new JudgeFormatError('答案不合法');
    return { weighings, balls, heavy: typeof heavy === 'boolean' ? heavy : null };
  },
  // 重放秤的回答（次数、两边球数、编号都要合规），最后剩下的候选恰好是指认的那个、那一对（要说轻重的还要轻重对）或都是真的（不带轻重）才算。
  solved: (puzzle, answer) => {
    if (answer.weighings.length > puzzle.weighings) return false;
    if (answer.balls.length === 0 ? answer.heavy !== null : (answer.heavy !== null) !== puzzle.direction) return false;
    const total = puzzle.balls + puzzle.standards;
    let suspects = start(puzzle);
    for (const [index, weighing] of answer.weighings.entries()) {
      if ([...weighing.left, ...weighing.right].some((ball) => ball >= total)) return false;
      if (weighing.left.length === 0 || weighing.right.length === 0 || weighing.left.length !== weighing.right.length) return false;
      const left = maskOf(weighing.left), right = maskOf(weighing.right);
      suspects = split(puzzle, suspects, left, right)[respond(puzzle, suspects, left, right, index)];
    }
    if (answer.balls.length === 0) return suspects.none && (suspects.heavy | suspects.light | suspects.pairs) === 0;
    const sorted = [...answer.balls].sort((first, second) => first - second);
    if (suspects.none || sorted.length !== puzzle.fakes || sorted.some((ball) => ball >= puzzle.balls)) return false;
    if (puzzle.fakes === 2) return suspects.pairs === 1 << pairIndex(puzzle.balls, sorted[0], sorted[1]);
    const bit = 1 << sorted[0];
    const pool = answer.heavy === null ? suspects.heavy | suspects.light : answer.heavy ? suspects.heavy : suspects.light;
    if ((pool & bit) === 0) return false;
    return answer.heavy === null ? (suspects.heavy | suspects.light) === bit : pool === bit && (answer.heavy ? suspects.light : suspects.heavy) === 0;
  },
};
