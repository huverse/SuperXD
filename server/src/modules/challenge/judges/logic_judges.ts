import { answerBits, field, Judge, JudgeFormatError, puzzleInt, puzzleInts } from 'src/modules/challenge/judges/judge_input';

// 过河问题、数织、骑士与无赖（各自对应 lib/playground/puzzle 下同名的 _rules.dart）。

const bitCount = (mask: number) => {
  let count = 0;
  for (let rest = mask; rest !== 0; rest &= rest - 1) count++;
  return count;
};

// ---------- 过河问题 river ----------
type RiverVariant = 'farmer' | 'guardians' | 'families';
// 人物编码同 Dart：0 农夫、1 狼、2 羊、3 白菜、4 大人、5 小孩，第 f 家的爸爸 10 + 2f、孩子 11 + 2f。
type RiverPerson = { role: 'farmer' | 'wolf' | 'goat' | 'cabbage' | 'adult' | 'kid' | 'father' | 'son'; family: number };
type RiverPuzzle = { variant: RiverVariant; capacity: number; people: RiverPerson[] };
const riverMaxPeople = 10, riverMinCapacity = 2, riverMaxCapacity = 4, riverMaxCrossings = 1024, riverFamilies = 6;
const riverRoles = ['farmer', 'wolf', 'goat', 'cabbage', 'adult', 'kid'] as const;

const riverMembers = (mask: number) => {
  const members: number[] = [];
  for (let index = 0; mask >> index !== 0; index++) if ((mask & (1 << index)) !== 0) members.push(index);
  return members;
};

// 这一群人单独待着会不会出事（同 Dart 的 riverTrouble，只要有没有）。
const riverTrouble = (puzzle: RiverPuzzle, group: number) => {
  const members = riverMembers(group).map((index) => puzzle.people[index]);
  const has = (role: RiverPerson['role']) => members.some((person) => person.role === role);
  switch (puzzle.variant) {
    case 'farmer':
      if (has('farmer')) return false;
      return (has('wolf') && has('goat')) || (has('goat') && has('cabbage'));
    case 'guardians': {
      const kids = members.filter((person) => person.role === 'kid').length;
      const adults = members.length - kids;
      return adults > 0 && kids > adults;
    }
    case 'families': {
      const fathers = new Set(members.filter((person) => person.role === 'father').map((person) => person.family));
      return fathers.size > 0 && members.some((person) => person.role === 'son' && !fathers.has(person.family));
    }
  }
};

const riverRows = (person: RiverPerson) => person.role !== 'wolf' && person.role !== 'goat' && person.role !== 'cabbage';

export const riverJudge: Judge<RiverPuzzle, number[][]> = {
  decodePuzzle: (json) => {
    const variant = field(json, 'variant');
    if (variant !== 'farmer' && variant !== 'guardians' && variant !== 'families') throw new JudgeFormatError('题型不合法');
    const capacity = puzzleInt(json, 'capacity', riverMinCapacity, riverMaxCapacity);
    const people = puzzleInts(field(json, 'people'), riverMaxPeople, 0, 11 + (riverFamilies - 1) * 2).map((code): RiverPerson => {
      if (code >= 10) return { role: code % 2 === 0 ? 'father' : 'son', family: Math.trunc((code - 10) / 2) };
      if (code > 5) throw new JudgeFormatError('人物编码不合法');
      return { role: riverRoles[code], family: -1 };
    });
    return { variant, capacity, people };
  },
  decodeAnswer: (json) => {
    if (!Array.isArray(json) || json.length > riverMaxCrossings) throw new JudgeFormatError('答案不合法');
    return json.map((item) => {
      const crossing = puzzleInts(item, riverMaxCapacity, 0, riverMaxPeople - 1);
      if (crossing.length === 0 || new Set(crossing).size !== crossing.length) throw new JudgeFormatError('答案不合法');
      return crossing;
    });
  },
  solved: (puzzle, answer) => {
    if (answer.length > riverMaxCrossings) return false;
    const everyone = (1 << puzzle.people.length) - 1;
    let left = everyone, side = 0;
    for (const crossing of answer) {
      if (crossing.some((index) => index >= puzzle.people.length)) return false;
      const group = crossing.reduce((mask, index) => mask | (1 << index), 0);
      const here = side === 0 ? left : everyone & ~left;
      if (bitCount(group) > puzzle.capacity || (group & ~here) !== 0) return false;
      if (!riverMembers(group).some((index) => riverRows(puzzle.people[index]))) return false;
      // 开船那一刻：父子题船上也算一处，再看留下的岸与到的岸。
      if (puzzle.variant === 'families' && riverTrouble(puzzle, group)) return false;
      if (riverTrouble(puzzle, here & ~group) || riverTrouble(puzzle, (everyone & ~here) | group)) return false;
      left = side === 0 ? left & ~group : left | group;
      side = 1 - side;
    }
    return left === 0;
  },
};

// ---------- 数织 nonogram ----------
type NonogramPuzzle = { width: number; height: number; rows: number[][]; columns: number[][] };
const nonogramMaxSide = 25;

const runsOf = (line: boolean[]) => {
  const runs: number[] = [];
  let run = 0;
  for (const filled of line) {
    if (filled) {
      run++;
    } else if (run > 0) {
      runs.push(run);
      run = 0;
    }
  }
  if (run > 0) runs.push(run);
  return runs;
};

const sameRuns = (left: number[], right: number[]) => left.length === right.length && left.every((run, index) => run === right[index]);

export const nonogramJudge: Judge<NonogramPuzzle, boolean[]> = {
  decodePuzzle: (json) => {
    const width = puzzleInt(json, 'width', 1, nonogramMaxSide), height = puzzleInt(json, 'height', 1, nonogramMaxSide);
    const lines = (value: unknown, count: number, length: number) => {
      if (!Array.isArray(value) || value.length !== count) throw new JudgeFormatError('提示行数不对');
      return value.map((line) => puzzleInts(line, Math.trunc((length + 1) / 2), 1, length));
    };
    return { width, height, rows: lines(field(json, 'rows'), height, width), columns: lines(field(json, 'columns'), width, height) };
  },
  decodeAnswer: (json) => answerBits(json, nonogramMaxSide * nonogramMaxSide),
  solved: (puzzle, answer) => {
    if (answer.length !== puzzle.width * puzzle.height) return false;
    for (let row = 0; row < puzzle.height; row++) {
      if (!sameRuns(runsOf(answer.slice(row * puzzle.width, (row + 1) * puzzle.width)), puzzle.rows[row])) return false;
    }
    for (let column = 0; column < puzzle.width; column++) {
      const line = Array.from({ length: puzzle.height }, (_, row) => answer[row * puzzle.width + column]);
      if (!sameRuns(runsOf(line), puzzle.columns[column])) return false;
    }
    return true;
  },
};

// ---------- 骑士与无赖 knights ----------
// 句式 code 同 Dart 的 KnightsClaimKind：0 是骑士、1 是无赖、2 同类、3 不同类、4 恰好、5 至少、6 至多、7 如果…那么、8 至少一个是无赖、9 转述。
type KnightsClaim = { kind: number; first: number; second: number };
const knightsMinPeople = 2, knightsMaxPeople = 6;
const knightsArity = [1, 1, 1, 1, 1, 1, 1, 2, 2, 2];

const isKnight = (knights: number, person: number) => ((knights >> person) & 1) === 1;

const knightsTruth = (claim: KnightsClaim, speaker: number, knights: number) => {
  const { first, second } = claim;
  switch (claim.kind) {
    case 0:
      return isKnight(knights, first);
    case 1:
      return !isKnight(knights, first);
    case 2:
      return isKnight(knights, speaker) === isKnight(knights, first);
    case 3:
      return isKnight(knights, speaker) !== isKnight(knights, first);
    case 4:
      return bitCount(knights) === first;
    case 5:
      return bitCount(knights) >= first;
    case 6:
      return bitCount(knights) <= first;
    case 7:
    case 8:
      return !isKnight(knights, first) || !isKnight(knights, second);
    default:
      return isKnight(knights, first) !== isKnight(knights, second);
  }
};

export const knightsJudge: Judge<KnightsClaim[], boolean[]> = {
  decodePuzzle: (json) => {
    const claims = field(json, 'claims');
    if (!Array.isArray(claims) || claims.length < knightsMinPeople || claims.length > knightsMaxPeople) throw new JudgeFormatError('人数不合法');
    return claims.map((raw) => {
      const parts = puzzleInts(raw, 3, 0, 15);
      const kind = parts[0];
      if (kind === undefined || kind >= knightsArity.length || parts.length !== 1 + knightsArity[kind]) throw new JudgeFormatError('句式不合法');
      return { kind, first: parts[1], second: knightsArity[kind] === 2 ? parts[2] : -1 };
    });
  },
  decodeAnswer: (json) => {
    if (typeof json !== 'string' || json.length < knightsMinPeople || json.length > knightsMaxPeople || !/^[01]+$/.test(json)) throw new JudgeFormatError('答案不合法');
    return [...json].map((char) => char === '1');
  },
  // 每句话的真假都和说话人的身份一致（题目保证唯一，所以等价于答对）。
  solved: (claims, answer) => {
    if (answer.length !== claims.length) return false;
    const knights = answer.reduce((mask, knight, index) => (knight ? mask | (1 << index) : mask), 0);
    return claims.every((claim, speaker) => knightsTruth(claim, speaker, knights) === isKnight(knights, speaker));
  },
};
