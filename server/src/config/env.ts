// 环境变量唯一入口：业务代码一律从 env 取值，禁止散落 process.env。缺失必填项启动即失败。
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
  // 反向代理层数：部署在 Nginx 等之后时设为 1，按 X-Forwarded-For 取客户端 IP 做注册与代签接口的限流；前面没有代理时必须为 0，否则来源 IP 可被伪造。
  trustProxy: integer('RELAY_TRUST_PROXY'),
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
    // 客户端封装密码与恢复码用的 X25519 私钥种子（32 字节 base64url）；公钥写死在客户端 lib/social/account_seal.dart，换钥两边一起换。
    sealKey: required('RELAY_ACCOUNT_SEAL_KEY'),
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
