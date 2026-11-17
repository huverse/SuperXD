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

// ---------- 过河问题 river 第 2 版 ----------
// 同 Dart 第 2 版（river_rules.dart，puzzleVersion 2）：五种题型（加了家庭过河、桥与火把，农夫过河能带更多动物）、会划船的人写在题面上、
// 大人与小孩另写船上算不算、桥与火把另写每人的分钟与火把能烧几分钟。人物编码：0–17 是身份（见 riverRolesV2），第 f 家的爸爸 100 + 2f、孩子 101 + 2f。
type RiverVariantV2 = 'farmer' | 'guardians' | 'families' | 'household' | 'bridge';
const riverRolesV2 = ['farmer', 'wolf', 'goat', 'cabbage', 'adult', 'kid', 'dog', 'cat', 'mouse', 'chicken', 'rice', 'dad', 'mom', 'boy', 'girl', 'police', 'thief', 'walker'] as const;
type RiverRoleV2 = (typeof riverRolesV2)[number] | 'father' | 'son';
type RiverPersonV2 = { role: RiverRoleV2; family: number };
type RiverPuzzleV2 = { variant: RiverVariantV2; capacity: number; people: RiverPersonV2[]; rowers: number; boat: boolean; minutes: number[]; limit: number };
// 农夫过河的食物链（同 Dart 的 riverPrey）。
const riverPreyV2: [RiverRoleV2, RiverRoleV2][] = [
  ['wolf', 'goat'],
  ['goat', 'cabbage'],
  ['wolf', 'chicken'],
  ['dog', 'cat'],
  ['cat', 'mouse'],
  ['mouse', 'rice'],
  ['chicken', 'rice'],
];
const riverItemsV2 = new Set<RiverRoleV2>(['wolf', 'goat', 'cabbage', 'dog', 'cat', 'mouse', 'chicken', 'rice']);
const riverMaxWalkers = 7, riverMaxMinutes = 60, riverMaxLimit = 600;

// 「a 和 b 在一处、guards 里的人一个都不在」就出事（同 Dart 的 riverRules，大人与小孩的人数规矩另算）。
const riverRulesV2 = (puzzle: RiverPuzzleV2) => {
  const having = (role: RiverRoleV2) => puzzle.people.flatMap((person, index) => (person.role === role ? [index] : []));
  const maskOf = (members: number[]) => members.reduce((mask, index) => mask | (1 << index), 0);
  const rules: { a: number; b: number; guards: number }[] = [];
  if (puzzle.variant === 'farmer') {
    const guards = maskOf(having('farmer'));
    for (const [eater, eaten] of riverPreyV2) for (const a of having(eater)) for (const b of having(eaten)) rules.push({ a, b, guards });
  } else if (puzzle.variant === 'families') {
    for (const son of having('son')) {
      const own = maskOf(having('father').filter((index) => puzzle.people[index].family === puzzle.people[son].family));
      for (const other of having('father')) if ((own & (1 << other)) === 0) rules.push({ a: son, b: other, guards: own });
    }
  } else if (puzzle.variant === 'household') {
    const [dads, moms, police] = [maskOf(having('dad')), maskOf(having('mom')), maskOf(having('police'))];
    for (const a of having('mom')) for (const b of having('boy')) rules.push({ a, b, guards: dads });
    for (const a of having('dad')) for (const b of having('girl')) rules.push({ a, b, guards: moms });
    const family = new Set<RiverRoleV2>(['dad', 'mom', 'boy', 'girl']);
    for (const a of having('thief')) puzzle.people.forEach((person, b) => family.has(person.role) && rules.push({ a, b, guards: police }));
  }
  return rules;
};

const riverTroubleV2 = (puzzle: RiverPuzzleV2, rules: { a: number; b: number; guards: number }[], group: number) => {
  if (puzzle.variant === 'guardians') {
    const members = riverMembers(group).map((index) => puzzle.people[index]);
    const kids = members.filter((person) => person.role === 'kid').length;
    if (members.length - kids > 0 && kids > members.length - kids) return true;
  }
  return rules.some((rule) => (group & (1 << rule.a)) !== 0 && (group & (1 << rule.b)) !== 0 && (group & rule.guards) === 0);
};

export const riverJudgeV2: Judge<RiverPuzzleV2, number[][]> = {
  decodePuzzle: (json) => {
    const variant = field(json, 'variant');
    if (variant !== 'farmer' && variant !== 'guardians' && variant !== 'families' && variant !== 'household' && variant !== 'bridge') throw new JudgeFormatError('题型不合法');
    const capacity = puzzleInt(json, 'capacity', riverMinCapacity, riverMaxCapacity);
    const people = puzzleInts(field(json, 'people'), riverMaxPeople, 0, 101 + (riverFamilies - 1) * 2).map((code): RiverPersonV2 => {
      if (code >= 100) return { role: code % 2 === 0 ? 'father' : 'son', family: Math.trunc((code - 100) / 2) };
      if (code >= riverRolesV2.length) throw new JudgeFormatError('人物编码不合法');
      return { role: riverRolesV2[code], family: -1 };
    });
    const members = puzzleInts(field(json, 'rowers'), riverMaxPeople, 0, riverMaxPeople - 1);
    if (members.some((index, order) => index >= people.length || (order > 0 && index <= members[order - 1]))) throw new JudgeFormatError('会划船的人不合法');
    const rowers = members.reduce((mask, index) => mask | (1 << index), 0), everyone = (1 << people.length) - 1;
    const count = (role: RiverRoleV2) => people.filter((person) => person.role === role).length;
    const only = (allowed: RiverRoleV2[]) => people.every((person) => allowed.includes(person.role));
    const fits = {
      farmer: () =>
        count('farmer') === 1 && people.length >= 2 && people.every((person) => person.role === 'farmer' || riverItemsV2.has(person.role)) && new Set(people.map((person) => person.role)).size === people.length && rowers === 1 << people.findIndex((person) => person.role === 'farmer'),
      guardians: () => count('adult') > 0 && count('kid') > 0 && only(['adult', 'kid']),
      families: () =>
        count('father') >= 2 &&
        only(['father', 'son']) &&
        [...new Set(people.map((person) => person.family))].every((family) => {
          const roles = people.filter((person) => person.family === family).map((person) => person.role);
          return roles.length === 2 && new Set(roles).size === 2;
        }),
      household: () =>
        count('dad') === 1 &&
        count('mom') === 1 &&
        count('boy') <= 2 &&
        count('girl') <= 2 &&
        count('boy') + count('girl') > 0 &&
        count('police') === count('thief') &&
        count('police') <= 1 &&
        only(['dad', 'mom', 'boy', 'girl', 'police', 'thief']),
      bridge: () => people.length >= 2 && people.length <= riverMaxWalkers && only(['walker']) && rowers === everyone,
    }[variant]();
    if (!fits || rowers === 0) throw new JudgeFormatError('人物与题型对不上');
    let boat = variant === 'families' || variant === 'household';
    if (variant === 'guardians') {
      const value = field(json, 'boat');
      if (typeof value !== 'boolean') throw new JudgeFormatError('船上算不算不合法');
      boat = value;
    }
    const timed = variant === 'bridge';
    const minutes = timed ? puzzleInts(field(json, 'minutes'), riverMaxWalkers, 1, riverMaxMinutes) : [];
    if (minutes.length !== (timed ? people.length : 0) || new Set(minutes).size !== minutes.length) throw new JudgeFormatError('分钟数对不上');
    const limit = timed ? puzzleInt(json, 'limit', 1, riverMaxLimit) : 0;
    return { variant, capacity, people, rowers, boat, minutes, limit };
  },
  decodeAnswer: (json) => riverJudge.decodeAnswer(json),
  solved: (puzzle, answer) => {
    if (answer.length > riverMaxCrossings) return false;
    const everyone = (1 << puzzle.people.length) - 1, rules = riverRulesV2(puzzle);
    let left = everyone, side = 0, spent = 0;
    for (const crossing of answer) {
      if (crossing.some((index) => index >= puzzle.people.length)) return false;
      const group = crossing.reduce((mask, index) => mask | (1 << index), 0);
      const here = side === 0 ? left : everyone & ~left;
      if (bitCount(group) > puzzle.capacity || (group & ~here) !== 0 || (group & puzzle.rowers) === 0) return false;
      // 开船那一刻：船上（船上算的题型）、留下的岸、到的岸，桥与火把再看火把够不够烧。
      if (puzzle.boat && riverTroubleV2(puzzle, rules, group)) return false;
      if (riverTroubleV2(puzzle, rules, here & ~group) || riverTroubleV2(puzzle, rules, (everyone & ~here) | group)) return false;
      if (puzzle.variant === 'bridge') {
        spent += Math.max(...crossing.map((index) => puzzle.minutes[index]));
        if (spent > puzzle.limit) return false;
      }
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
