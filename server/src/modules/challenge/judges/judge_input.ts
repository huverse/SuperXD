// 挑战判定（人工决策见客户端 lib/playground/challenge/challenge_rules.dart）：各游戏的「解码答案 + 按规则判定」从客户端规则
// lib/playground/puzzle/<游戏>/<游戏>_rules.dart 逐个移植，判定结果与 Dart 逐条一致，由 test/vectors/challenge_judge_v1.json（Dart 工具生成）守护。
// 题面来自自己的题库（出题工具用同一份 Dart 规则生成并核过），这里只按结构解析、不重复做可解性检查；答案是外部输入，解码按 Dart 的口径严格校验。

export class JudgeFormatError extends Error {}

export type Judge<P, A> = {
  decodePuzzle(json: unknown): P;
  // 答案不合法（类型、长度、范围）抛 JudgeFormatError，同 Dart 的 decodeAnswer 抛 FormatException。
  decodeAnswer(json: unknown): A;
  solved(puzzle: P, answer: A): boolean;
};

const isRecord = (json: unknown): json is Record<string, unknown> => typeof json === 'object' && json !== null && !Array.isArray(json);

// 同 Dart 的 puzzleInt：取 Map 里的整数，类型或范围不对抛错。
export const puzzleInt = (json: unknown, key: string, min: number, max: number): number => {
  const value = isRecord(json) ? json[key] : undefined;
  if (typeof value !== 'number' || !Number.isInteger(value) || value < min || value > max) throw new JudgeFormatError(`题目字段 ${key} 不合法`);
  return value;
};

// 同 Dart 的 puzzleInts：整数列表，长度与每项范围不对抛错。
export const puzzleInts = (value: unknown, maxLength: number, min: number, max: number): number[] => {
  if (!Array.isArray(value) || value.length > maxLength) throw new JudgeFormatError('题目列表不合法');
  return value.map((item) => {
    if (typeof item !== 'number' || !Number.isInteger(item) || item < min || item > max) throw new JudgeFormatError('题目列表不合法');
    return item;
  });
};

export const field = (json: unknown, key: string): unknown => (isRecord(json) ? json[key] : undefined);

// 题面里的 0、1 串（岩石、墙、灯），长度要对上。
export const bitString = (value: unknown, length: number): boolean[] => {
  if (typeof value !== 'string' || value.length !== length || !/^[01]*$/.test(value)) throw new JudgeFormatError('题面的格子串不合法');
  return [...value].map((char) => char === '1');
};

// 答案里的 0、1 串（数织的涂色、数回的边）：Dart 端是 decodeAnswer 里校验的同一口径。
export const answerBits = (value: unknown, maxLength: number): boolean[] => {
  if (typeof value !== 'string' || value.length > maxLength || !/^[01]*$/.test(value)) throw new JudgeFormatError('答案不合法');
  return [...value].map((char) => char === '1');
};
