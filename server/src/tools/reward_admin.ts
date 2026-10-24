// dotenv 最先加载，早于配置模块读取环境变量（容器里环境变量已就绪，本机开发读 .env）。
import 'dotenv/config';
import { createInterface } from 'node:readline';
import { createConnection } from 'mysql2/promise';

import { env } from 'src/config/env';
import { RewardAdminError, runRewardAdmin } from 'src/modules/reward/reward_admin';

// 节日抽奖维护命令的命令行入口，用法见 src/modules/reward/reward_admin.ts 文件头。
const main = async () => {
  const { host, port, username, password, database } = env().mysql;
  const connection = await createConnection({ host, port, user: username, password, database, timezone: 'Z', connectTimeout: 5000 });
  try {
    console.log(await runRewardAdmin(connection, process.argv.slice(2), createInterface({ input: process.stdin, crlfDelay: Infinity })));
  } finally {
    await connection.end();
  }
};

main().catch((error) => {
  if (error instanceof RewardAdminError) console.error(error.message);
  else console.error(error);
  process.exit(1);
});
