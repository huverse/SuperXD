import { describe, expect, it } from 'vitest';

import { parseTrustProxy } from 'src/config/env';

// 反向代理信任范围的解析（人工决策见 src/config/env.ts 的 11-18 那条）：层数照旧，另认地址、网段与 express 的名字，写坏了启动即失败。
describe('RELAY_TRUST_PROXY', () => {
  it('整数是代理层数', () => {
    expect(parseTrustProxy('X', '0')).toBe(0);
    expect(parseTrustProxy('X', '1')).toBe(1);
  });

  it('地址、网段与名字原样给 express', () => {
    expect(parseTrustProxy('X', 'uniquelocal')).toEqual(['uniquelocal']);
    expect(parseTrustProxy('X', 'loopback, 172.16.0.0/12,10.0.0.1, fd00::/8')).toEqual(['loopback', '172.16.0.0/12', '10.0.0.1', 'fd00::/8']);
  });

  it('写坏了报错', () => {
    for (const value of ['', 'true', 'everyone', '172.16.0.0/33', '1.2.3', '-1', '10.0.0.1/8/1']) {
      expect(() => parseTrustProxy('X', value)).toThrow(/RELAY_TRUST_PROXY|X/);
    }
  });
});
