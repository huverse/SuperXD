// dotenv 最先加载，早于配置模块读取环境变量。
import 'dotenv/config';
import { Logger } from '@nestjs/common';

import { env } from 'src/config/env';
import { createRelayApp } from 'src/relay_app';

const bootstrap = async () => {
  const app = await createRelayApp();
  await app.listen(env().port, '0.0.0.0');
  new Logger('Relay').log(`[Relay] action=listen port=${env().port}`);
};

bootstrap().catch((error) => {
  console.error(error);
  process.exit(1);
});
