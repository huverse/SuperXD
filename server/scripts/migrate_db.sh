#!/usr/bin/env bash
# 表结构升级台账：部署时由维护者执行（服务启动不做 DDL），按文件名顺序执行 sql 下还没登记在台账 schema_migration 里的 upgrade_*.sql，
# 每执行完一个登记一行（文件名、时刻、文件内容的 sha256）。部署与恢复步骤见 server/README.md「部署」与「备份与恢复」。
# [人工决策-2026-11-17 21:24:25] 表结构升级台账与漂移检查（用户同意审查建议 P1-3，按最佳实践做）：以前升级文件靠人记住跑到哪一个，
# 漏跑、重跑都只在线上暴露（14c 重跑会失败、15b 旧版重跑会清光新账号）。现在每个升级文件本身可重复执行，台账记下跑过什么、只跑没跑过的；
# 已登记的文件内容变了就停下等人核对（升级文件上线后不要再改，要改就新加一个）。CI 另由 scripts/schema_drift_check.sh 核对
# 「最早的基线 + 全部升级文件」与 sql/schema.sql 结构一致、每个升级文件可重复执行。没选：服务启动时自动迁移（违反启动不做 DDL）、引入迁移框架（多一个依赖，SQL 文件照样手写）。
# 用法：
#   scripts/migrate_db.sh                         执行还没登记的升级文件并登记（先跑 scripts/backup_db.sh）
#   scripts/migrate_db.sh --status                列出每个升级文件：applied 已执行、baseline 只登记、pending 待执行、changed 登记后被改过
#   scripts/migrate_db.sh --baseline <文件名>     接入台账前已手工执行过的：这个文件及按顺序在它之前的只登记、不执行（线上第一次用）
#   scripts/migrate_db.sh --structure             打印规范化的表结构（列的先后、类型、可空、默认值、生成列、字符集；索引；引擎与排序规则；不含注释），漂移检查与线上核对用
# 连接：默认在 compose 的 mysql 容器里用容器自己的 MYSQL_USER、MYSQL_PASSWORD、MYSQL_DATABASE（同 backup_db.sh，密码不经命令行），
# docker compose 自己的 COMPOSE_FILE、COMPOSE_PROJECT_NAME 照常生效；设了 MIGRATE_MYSQL_HOST 时改用本机的 mysql 客户端直连（漂移检查），
# 另要 MIGRATE_MYSQL_PORT、MIGRATE_MYSQL_USER、MIGRATE_MYSQL_PASSWORD、MIGRATE_MYSQL_DATABASE。
set -euo pipefail

log() { echo "[Migrate] $* time=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }

cd "$(dirname "$0")/.."
# 台账表由这个升级文件建：台账还没有时先执行它（之后照常按顺序轮到它时再执行一遍、登记，可重复执行）。
ledger_file=upgrade_2026_11_17.sql
name_pattern='^upgrade_[0-9]{4}_[0-9]{2}_[0-9]{2}[a-z]?\.sql$'

# 从标准输入读 SQL 执行；-N -B 只出数据行、制表符分隔。
sql() {
  if [ -n "${MIGRATE_MYSQL_HOST:-}" ]; then
    # shellcheck disable=SC2153 # 直连用的几个变量由调用方一起给（见文件头）。
    MYSQL_PWD="$MIGRATE_MYSQL_PASSWORD" mysql --protocol=TCP -h"$MIGRATE_MYSQL_HOST" -P"$MIGRATE_MYSQL_PORT" -u"$MIGRATE_MYSQL_USER" --default-character-set=utf8mb4 -N -B "$MIGRATE_MYSQL_DATABASE"
  else
    # shellcheck disable=SC2016 # 变量要在容器里展开，用的是容器自己的环境变量。
    docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -u"$MYSQL_USER" --default-character-set=utf8mb4 -N -B "$MYSQL_DATABASE"'
  fi
}

structure() {
  sql <<'SQL'
SELECT CONCAT_WS(' ', 'table', TABLE_NAME, CONCAT('engine=', ENGINE), CONCAT('collation=', TABLE_COLLATION))
FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME;
SELECT CONCAT_WS(' ', 'column', TABLE_NAME, ORDINAL_POSITION, COLUMN_NAME, COLUMN_TYPE, CONCAT('null=', IS_NULLABLE), CONCAT('default=', IFNULL(COLUMN_DEFAULT, '<null>')),
  CONCAT('extra=', EXTRA), CONCAT('charset=', IFNULL(CHARACTER_SET_NAME, '-')), CONCAT('collation=', IFNULL(COLLATION_NAME, '-')), CONCAT('generated=', GENERATION_EXPRESSION))
FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME, ORDINAL_POSITION;
SELECT CONCAT_WS(' ', 'index', TABLE_NAME, INDEX_NAME, CONCAT('unique=', 1 - MAX(NON_UNIQUE)), CONCAT('type=', MAX(INDEX_TYPE)), CONCAT('visible=', MAX(IS_VISIBLE)),
  CONCAT('columns=', GROUP_CONCAT(CONCAT(IFNULL(COLUMN_NAME, EXPRESSION), IF(SUB_PART IS NULL, '', CONCAT('(', SUB_PART, ')'))) ORDER BY SEQ_IN_INDEX SEPARATOR ',')))
FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() GROUP BY TABLE_NAME, INDEX_NAME ORDER BY TABLE_NAME, INDEX_NAME;
SQL
}

mode=apply
target=
case "${1:-}" in
  '') ;;
  --status) mode=status ;;
  --structure) mode=structure ;;
  --baseline)
    mode=baseline
    target=${2:-}
    if ! [[ $target =~ $name_pattern ]]; then echo "用法：scripts/migrate_db.sh --baseline <upgrade_*.sql 文件名>" >&2; exit 2; fi
    ;;
  *) echo "用法：scripts/migrate_db.sh [--status | --structure | --baseline <文件名>]" >&2; exit 2 ;;
esac

if [ "$mode" = structure ]; then
  structure
  exit 0
fi

# 升级文件按文件名的字节序排（upgrade_2026_11_14.sql 在 upgrade_2026_11_14b.sql 之前），即线上执行过的顺序。
mapfile -t files < <(find sql -maxdepth 1 -name 'upgrade_*.sql' -printf '%f\n' | LC_ALL=C sort)
declare -A current=()
for file in "${files[@]}"; do
  if ! [[ $file =~ $name_pattern ]]; then log "action=scan file=$file errorType=bad_name" >&2; exit 2; fi
  current[$file]=$(sha256sum "sql/$file" | cut -d' ' -f1)
done
if [ "$mode" = baseline ] && [ -z "${current[$target]:-}" ]; then log "action=baseline file=$target errorType=not_found" >&2; exit 2; fi

# 在顶层赋值（不放进 if 或函数的条件里，那里 set -e 不生效）：连不上库时就在这里失败退出，不会被当成「台账还没建」。
has_ledger=$(printf '%s\n' "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'schema_migration';" | sql)
if [ "$mode" = status ] && [ "$has_ledger" = 0 ]; then
  for file in "${files[@]}"; do echo "pending $file"; done
  log "action=status ledger=missing pending=${#files[@]}"
  exit 0
fi
if [ "$has_ledger" = 0 ]; then
  sql < "sql/$ledger_file" > /dev/null
  log "action=ledger_create file=$ledger_file"
fi

# 先整份读出来再逐行解析：查询失败时在这里就退出，不会当成台账是空的、把升级文件全跑一遍。
rows=$(printf '%s\n' 'SELECT file_name, checksum, mode FROM schema_migration ORDER BY file_name;' | sql)
declare -A recorded=() recorded_mode=()
while IFS=$'\t' read -r file checksum kind; do
  [ -n "$file" ] || continue
  recorded[$file]=$checksum
  recorded_mode[$file]=$kind
done <<< "$rows"

changed=()
for file in "${!recorded[@]}"; do
  if [ -z "${current[$file]:-}" ]; then
    log "action=check file=$file errorType=missing_file" >&2
  elif [ "${recorded[$file]}" != "${current[$file]}" ]; then
    changed+=("$file")
  fi
done

if [ "$mode" = status ]; then
  pending=0
  for file in "${files[@]}"; do
    if [ -z "${recorded[$file]:-}" ]; then echo "pending $file"; pending=$((pending + 1))
    elif [ "${recorded[$file]}" != "${current[$file]}" ]; then echo "changed $file"
    else echo "${recorded_mode[$file]} $file"; fi
  done
  log "action=status pending=$pending changed=${#changed[@]}"
  exit 0
fi

# 登记后被改过的升级文件：停下，什么也不执行。核对改动只是注释或等价的写法后，按提示改台账里的校验和再重跑。
if [ "${#changed[@]}" -gt 0 ]; then
  for file in "${changed[@]}"; do
    log "action=check file=$file errorType=checksum_changed recorded=${recorded[$file]} current=${current[$file]}" >&2
    echo "核对过改动后可执行：UPDATE schema_migration SET checksum = '${current[$file]}', update_time = UTC_TIMESTAMP(3) WHERE file_name = '$file';" >&2
  done
  exit 1
fi

if [ "$mode" = baseline ]; then
  marked=0
  for file in "${files[@]}"; do
    if [ -z "${recorded[$file]:-}" ]; then
      printf '%s\n' "INSERT INTO schema_migration (file_name, checksum, mode, create_time, update_time) VALUES ('$file', '${current[$file]}', 'baseline', UTC_TIMESTAMP(3), UTC_TIMESTAMP(3));" | sql
      log "action=baseline file=$file"
      marked=$((marked + 1))
    fi
    if [ "$file" = "$target" ]; then break; fi
  done
  log "action=baseline_done target=$target marked=$marked"
  exit 0
fi

applied=0
for file in "${files[@]}"; do
  if [ -n "${recorded[$file]:-}" ]; then continue; fi
  started=$SECONDS
  # 升级文件里 PREPARE 的 SELECT 1 会出结果行，丢掉；出错时 mysql 停在那一句、非零退出，这个文件不登记，修好后重跑（文件可重复执行）。
  sql < "sql/$file" > /dev/null
  printf '%s\n' "INSERT INTO schema_migration (file_name, checksum, mode, create_time, update_time) VALUES ('$file', '${current[$file]}', 'applied', UTC_TIMESTAMP(3), UTC_TIMESTAMP(3));" | sql
  log "action=apply file=$file seconds=$((SECONDS - started))"
  applied=$((applied + 1))
done
log "action=done applied=$applied total=${#files[@]}"
