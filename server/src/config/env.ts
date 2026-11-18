// 环境变量唯一入口：业务代码一律从 env 取值，禁止散落 process.env。缺失必填项启动即失败。
import { isIP } from 'node:net';

const required = (name: string): string => {
  const value = process.env[name];
  if (value === undefined || value === '') throw new Error(`缺少环境变量 ${name}`);
  return value;
};

const integer = (name: string): number => {
  const value = Number(required(name));
  if (!Number.isInteger(value)) throw new Error(`环境变量 ${name} 不是整数`);
  return value;
};

const flag = (name: string): boolean => {
  const value = required(name);
  if (value !== 'true' && value !== 'false') throw new Error(`环境变量 ${name} 只能是 true 或 false`);
  return value === 'true';
};

// 反向代理的信任范围：整数是代理层数（0 为前面没有代理）；否则是逗号分隔的地址、网段或 express 认得的名字（loopback、linklocal、uniquelocal），
// 只有从这些地址来的请求才按 X-Forwarded-For 取客户端 IP。
const proxyNames = new Set(['loopback', 'linklocal', 'uniquelocal']);
export const parseTrustProxy = (name: string, value: string): number | string[] => {
  if (/^\d+$/.test(value)) return Number(value);
  const entries = value.split(',').map((entry) => entry.trim()).filter((entry) => entry !== '');
  const valid = (entry: string): boolean => {
    if (proxyNames.has(entry)) return true;
    const [address, prefix, ...rest] = entry.split('/');
    const family = isIP(address);
    if (family === 0 || rest.length > 0) return false;
    return prefix === undefined || (/^\d+$/.test(prefix) && Number(prefix) <= (family === 4 ? 32 : 128));
  };
  if (entries.length === 0 || !entries.every(valid)) throw new Error(`环境变量 ${name} 要么是代理层数，要么是逗号分隔的地址、网段或 loopback、linklocal、uniquelocal`);
  return entries;
};

const timeZone = (name: string): string => {
  const value = required(name);
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: value });
  } catch {
    throw new Error(`环境变量 ${name} 不是认得的时区名`);
  }
  return value;
};

export const loadEnv = () => ({
  port: integer('RELAY_PORT'),
  // 反向代理：按 X-Forwarded-For 取客户端 IP 做注册、登录与代签接口的限流与扫码登录的属地。前面没有代理时必须为 0，否则来源 IP 可被伪造。
  // [人工决策-2026-11-18 18:10:39] 中转改用 Let's Encrypt 公网 IP 证书的 HTTPS（用户在两路实验后选定）：Nginx 在 8443 终止 HTTPS 再转给中转，
  // 旧版本客户端仍直连 8080 明文。两条路同时开着时不能用层数（直连 8080 的人可以自己写 X-Forwarded-For 冒充来源），
  // 线上设为 uniquelocal：只信内网来的请求（Nginx 在 compose 内网里），直连的公网来源一律按真实地址，见 docker-compose.yml 的 tls。
  trustProxy: parseTrustProxy('RELAY_TRUST_PROXY', required('RELAY_TRUST_PROXY')),
  swagger: flag('RELAY_SWAGGER'),
  // 构建版本：流水线构建镜像时把提交号经构建参数写进镜像（Dockerfile 的 RELAY_BUILD_VERSION），/v1/health 原样返回；
  // 本地开发与测试不经镜像构建，没有这个变量即为 dev。不要写进 .env（env_file 会盖掉镜像里的值）。
  buildVersion: process.env.RELAY_BUILD_VERSION ?? 'dev',
  // 应用更新：版本清单（<渠道>.json）与安装包所在目录，发版时人工放入；容器里只读挂载。
  releasesDir: required('RELAY_RELEASES_DIR'),
  // 诊断包密文的存放目录（文件名即诊断编号），要可写；容器里是 compose 挂的命名卷。
  diagnosticsDir: required('RELAY_DIAGNOSTICS_DIR'),
  // 业务时区（IANA 名，同客户端 lib/domain/campus_clock.dart 的 campusTimeZone）：每周轮换的挑战按它的周一 0 点换，日界只在这里取，不写死偏移。
  businessTimeZone: timeZone('RELAY_BUSINESS_TIME_ZONE'),
  account: {
    // 客户端封装密码与恢复码用的 X25519 私钥种子（32 字节 base64url）：一把或几把，逗号分隔、现用的在前（换钥过渡期新旧都在，见 src/modules/account/account_keys.ts）；
    // 现用那把的公钥写死在客户端 lib/relay/account_seal.dart 的 accountSealKey。
    sealKeys: required('RELAY_ACCOUNT_SEAL_KEY').split(','),
  },
  signing: {
    // 服务器在线签名钥的 Ed25519 私钥种子（32 字节 base64url，见 src/common/crypto/relay_signer.ts）：签好友公钥、奖品信封与「账号已注销」，
    // 公钥写死在客户端 lib/relay/relay_client.dart 的 relayServerKeys。变量名沿用最早只签好友公钥时的叫法，线上 .env 不用改。
    key: required('RELAY_FRIEND_SIGN_KEY'),
  },
  // IP 属地离线库 ip2region_v4.xdb 的路径（src/common/ip_region.ts）：镜像里由 Dockerfile 设好；本地开发与测试不配，扫码登录照常、只是不显示属地。
  ipRegionDb: process.env.RELAY_IP_REGION_DB ?? null,
  mysql: {
    host: required('MYSQL_HOST'),
    port: integer('MYSQL_PORT'),
    username: required('MYSQL_USER'),
    password: required('MYSQL_PASSWORD'),
    database: required('MYSQL_DATABASE'),
  },
  redis: {
    host: required('REDIS_HOST'),
    port: integer('REDIS_PORT'),
    password: process.env.REDIS_PASSWORD || undefined,
    db: integer('REDIS_DB'),
    keyPrefix: required('REDIS_KEY_PREFIX'),
  },
});

export type RelayEnv = ReturnType<typeof loadEnv>;

let cached: RelayEnv | undefined;

// 首次访问时读取并校验，之后复用同一份；dotenv 在 main.ts 最先执行。
export const env = (): RelayEnv => (cached ??= loadEnv());
