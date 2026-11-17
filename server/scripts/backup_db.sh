#!/usr/bin/env bash
# 中转库备份：在服务器上由 cron 每天跑一次（安装、恢复与演练见 server/README.md「备份与恢复」）。
# [人工决策-2026-11-10 13:12:22] 中转库备份（用户 11-10 确认方向）：只导长期数据——device、friendship 与节日抽奖三张表（reward_campaign、reward_prize、reward_draw）；
# 11-13 起按下面「新增长期保存的表加在这里」补进应用账号的三张表（app_account、account_identity、account_device）；
# 11-14 补进积分的两张表（points_grant、points_entry）与挑战的最好成绩 challenge_best；挑战的一局 challenge_run 结束 30 天就删，是短期数据，不导。
# 11-16 补进灰度点名 rollout_target 与红包名单 reward_audience（都是开发者手工导入的名单，丢了要重导），以及分批更新的暂停记录 app_release_pause（丢了解除过的会被再停）；
# 健康汇总与意见只留 90 天、丢了不影响，不备份。
# 11-14 晚补进私信设备属于哪个应用账号的 account_social（随账号长期保存，丢了要重新接管），与账号记过的解锁 account_unlock（花积分买的，丢了要重新付）。
# 11-15 应用账号改为用户名加密码：account_identity 删除，app_account 里多了密码与恢复码的 scrypt 哈希（没有原文，但备份同样只给属主读写）。
# 11-16 补进注销账号时记的墓碑 account_tombstone（保留 400 天；丢了只是那些设备再来时回 ACCOUNT_NOT_FOUND、不清本机私信）。
# 11-17 补进表结构升级台账 schema_migration（scripts/migrate_db.sh）：恢复后台账回到备份时，再跑台账脚本就把备份之后的升级补上。
# 表清单里库中还没有的表（部署先备份、后执行升级文件，新版脚本新加的长期表这时还不存在）跳过并记一行，不让备份失败。
# message（30 天）与 chaoxing_pack（10 分钟）是短期数据，不导。用 mysqldump --single-transaction 在 InnoDB 一致性快照里导出，不锁表、不停服务；
# gzip 压缩，文件名带 UTC 时刻，按天跑、只留最新 BACKUP_KEEP 份（默认 14）。只存本机盘只防误删与库损坏，防不了整盘丢失；
# 异地存放的去处还没定（等用户选），先留可选的上传钩子 BACKUP_UPLOAD_HOOK：备份写好后以备份文件的绝对路径为参数调用它，失败则本脚本以非零退出。
# 备份里有还没发出的红包口令与二维码内容：目录与文件只给属主读写，传到异地前必须先加密。
# 密码不经命令行：在 mysql 容器里用容器自己的 MYSQL_USER、MYSQL_PASSWORD、MYSQL_DATABASE 环境变量连接。
# 用法：scripts/backup_db.sh。可选环境变量：BACKUP_DIR（默认 compose 目录下的 backups，相对路径按 compose 目录算）、BACKUP_KEEP、BACKUP_UPLOAD_HOOK；
# docker compose 自己的 COMPOSE_FILE、COMPOSE_PROJECT_NAME 照常生效（演练时指向临时库）。
set -euo pipefail

# 新增长期保存的表时加在这里，并同步 README「备份与恢复」。
tables=(device friendship reward_campaign reward_prize reward_draw reward_audience app_account account_device account_tombstone points_grant points_entry challenge_best account_social account_unlock rollout_target app_release_pause schema_migration)

log() { echo "[Backup] $* time=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }

cd "$(dirname "$0")/.."
dir=${BACKUP_DIR:-backups}
keep=${BACKUP_KEEP:-14}
if ! [[ $keep =~ ^[1-9][0-9]*$ ]]; then log "action=start errorType=bad_keep keep=$keep" >&2; exit 2; fi

umask 077
mkdir -p "$dir"
chmod 700 "$dir"
dir=$(cd "$dir" && pwd)
file="$dir/superxd-relay-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
partial="$file.partial"
trap 'rm -f "$partial"' EXIT

started=$SECONDS
# shellcheck disable=SC2016 # 变量要在容器里展开，用的是容器自己的环境变量。
existing=$(docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -u"$MYSQL_USER" -N -B -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()" "$MYSQL_DATABASE"')
present=()
missing=()
for table in "${tables[@]}"; do
  if grep -qx -- "$table" <<< "$existing"; then present+=("$table"); else missing+=("$table"); fi
done
if [ "${#missing[@]}" -gt 0 ]; then log "action=check missing=$(IFS=,; echo "${missing[*]}")"; fi
# 一张都没有多半是连错了库；不带表名的 mysqldump 会导出整个库，所以直接失败。
if [ "${#present[@]}" -eq 0 ]; then log "action=check errorType=no_tables" >&2; exit 1; fi
# shellcheck disable=SC2016 # 同上。
docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysqldump -u"$MYSQL_USER" --single-transaction --quick --no-tablespaces --set-gtid-purged=OFF --hex-blob --default-character-set=utf8mb4 "$MYSQL_DATABASE" "$@"' sh "${present[@]}" | gzip -6 > "$partial"
# 压缩包完整且以 mysqldump 的结束标记收尾才算备份成功，中途断开的不留。
gzip -t "$partial"
if ! gzip -dc "$partial" | tail -n 1 | grep -q '^-- Dump completed'; then log "action=dump errorType=incomplete" >&2; exit 1; fi
mv "$partial" "$file"
log "action=dump file=$(basename "$file") bytes=$(stat -c %s "$file") tables=${#present[@]} seconds=$((SECONDS - started))"

# 轮换：文件名按时刻排序，只留最新 keep 份。
mapfile -t backups < <(find "$dir" -maxdepth 1 -name 'superxd-relay-*.sql.gz' -printf '%f\n' | sort)
removed=0
for ((index = 0; index < ${#backups[@]} - keep; index++)); do
  rm -f -- "$dir/${backups[index]}"
  removed=$((removed + 1))
done
log "action=rotate kept=$((${#backups[@]} - removed)) removed=$removed"

if [ -n "${BACKUP_UPLOAD_HOOK:-}" ]; then
  if ! "$BACKUP_UPLOAD_HOOK" "$file"; then log "action=upload errorType=hook_failed" >&2; exit 1; fi
  log "action=upload result=ok"
fi
