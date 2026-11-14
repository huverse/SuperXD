import { readFileSync } from 'node:fs';

import { rolloutBucket, rolloutIncludes } from 'src/common/rollout_bucket';

// 客户端 lib/domain/rollout.dart 生成的向量（test/rollout_test.dart 读同一份文件），两端分到同一个桶。
const vectors = JSON.parse(readFileSync(new URL('./vectors/rollout_v1.json', import.meta.url), 'utf8')) as {
  cases: { id: string; subject: string; bucket: number }[];
  weighted: { id: string; subject: string; percent: number; level: number; included: boolean }[];
};

describe('rollout bucket vectors', () => {
  it('分桶同客户端', () => {
    for (const item of vectors.cases) expect(rolloutBucket(item.id, item.subject), `${item.id} / ${item.subject}`).toBe(item.bucket);
  });

  it('按积分等级加权的判定同客户端；放量 0 不论等级谁都不在', () => {
    for (const item of vectors.weighted) {
      expect(rolloutIncludes(item.id, item.subject, item.percent, item.level), `${item.subject} ${item.percent}% Lv${item.level}`).toBe(item.included);
      expect(rolloutIncludes(item.id, item.subject, 0, 5)).toBe(false);
    }
  });

  it('0% 谁都不在，100% 谁都在', () => {
    for (const item of vectors.cases) {
      expect(rolloutIncludes(item.id, item.subject, 0)).toBe(false);
      expect(rolloutIncludes(item.id, item.subject, 100)).toBe(true);
    }
  });
});
