// e2e 默认连接 docker-compose.test.yml 起的 MySQL 与 Redis；CI 可用同名环境变量覆盖。
const defaults: Record<string, string> = {
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
