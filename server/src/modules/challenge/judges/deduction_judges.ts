import { field, Judge, JudgeFormatError, puzzleInt, puzzleInts } from 'src/modules/challenge/judges/judge_input';

// 逻辑网格推理、密码破译（各自对应 lib/playground/puzzle 下同名的 _rules.dart）。

// ---------- 逻辑网格推理 logicgrid ----------
// 属性池里只有「座位」一类是有序的（Dart 的 logicGridKinds，下标 6），类与值只在末尾追加。
const logicGridSeatKind = 6, logicGridKinds = 7;
const logicGridMinPeople = 3, logicGridMaxPeople = 5, logicGridMinCategories = 2, logicGridMaxCategories = 4, logicGridMaxClues = 40;
// 句式 code 同 Dart 的 LogicGridClueKind：0 是、1 不是、2 要么…要么…、3 左边一位、4 挨着、5 在左边。
const logicGridArity = [2, 2, 3, 2, 2, 2];
type LogicGridRef = { category: number; value: number };
type LogicGridPuzzle = { people: number; categories: number[]; seat: number | null; clues: { kind: number; refs: LogicGridRef[] }[] };

export const logicGridJudge: Judge<LogicGridPuzzle, number[][]> = {
  decodePuzzle: (json) => {
    const people = puzzleInt(json, 'people', logicGridMinPeople, logicGridMaxPeople);
    const rawCategories = field(json, 'categories');
    if (!Array.isArray(rawCategories) || rawCategories.length < logicGridMinCategories || rawCategories.length > logicGridMaxCategories) throw new JudgeFormatError('属性类数不合法');
    const categories = rawCategories.map((raw) => {
      if (!Array.isArray(raw) || raw.length !== 2 || typeof raw[0] !== 'number' || !Number.isInteger(raw[0]) || raw[0] < 0 || raw[0] >= logicGridKinds) throw new JudgeFormatError('属性类不合法');
      return raw[0];
    });
    const seat = categories.indexOf(logicGridSeatKind);
    const rawClues = field(json, 'clues');
    if (!Array.isArray(rawClues) || rawClues.length === 0 || rawClues.length > logicGridMaxClues) throw new JudgeFormatError('线索条数不合法');
    const clues = rawClues.map((raw) => {
      const parts = puzzleInts(raw, 7, 0, 15);
      const kind = parts[0];
      if (kind === undefined || kind >= logicGridArity.length || parts.length !== 1 + 2 * logicGridArity[kind]) throw new JudgeFormatError('句式不合法');
      const refs = Array.from({ length: logicGridArity[kind] }, (_, index) => ({ category: parts[1 + 2 * index], value: parts[2 + 2 * index] }));
      for (const ref of refs) if (ref.category > categories.length || ref.value >= people) throw new JudgeFormatError('线索的参数不合法');
      return { kind, refs };
    });
    return { people, categories, seat: seat < 0 ? null : seat, clues };
  },
  decodeAnswer: (json) => {
    if (!Array.isArray(json) || json.length === 0 || json.length > logicGridMaxCategories) throw new JudgeFormatError('答案不合法');
    const rows = json.map((row) => puzzleInts(row, logicGridMaxPeople, 0, logicGridMaxPeople - 1));
    if (rows.some((row) => row.length < logicGridMinPeople || row.length !== rows[0].length)) throw new JudgeFormatError('答案不合法');
    return rows;
  },
  // 每类都是一一对应，且每条线索都成立（题目保证唯一，所以等价于答对）。
  solved: (puzzle, answer) => {
    if (answer.length !== puzzle.categories.length) return false;
    for (const row of answer) {
      if (row.length !== puzzle.people || new Set(row).size !== puzzle.people || row.some((value) => value < 0 || value >= puzzle.people)) return false;
    }
    const who = (ref: LogicGridRef) => (ref.category === 0 ? ref.value : answer[ref.category - 1].indexOf(ref.value));
    const seatOf = (ref: LogicGridRef) => answer[puzzle.seat!][who(ref)];
    return puzzle.clues.every(({ kind, refs }) => {
      switch (kind) {
        case 0:
          return who(refs[0]) === who(refs[1]);
        case 1:
          return who(refs[0]) !== who(refs[1]);
        case 2:
          return (who(refs[0]) === who(refs[1])) !== (who(refs[0]) === who(refs[2]));
        case 3:
          return seatOf(refs[0]) + 1 === seatOf(refs[1]);
        case 4:
          return Math.abs(seatOf(refs[0]) - seatOf(refs[1])) === 1;
        default:
          return seatOf(refs[0]) < seatOf(refs[1]);
      }
    });
  },
};

// ---------- 密码破译 cipher ----------
type CipherRow = { guess: number[]; exact: number; misplaced: number };
type CipherPuzzle = { length: number; digits: number; rows: CipherRow[] };
const cipherMinLength = 3, cipherMaxLength = 5, cipherMaxDigits = 10, cipherMaxRows = 12;

// Mastermind 记法：位置对的个数，加上数字对、位置不对的个数（重复数字不多算）。
const cipherHint = (code: number[], guess: number[]) => {
  let exact = 0, common = 0;
  for (let position = 0; position < code.length && position < guess.length; position++) if (code[position] === guess[position]) exact++;
  const counts = new Map<number, number>();
  for (const digit of code) counts.set(digit, (counts.get(digit) ?? 0) + 1);
  for (const digit of guess) {
    const left = counts.get(digit) ?? 0;
    if (left === 0) continue;
    counts.set(digit, left - 1);
    common++;
  }
  return { exact, misplaced: common - exact };
};

export const cipherJudge: Judge<CipherPuzzle, number[]> = {
  decodePuzzle: (json) => {
    const length = puzzleInt(json, 'length', cipherMinLength, cipherMaxLength);
    const digits = puzzleInt(json, 'digits', length + 1, cipherMaxDigits);
    const raw = field(json, 'rows');
    if (!Array.isArray(raw) || raw.length === 0 || raw.length > cipherMaxRows) throw new JudgeFormatError('线索行数不合法');
    const rows = raw.map((item) => {
      if (!Array.isArray(item) || item.length !== 3) throw new JudgeFormatError('线索不合法');
      const [exact, misplaced] = [item[1], item[2]];
      if (typeof exact !== 'number' || typeof misplaced !== 'number') throw new JudgeFormatError('线索的提示不合法');
      return { guess: puzzleInts(item[0], length, 0, digits - 1), exact, misplaced };
    });
    return { length, digits, rows };
  },
  decodeAnswer: (json) => {
    const answer = puzzleInts(json, cipherMaxLength, 0, cipherMaxDigits - 1);
    if (answer.length < cipherMinLength) throw new JudgeFormatError('答案不合法');
    return answer;
  },
  // 合规的密码（位数对、在数字范围里、各不相同），并且和每一行线索的提示都对得上。
  solved: (puzzle, answer) => {
    if (answer.length !== puzzle.length || answer.some((digit) => digit >= puzzle.digits) || new Set(answer).size !== answer.length) return false;
    return puzzle.rows.every((row) => {
      const hint = cipherHint(answer, row.guess);
      return hint.exact === row.exact && hint.misplaced === row.misplaced;
    });
  },
};
