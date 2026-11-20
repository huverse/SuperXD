import 'dotenv/config';
import Redis from 'ioredis';
import { createConnection } from 'mysql2/promise';

import { env } from 'src/config/env';
import { FlagAdminError, runFlagAdmin } from 'src/modules/flag_target/flag_admin';

const main = async () => {
  const { host, port, username, password, database } = env().mysql;
  const connection = await createConnection({ host, port, user: username, password, database, timezone: 'Z', connectTimeout: 5000 });
  // 与中转同一个库与前缀（src/common/redis/redis.module.ts），点名版本才对得上。
  const config = env().redis;
  const redis = new Redis({ host: config.host, port: config.port, password: config.password, db: config.db, keyPrefix: config.keyPrefix, commandTimeout: 3000, connectTimeout: 5000, maxRetriesPerRequest: 1 });
  try {
    console.log(await runFlagAdmin(connection, redis, process.argv.slice(2)));
  } finally {
    await connection.end();
    redis.disconnect();
  }
};

main().catch((error) => {
  if (error instanceof FlagAdminError) console.error(error.message);
  else console.error(error);
  process.exit(1);
});
