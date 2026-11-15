import { tmpdir } from 'node:os';
import { join } from 'node:path';

// e2e 默认连接 docker-compose.test.yml 起的 MySQL 与 Redis；CI 可用同名环境变量覆盖。
const defaults: Record<string, string> = {
  // 应用更新用例自己往这个临时目录放清单与安装包。
  RELAY_RELEASES_DIR: join(tmpdir(), 'superxd-relay-releases-test'),
  // 诊断包用例同样用自己的临时目录。
  RELAY_DIAGNOSTICS_DIR: join(tmpdir(), 'superxd-relay-diagnostics-test'),
  // 应用账号封装密码与恢复码用的私钥种子：公开的测试值（同 test/vectors/account_seal_v1.json 的 recipientSeed），只在测试与镜像试运行里用。
  RELAY_ACCOUNT_SEAL_KEY: 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA',
  RELAY_BUSINESS_TIME_ZONE: 'Asia/Shanghai',
  RELAY_PORT: '0',
  RELAY_TRUST_PROXY: '0',
  RELAY_SWAGGER: 'false',
  MYSQL_HOST: '127.0.0.1',
  MYSQL_PORT: '3307',
  MYSQL_USER: 'superxd',
  MYSQL_PASSWORD: 'test',
  MYSQL_DATABASE: 'superxd_relay_test',
  REDIS_HOST: '127.0.0.1',
  REDIS_PORT: '6380',
  REDIS_DB: '0',
  REDIS_KEY_PREFIX: 'sxdtest:',
};

for (const [name, value] of Object.entries(defaults)) process.env[name] ??= value;
