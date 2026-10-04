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

export const loadEnv = () => ({
  port: integer('RELAY_PORT'),
  // 反向代理层数：部署在 Nginx 等之后时设为 1，按 X-Forwarded-For 取客户端 IP 做注册限流。
  trustProxy: integer('RELAY_TRUST_PROXY'),
  swagger: flag('RELAY_SWAGGER'),
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
