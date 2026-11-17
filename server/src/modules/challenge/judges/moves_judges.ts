import { bitString, field, Judge, JudgeFormatError, puzzleInt, puzzleInts } from 'src/modules/challenge/judges/judge_input';

// 按步重放的几个游戏：汉诺塔、冰面滑行、点灯、推箱子（各自对应 lib/playground/puzzle 下同名的 _rules.dart）。

// ---------- 汉诺塔 hanoi ----------
type HanoiPuzzle = { disks: number; start: number[]; target: number };
type HanoiMove = { from: number; to: number };
const hanoiPegs = 3, hanoiMaxDisks = 10, hanoiMaxMoves = 4096;

export const hanoiJudge: Judge<HanoiPuzzle, HanoiMove[]> = {
  decodePuzzle: (json) => {
    const disks = puzzleInt(json, 'disks', 1, hanoiMaxDisks);
    const start = puzzleInts(field(json, 'start'), hanoiMaxDisks, 0, hanoiPegs - 1);
    if (start.length !== disks) throw new JudgeFormatError('开局与盘子数不一致');
    return { disks, start, target: puzzleInt(json, 'target', 0, hanoiPegs - 1) };
  },
  decodeAnswer: (json) => puzzleInts(json, hanoiMaxMoves, 0, hanoiPegs * hanoiPegs - 1).map((code) => ({ from: Math.trunc(code / hanoiPegs), to: code % hanoiPegs })),
  solved: (puzzle, answer) => {
    if (answer.length > hanoiMaxMoves) return false;
    // 每根柱子从底到顶的盘号（盘号 0 最小）。
    const pegs: number[][] = [0, 1, 2].map((peg) => {
      const stack: number[] = [];
      for (let disk = puzzle.disks - 1; disk >= 0; disk--) if (puzzle.start[disk] === peg) stack.push(disk);
      return stack;
    });
    for (const move of answer) {
      if (move.from === move.to) return false;
      const source = pegs[move.from], destination = pegs[move.to];
      if (source.length === 0) return false;
      if (destination.length > 0 && destination[destination.length - 1] < source[source.length - 1]) return false;
      destination.push(source.pop()!);
    }
    return pegs[puzzle.target].length === puzzle.disks;
  },
  steps: (_puzzle, answer) => answer.length,
};

// ---------- 冰面滑行 ice 第 1 版题面（只有岩石；已发布的客户端还报第 1 版，留着不动） ----------
type IcePuzzle = { width: number; height: number; rocks: boolean[]; start: number; goal: number };
const iceMinSide = 3, iceMaxSide = 16, iceMaxMoves = 2048;
const rowStep = [-1, 0, 1, 0], columnStep = [0, 1, 0, -1];

const iceSlide = (puzzle: IcePuzzle, cell: number, direction: number) => {
  let row = Math.trunc(cell / puzzle.width), column = cell % puzzle.width;
  for (;;) {
    const nextRow = row + rowStep[direction], nextColumn = column + columnStep[direction];
    if (nextRow < 0 || nextRow >= puzzle.height || nextColumn < 0 || nextColumn >= puzzle.width || puzzle.rocks[nextRow * puzzle.width + nextColumn]) return row * puzzle.width + column;
    row = nextRow;
    column = nextColumn;
  }
};

export const iceJudge: Judge<IcePuzzle, number[]> = {
  decodePuzzle: (json) => {
    const width = puzzleInt(json, 'width', iceMinSide, iceMaxSide), height = puzzleInt(json, 'height', iceMinSide, iceMaxSide);
    const cells = width * height;
    // 挑战里标的几个出口（exits）只给页面画，判定只看停没停在终点。
    if (field(json, 'exits') !== undefined) puzzleInts(field(json, 'exits'), 4, 0, cells - 1);
    return { width, height, rocks: bitString(field(json, 'rocks'), cells), start: puzzleInt(json, 'start', 0, cells - 1), goal: puzzleInt(json, 'goal', 0, cells - 1) };
  },
  decodeAnswer: (json) => puzzleInts(json, iceMaxMoves, 0, 3),
  solved: (puzzle, answer) => answer.length <= iceMaxMoves && answer.reduce((cell, direction) => iceSlide(puzzle, cell, direction), puzzle.start) === puzzle.goal,
  steps: (_puzzle, answer) => answer.length,
};

// ---------- 冰面滑行 ice 第 2 版题面（11-16 起：雪地、冰洞、薄冰、宝石与步数上限，同 Dart 的 ice_rules.dart 的 iceMove 与 solved） ----------
// 格子 tiles 一格一位数字：0 冰面、1 岩石、2 雪地（滑进去就停）、3 冰洞（滑进去就掉下去）、4 薄冰（同冰面滑过，滑过或停过一次就碎成冰洞）。
// 宝石滑过或停在上面就收走；收齐宝石后停在终点、且步数不超过上限才算解开。题面出自自己的题库，这里只按结构解析。
type IcePuzzleV2 = { width: number; height: number; tiles: number[]; gems: number[]; thin: number[]; start: number; goal: number; limit: number };
type IceState = { cell: number; gems: number; broken: number; fallen: boolean };
const iceRock = 1, iceSnow = 2, iceHole = 3, iceThin = 4;
const iceMaxGems = 3;

// 从 state 朝 direction 滑一次：撞上岩石或边界、滑进雪地为止，路上（含停下的那格）收宝石、记碎的薄冰；碰到冰洞或碎了的薄冰就掉下去。滑不动原样返回。
const iceMoveV2 = (puzzle: IcePuzzleV2, state: IceState, direction: number): IceState => {
  const { width } = puzzle;
  let row = Math.trunc(state.cell / width), column = state.cell % width;
  let { gems, broken } = state;
  for (;;) {
    const nextRow = row + rowStep[direction], nextColumn = column + columnStep[direction];
    if (nextRow < 0 || nextRow >= puzzle.height || nextColumn < 0 || nextColumn >= width) break;
    const next = nextRow * width + nextColumn;
    const tile = puzzle.tiles[next];
    if (tile === iceRock) break;
    const thin = tile === iceThin ? puzzle.thin.indexOf(next) : -1;
    if (tile === iceHole || (thin >= 0 && (broken & (1 << thin)) !== 0)) return { cell: next, gems, broken, fallen: true };
    row = nextRow;
    column = nextColumn;
    const gem = puzzle.gems.indexOf(next);
    if (gem >= 0) gems |= 1 << gem;
    if (thin >= 0) broken |= 1 << thin;
    if (tile === iceSnow) break;
  }
  return { cell: row * width + column, gems, broken, fallen: false };
};

export const iceJudgeV2: Judge<IcePuzzleV2, number[]> = {
  decodePuzzle: (json) => {
    const width = puzzleInt(json, 'width', iceMinSide, iceMaxSide), height = puzzleInt(json, 'height', iceMinSide, iceMaxSide);
    const cells = width * height;
    const text = field(json, 'tiles');
    if (typeof text !== 'string' || text.length !== cells || !/^[0-4]*$/.test(text)) throw new JudgeFormatError('题面的格子串不合法');
    const tiles = [...text].map(Number);
    // 挑战里标的几个出口（exits）只给页面画，判定只看终点。
    if (field(json, 'exits') !== undefined) puzzleInts(field(json, 'exits'), 4, 0, cells - 1);
    return {
      width,
      height,
      tiles,
      gems: puzzleInts(field(json, 'gems'), iceMaxGems, 0, cells - 1),
      thin: tiles.flatMap((tile, cell) => (tile === iceThin ? [cell] : [])),
      start: puzzleInt(json, 'start', 0, cells - 1),
      goal: puzzleInt(json, 'goal', 0, cells - 1),
      limit: puzzleInt(json, 'limit', 1, iceMaxMoves),
    };
  },
  decodeAnswer: (json) => puzzleInts(json, iceMaxMoves, 0, 3),
  solved: (puzzle, answer) => {
    if (answer.length > puzzle.limit) return false;
    let state: IceState = { cell: puzzle.start, gems: 0, broken: 0, fallen: false };
    for (const direction of answer) {
      state = iceMoveV2(puzzle, state, direction);
      if (state.fallen) return false;
    }
    return state.cell === puzzle.goal && state.gems === (1 << puzzle.gems.length) - 1;
  },
  steps: (_puzzle, answer) => answer.length,
};

// ---------- 点灯 lights ----------
type LightsPuzzle = { side: number; lit: boolean[] };
const lightsMinSide = 3, lightsMaxSide = 7, lightsMaxPresses = 1024;

export const lightsJudge: Judge<LightsPuzzle, number[]> = {
  decodePuzzle: (json) => {
    const side = puzzleInt(json, 'side', lightsMinSide, lightsMaxSide);
    return { side, lit: bitString(field(json, 'lights'), side * side) };
  },
  decodeAnswer: (json) => puzzleInts(json, lightsMaxPresses, 0, lightsMaxSide * lightsMaxSide - 1),
  solved: (puzzle, answer) => {
    if (answer.length > lightsMaxPresses) return false;
    const { side } = puzzle;
    const lit = [...puzzle.lit];
    for (const cell of answer) {
      if (cell >= side * side) return false;
      const row = Math.trunc(cell / side), column = cell % side;
      const reached = [cell];
      if (row > 0) reached.push(cell - side);
      if (row < side - 1) reached.push(cell + side);
      if (column > 0) reached.push(cell - 1);
      if (column < side - 1) reached.push(cell + 1);
      for (const target of reached) lit[target] = !lit[target];
    }
    return lit.every((on) => on);
  },
  steps: (_puzzle, answer) => answer.length,
};

// ---------- 八皇后 queens ----------
type QueensPuzzle = { size: number; given: number[] };
const queensMinSize = 4, queensMaxSize = 16;

export const queensJudge: Judge<QueensPuzzle, number[]> = {
  decodePuzzle: (json) => {
    const size = puzzleInt(json, 'size', queensMinSize, queensMaxSize);
    const given = puzzleInts(field(json, 'given'), queensMaxSize, -1, size - 1);
    if (given.length !== size) throw new JudgeFormatError('锁定皇后的行数不对');
    return { size, given };
  },
  decodeAnswer: (json) => puzzleInts(json, queensMaxSize, -1, queensMaxSize - 1),
  // 每行恰好一个、全部互不攻击、并且题面锁定的皇后都在原处。
  solved: (puzzle, answer) => {
    if (answer.length !== puzzle.size) return false;
    for (let row = 0; row < puzzle.size; row++) {
      const column = answer[row];
      if (column < 0 || column >= puzzle.size) return false;
      if (puzzle.given[row] >= 0 && puzzle.given[row] !== column) return false;
      for (let other = 0; other < row; other++) {
        if (column === answer[other] || Math.abs(row - other) === Math.abs(column - answer[other])) return false;
      }
    }
    return true;
  },
};

// ---------- 推箱子 boxes ----------
export type BoxesPuzzle = { width: number; height: number; walls: boolean[]; goals: number[]; boxes: number[]; player: number };
const boxesMinSide = 3, boxesMaxSide = 16, boxesMaxBoxes = 5, boxesMaxMoves = 4096;

const boxesNeighbor = (puzzle: BoxesPuzzle, cell: number, direction: number) => {
  const row = Math.trunc(cell / puzzle.width) + rowStep[direction], column = (cell % puzzle.width) + columnStep[direction];
  if (row < 0 || row >= puzzle.height || column < 0 || column >= puzzle.width) return null;
  const next = row * puzzle.width + column;
  return puzzle.walls[next] ? null : next;
};

// 推了几次（同重放的规则，撞墙、推不动的那步不算）：困难与专家档要和最少推数比。
export const boxesPushes = (puzzle: BoxesPuzzle, answer: number[]) => {
  const boxes = [...puzzle.boxes];
  let player = puzzle.player, pushes = 0;
  for (const direction of answer) {
    const to = boxesNeighbor(puzzle, player, direction);
    if (to === null) continue;
    const box = boxes.indexOf(to);
    if (box >= 0) {
      const beyond = boxesNeighbor(puzzle, to, direction);
      if (beyond === null || boxes.includes(beyond)) continue;
      boxes[box] = beyond;
      pushes++;
    }
    player = to;
  }
  return pushes;
};

export const boxesJudge: Judge<BoxesPuzzle, number[]> = {
  decodePuzzle: (json) => {
    const width = puzzleInt(json, 'width', boxesMinSide, boxesMaxSide), height = puzzleInt(json, 'height', boxesMinSide, boxesMaxSide);
    const cells = width * height;
    const walls = bitString(field(json, 'walls'), cells);
    // 同 Dart 解码：目标点与箱子按格号升序（只影响下标，不影响判定）。
    const spots = (key: string) => puzzleInts(field(json, key), boxesMaxBoxes, 0, cells - 1).sort((left, right) => left - right);
    return { width, height, walls, goals: spots('goals'), boxes: spots('boxes'), player: puzzleInt(json, 'player', 0, cells - 1) };
  },
  decodeAnswer: (json) => puzzleInts(json, boxesMaxMoves, 0, 3),
  solved: (puzzle, answer) => {
    if (answer.length > boxesMaxMoves) return false;
    const boxes = [...puzzle.boxes];
    let player = puzzle.player;
    // 撞墙、推不动原地不动（不算违规，同 Dart 的 boxesReplay）。
    for (const direction of answer) {
      const to = boxesNeighbor(puzzle, player, direction);
      if (to === null) continue;
      const box = boxes.indexOf(to);
      if (box >= 0) {
        const beyond = boxesNeighbor(puzzle, to, direction);
        if (beyond === null || boxes.includes(beyond)) continue;
        boxes[box] = beyond;
      }
      player = to;
    }
    return boxes.every((cell) => puzzle.goals.includes(cell));
  },
  steps: boxesPushes,
};
