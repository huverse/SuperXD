import { createHash } from 'node:crypto';

// 教务（Kingo）登录参数的加密与签名，逐字节同客户端 lib/edu/kingo_codec.dart、kingo_des.dart 与 login_rules.dart 的 buildLoginPlain，
// 双端共用 test/vectors/kingo_login_v1.json。DES 是教务前端脚本的原样移植（按 UTF-16 码元分组、每组 4 个码元），只用于登录参数，不是通用 DES。

// 客户端交来的口令摘要（人工决策见 account_provider.ts）：服务器拿不到明文密码，只拿到教务登录要用的那几项。
export type KingoCredential = {
  account: string;
  // hexMd5(明文密码)，教务登录用的是它加验证码再取一次 MD5。
  passwordDigest: string;
  // 密码强度的几项旁证，教务登录表单要带：字符类别位、长度、是否含账号、是否满足最短长度且不等于账号。
  expression: string;
  length: string;
  userzh: string;
  policy: string;
};

// 只取每个码元的低 8 位再 MD5，同教务前端（码元超出 Latin-1 时与标准 UTF-8 MD5 不同）。
export const hexMd5 = (value: string) => createHash('md5').update(Buffer.from(Array.from({ length: value.length }, (_, index) => value.charCodeAt(index) & 0xff))).digest('hex');

export const utf16To8 = (value: string) => {
  let out = '';
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index);
    if (code >= 0x0001 && code <= 0x007f) out += String.fromCharCode(code);
    else if (code > 0x07ff) out += String.fromCharCode(0xe0 | ((code >> 12) & 0x0f), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    else out += String.fromCharCode(0xc0 | ((code >> 6) & 0x1f), 0x80 | (code & 0x3f));
  }
  return out;
};

const base64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

export const kingoBase64 = (value: string) => {
  let out = '';
  let index = 0;
  while (index < value.length) {
    const c1 = value.charCodeAt(index++) & 0xff;
    if (index === value.length) {
      out += base64Chars[c1 >> 2] + base64Chars[(c1 & 0x3) << 4] + '==';
      break;
    }
    const c2 = value.charCodeAt(index++) & 0xff;
    if (index === value.length) {
      out += base64Chars[c1 >> 2] + base64Chars[((c1 & 0x3) << 4) | ((c2 & 0xf0) >> 4)] + base64Chars[(c2 & 0xf) << 2] + '=';
      break;
    }
    const c3 = value.charCodeAt(index++) & 0xff;
    out += base64Chars[c1 >> 2] + base64Chars[((c1 & 0x3) << 4) | ((c2 & 0xf0) >> 4)] + base64Chars[((c2 & 0xf) << 2) | ((c3 & 0xc0) >> 6)] + base64Chars[c3 & 0x3f];
  }
  return out;
};

const strToBits = (text: string) => {
  const bits = new Array<number>(64).fill(0);
  for (let index = 0; index < Math.min(text.length, 4); index++) {
    const code = text.charCodeAt(index);
    for (let bit = 0; bit < 16; bit++) bits[16 * index + bit] = (code >> (15 - bit)) & 1;
  }
  return bits;
};

const keyBlocks = (key: string) => {
  const blocks: number[][] = [];
  const whole = Math.floor(key.length / 4);
  for (let index = 0; index < whole; index++) blocks.push(strToBits(key.substring(index * 4, index * 4 + 4)));
  if (key.length % 4 > 0) blocks.push(strToBits(key.substring(whole * 4)));
  return blocks;
};

const bitsToHex = (bits: number[]) => {
  let out = '';
  for (let nibble = 0; nibble < 16; nibble++) out += ((bits[nibble * 4] << 3) | (bits[nibble * 4 + 1] << 2) | (bits[nibble * 4 + 2] << 1) | bits[nibble * 4 + 3]).toString(16).toUpperCase();
  return out;
};

const boxes = [
  [[14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7], [0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8], [4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0], [15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13]],
  [[15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10], [3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5], [0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15], [13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9]],
  [[10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8], [13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1], [13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7], [1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12]],
  [[7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15], [13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9], [10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4], [3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14]],
  [[2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9], [14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6], [4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14], [11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3]],
  [[12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11], [10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8], [9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6], [4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13]],
  [[4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1], [13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6], [1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2], [6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12]],
  [[13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7], [1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2], [7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8], [2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11]],
];
const pOrder = [15, 6, 19, 20, 28, 11, 27, 16, 0, 14, 22, 25, 4, 17, 30, 9, 1, 7, 23, 13, 31, 26, 2, 8, 18, 12, 29, 5, 21, 10, 3, 24];
const finalOrder = [
  39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29, 36, 4, 44, 12, 52, 20, 60, 28,
  35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25, 32, 0, 40, 8, 48, 16, 56, 24,
];
const shifts = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];
const pick = [13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1, 40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31];

const roundKeys = (keyBits: number[]) => {
  const key = new Array<number>(56).fill(0);
  for (let row = 0; row < 7; row++) for (let column = 0, source = 7; column < 8; column++, source--) key[row * 8 + column] = keyBits[8 * source + row];
  const keys: number[][] = [];
  for (const shift of shifts) {
    for (let step = 0; step < shift; step++) {
      const left = key[0], right = key[28];
      for (let index = 0; index < 27; index++) {
        key[index] = key[index + 1];
        key[28 + index] = key[29 + index];
      }
      key[27] = left;
      key[55] = right;
    }
    keys.push(pick.map((index) => key[index]));
  }
  return keys;
};

const initialPermute = (bits: number[]) => {
  const out = new Array<number>(64).fill(0);
  for (let row = 0, odd = 1, even = 0; row < 4; row++, odd += 2, even += 2) {
    for (let source = 7, column = 0; source >= 0; source--, column++) {
      out[row * 8 + column] = bits[source * 8 + odd];
      out[row * 8 + column + 32] = bits[source * 8 + even];
    }
  }
  return out;
};

const expand = (right: number[]) => {
  const out = new Array<number>(48).fill(0);
  for (let group = 0; group < 8; group++) {
    out[group * 6] = group === 0 ? right[31] : right[group * 4 - 1];
    for (let bit = 0; bit < 4; bit++) out[group * 6 + 1 + bit] = right[group * 4 + bit];
    out[group * 6 + 5] = group === 7 ? right[0] : right[group * 4 + 4];
  }
  return out;
};

const substitute = (bits: number[]) => {
  const out = new Array<number>(32).fill(0);
  for (let box = 0; box < 8; box++) {
    const row = bits[box * 6] * 2 + bits[box * 6 + 5];
    const column = bits[box * 6 + 1] * 8 + bits[box * 6 + 2] * 4 + bits[box * 6 + 3] * 2 + bits[box * 6 + 4];
    const value = boxes[box][row][column];
    for (let bit = 0; bit < 4; bit++) out[box * 4 + bit] = (value >> (3 - bit)) & 1;
  }
  return out;
};

const encryptBlock = (data: number[], keyBits: number[]) => {
  const keys = roundKeys(keyBits);
  const permuted = initialPermute(data);
  let left = permuted.slice(0, 32), right = permuted.slice(32);
  for (const key of keys) {
    const mixed = substitute(expand(right).map((bit, index) => bit ^ key[index]));
    const next = pOrder.map((index, position) => mixed[index] ^ left[position]);
    left = right;
    right = next;
  }
  const joined = [...right, ...left];
  return finalOrder.map((index) => joined[index]);
};

// 教务前端的 strEnc(data, firstKey)：每 4 个码元一组，依次用密钥的每一组加密，输出大写十六进制。
export const strEnc = (data: string, firstKey: string) => {
  if (data.length === 0) return '';
  const keys = firstKey.length === 0 ? [] : keyBlocks(firstKey);
  const cipher = (block: string) => bitsToHex(keys.reduce((bits, key) => encryptBlock(bits, key), strToBits(block)));
  let out = '';
  const whole = Math.floor(data.length / 4);
  for (let index = 0; index < whole; index++) out += cipher(data.substring(index * 4, index * 4 + 4));
  if (whole === 0 || data.length % 4 > 0) out += cipher(data.substring(whole * 4));
  return out;
};

export const encryptLoginParams = (plain: string, tempDeskey: string) => kingoBase64(utf16To8(strEnc(plain, tempDeskey)));

export const loginToken = (plain: string, timestamp: string) => hexMd5(hexMd5(plain) + hexMd5(timestamp));

// 同客户端 buildLoginPlain，只是密码一项由客户端算好的摘要代入：hexMd5(hexMd5(明文) + hexMd5(验证码小写))。
export const buildLoginPlain = (credential: KingoCredential, pageSession: string, captcha: string) => {
  const hidFlag = captcha === '' ? '1' : '';
  const password = hexMd5(credential.passwordDigest + hexMd5(captcha.toLowerCase()));
  const userEncoded = kingoBase64(`${credential.account};;${pageSession}`);
  return (
    `_u${captcha}=${userEncoded}&_p${captcha}=${password}&randnumber=${captcha}&isPasswordPolicy=${credential.policy}` +
    `&txt_mm_expression=${credential.expression}&txt_mm_length=${credential.length}&txt_mm_userzh=${credential.userzh}` +
    `&hid_flag=${hidFlag}&hidlag=1&hid_dxyzm=`
  );
};
