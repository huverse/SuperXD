import { readFileSync } from 'node:fs';

import { buildLoginPlain, encryptLoginParams, KingoCredential, loginToken, strEnc } from 'src/modules/kingo/kingo_codec';

// 客户端 lib/edu 生成的向量（test/kingo_vectors_test.dart 读同一份文件），服务端逐字节一致才能代客户端登录教务。
const vectors = JSON.parse(readFileSync(new URL('./vectors/kingo_login_v1.json', import.meta.url), 'utf8')) as {
  strEnc: { data: string; key: string; out: string }[];
  encryptLoginParams: { plain: string; deskey: string; out: string }[];
  loginToken: { plain: string; timestamp: string; out: string }[];
  proofs: { proof: KingoCredential; pageSession: string; captcha: string; plain: string }[];
};

describe('kingo codec vectors', () => {
  it('strEnc 同教务前端', () => {
    for (const item of vectors.strEnc) expect(strEnc(item.data, item.key), `${item.data} / ${item.key}`).toBe(item.out);
  });

  it('登录参数加密与签名', () => {
    for (const item of vectors.encryptLoginParams) expect(encryptLoginParams(item.plain, item.deskey)).toBe(item.out);
    for (const item of vectors.loginToken) expect(loginToken(item.plain, item.timestamp)).toBe(item.out);
  });

  it('用口令摘要拼出的登录明文同客户端用明文密码拼的', () => {
    for (const item of vectors.proofs) expect(buildLoginPlain(item.proof, item.pageSession, item.captcha)).toBe(item.plain);
  });
});
