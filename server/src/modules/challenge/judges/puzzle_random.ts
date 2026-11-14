// 同客户端 lib/playground/puzzle_rules.dart 的 PuzzleRandom（xoshiro128**，种子经 splitmix32 式展开），只用 32 位运算，逐位一致。
// 服务端只有天平称球的秤要用它（平局时按种子挑结果）。
export class PuzzleRandom {
  private readonly state: number[];

  constructor(seed: number) {
    let state = seed >>> 0;
    const next = () => {
      state = (state + 0x9e3779b9) >>> 0;
      let z = state;
      z = Math.imul(z ^ (z >>> 16), 0x85ebca6b) >>> 0;
      z = Math.imul(z ^ (z >>> 13), 0xc2b2ae35) >>> 0;
      return (z ^ (z >>> 16)) >>> 0;
    };
    this.state = [next(), next(), next(), next()];
    if (!this.state.some((word) => word !== 0)) this.state[0] = 1;
  }

  private static rotl(value: number, bits: number) {
    return ((value << bits) | (value >>> (32 - bits))) >>> 0;
  }

  nextUint32() {
    const s = this.state;
    const result = Math.imul(PuzzleRandom.rotl(Math.imul(s[1], 5) >>> 0, 7), 9) >>> 0;
    const shifted = (s[1] << 9) >>> 0;
    s[2] = (s[2] ^ s[0]) >>> 0;
    s[3] = (s[3] ^ s[1]) >>> 0;
    s[1] = (s[1] ^ s[2]) >>> 0;
    s[0] = (s[0] ^ s[3]) >>> 0;
    s[2] = (s[2] ^ shifted) >>> 0;
    s[3] = PuzzleRandom.rotl(s[3], 11);
    return result;
  }

  // [0, bound) 里的整数，拒绝采样去掉取模偏差。
  nextInt(bound: number) {
    const limit = 0x100000000 - (0x100000000 % bound);
    for (;;) {
      const value = this.nextUint32();
      if (value < limit) return value % bound;
    }
  }
}
