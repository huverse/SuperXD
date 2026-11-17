#!/usr/bin/env bash
# 表结构漂移检查（人工决策见 scripts/migrate_db.sh 文件头）：CI 的 Relay server test 每次都跑，在一台 MySQL 上建三个临时库、跑完删掉：
#   fresh：执行 sql/schema.sql，再用台账脚本执行全部升级文件——结构不能变（新库跑台账脚本只是登记，升级文件在新库上都是空操作）；
#   upgraded：执行最早的基线 sql/baseline/schema_2026_10_06.sql，再用台账脚本按顺序执行全部升级文件——结构要和 fresh 一样（升级路径 = schema.sql）；
#   twice：同 upgraded，之后把每个升级文件再直接执行一遍——结构仍一样、不报错（每个升级文件都可重复执行，部署中途失败可以重跑）。
# 比的是 scripts/migrate_db.sh --structure 的规范化结构（列的先后、类型、可空、默认值、生成列、字符集；索引；引擎与排序规则），不比注释。
# 用法：MIGRATE_MYSQL_HOST=127.0.0.1 MIGRATE_MYSQL_PORT=3307 MIGRATE_ROOT_PASSWORD=<root 密码> scripts/schema_drift_check.sh
# 要能建库删库的账号（root）；库名带进程号，不碰已有的库。本机没有 mysql 客户端时在同版本的 mysql 镜像里跑（见 server/README.md「本地开发与测试」）。
set -euo pipefail

log() { echo "[SchemaDrift] $*"; }

cd "$(dirname "$0")/.."
prefix="sxd_drift_$$"
databases=("${prefix}_fresh" "${prefix}_upgraded" "${prefix}_twice")
work=$(mktemp -d)

root() { MYSQL_PWD="$MIGRATE_ROOT_PASSWORD" mysql --protocol=TCP -h"$MIGRATE_MYSQL_HOST" -P"$MIGRATE_MYSQL_PORT" -uroot --default-character-set=utf8mb4 -N -B "$@"; }
# 台账脚本按 MIGRATE_MYSQL_* 直连指定的库。
migrate() { MIGRATE_MYSQL_USER=root MIGRATE_MYSQL_PASSWORD="$MIGRATE_ROOT_PASSWORD" MIGRATE_MYSQL_DATABASE="$1" scripts/migrate_db.sh "${@:2}"; }

cleanup() {
  for database in "${databases[@]}"; do printf '%s\n' "DROP DATABASE IF EXISTS \`$database\`;" | root || true; done
  rm -rf "$work"
}
trap cleanup EXIT

for database in "${databases[@]}"; do printf '%s\n' "CREATE DATABASE \`$database\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;" | root; done

# 两份结构不一样就把只在一边的行列出来（每行带表名与列序号，排序后比不丢信息）。
same() {
  local left=$1 right=$2 what=$3
  if [ "$(< "$work/$left")" = "$(< "$work/$right")" ]; then return 0; fi
  log "result=drift check=$what"
  echo "只在 $left 里：" >&2
  LC_ALL=C comm -23 <(LC_ALL=C sort "$work/$left") <(LC_ALL=C sort "$work/$right") >&2
  echo "只在 $right 里：" >&2
  LC_ALL=C comm -13 <(LC_ALL=C sort "$work/$left") <(LC_ALL=C sort "$work/$right") >&2
  return 1
}

failed=0

root "${prefix}_fresh" < sql/schema.sql
migrate "${prefix}_fresh" --structure > "$work/schema.sql"
if ! migrate "${prefix}_fresh" > /dev/null; then log "result=failed check=升级文件在新库上执行出错（不可重复执行或与 schema.sql 冲突，见上面 mysql 的报错）"; exit 1; fi
migrate "${prefix}_fresh" --structure > "$work/schema.sql+升级文件"
same schema.sql schema.sql+升级文件 '升级文件在新库上是空操作' || failed=1

for database in "${prefix}_upgraded" "${prefix}_twice"; do
  root "$database" < sql/baseline/schema_2026_10_06.sql
  if ! migrate "$database" > /dev/null; then log "result=failed check=基线上按顺序执行升级文件出错（见上面 mysql 的报错）"; exit 1; fi
done
migrate "${prefix}_upgraded" --structure > "$work/基线+升级文件"
same schema.sql 基线+升级文件 '升级路径与 schema.sql 一致' || failed=1

# 不经台账、直接把每个升级文件再执行一遍。
while IFS= read -r file; do
  if ! root "${prefix}_twice" < "sql/$file" > /dev/null; then log "result=not_idempotent file=$file"; failed=1; fi
done < <(find sql -maxdepth 1 -name 'upgrade_*.sql' -printf '%f\n' | LC_ALL=C sort)
migrate "${prefix}_twice" --structure > "$work/升级文件再执行一遍"
same 基线+升级文件 升级文件再执行一遍 '升级文件可重复执行' || failed=1

# 台账：两条路都把每个升级文件登记上了，再跑一次什么也不执行。
expected=$(find sql -maxdepth 1 -name 'upgrade_*.sql' | wc -l)
for database in "${prefix}_fresh" "${prefix}_upgraded"; do
  recorded=$(printf '%s\n' 'SELECT COUNT(*) FROM schema_migration;' | root "$database")
  if [ "$recorded" != "$expected" ]; then log "result=ledger_incomplete database=$database recorded=$recorded expected=$expected"; failed=1; fi
  # 先写进文件再找：管道里 grep -q 找到就退出，前面的命令收到 SIGPIPE，pipefail 下会误判。
  migrate "$database" --status > "$work/status"
  if grep -v '^\[Migrate\]' "$work/status" | grep -v '^applied ' > "$work/not_applied"; then log "result=ledger_pending database=$database files=$(tr '\n' ' ' < "$work/not_applied")"; failed=1; fi
done

if [ "$failed" != 0 ]; then log "result=failed"; exit 1; fi
log "result=ok files=$expected columns=$(grep -c '^column ' "$work/schema.sql") indexes=$(grep -c '^index ' "$work/schema.sql")"
