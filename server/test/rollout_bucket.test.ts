import { readFileSync } from 'node:fs';

import { rolloutBucket, rolloutIncludes } from 'src/common/rollout_bucket';

// 客户端 lib/domain/rollout.dart 生成的向量（test/rollout_test.dart 读同一份文件），两端分到同一个桶。
const vectors = JSON.parse(readFileSync(new URL('./vectors/rollout_v1.json', import.meta.url), 'utf8')) as { cases: { id: string; subject: string; bucket: number }[] };

describe('rollout bucket vectors', () => {
  it('分桶同客户端', () => {
    for (const item of vectors.cases) expect(rolloutBucket(item.id, item.subject), `${item.id} / ${item.subject}`).toBe(item.bucket);
  });

  it('0% 谁都不在，100% 谁都在', () => {
    for (const item of vectors.cases) {
      expect(rolloutIncludes(item.id, item.subject, 0)).toBe(false);
      expect(rolloutIncludes(item.id, item.subject, 100)).toBe(true);
    }
  });
});
