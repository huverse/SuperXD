import 'dotenv/config';
import { createConnection } from 'mysql2/promise';

import { env } from 'src/config/env';
import { FlagAdminError, runFlagAdmin } from 'src/modules/flag_target/flag_admin';

const main = async () => {
  const { host, port, username, password, database } = env().mysql;
  const connection = await createConnection({ host, port, user: username, password, database, timezone: 'Z', connectTimeout: 5000 });
  try {
    console.log(await runFlagAdmin(connection, process.argv.slice(2)));
  } finally {
    await connection.end();
  }
};

main().catch((error) => {
  if (error instanceof FlagAdminError) console.error(error.message);
  else console.error(error);
  process.exit(1);
});
