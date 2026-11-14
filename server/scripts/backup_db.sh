#!/usr/bin/env bash
# 中转库备份：在服务器上由 cron 每天跑一次（安装、恢复与演练见 server/README.md「备份与恢复」）。
# [人工决策-2026-11-10 13:12:22] 中转库备份（用户 11-10 确认方向）：只导长期数据——device、friendship 与节日抽奖三张表（reward_campaign、reward_prize、reward_draw）；
# 11-13 起按下面「新增长期保存的表加在这里」补进应用账号的三张表（app_account、account_identity、account_device）；
# 11-14 补进积分的两张表（points_grant、points_entry）与挑战的最好成绩 challenge_best；挑战的一局 challenge_run 结束 30 天就删，是短期数据，不导。
# 11-14 晚补进私信设备属于哪个应用账号的 account_social（随账号长期保存，丢了要重新接管）。
# message（30 天）与 chaoxing_pack（10 分钟）是短期数据，不导。用 mysqldump --single-transaction 在 InnoDB 一致性快照里导出，不锁表、不停服务；
# gzip 压缩，文件名带 UTC 时刻，按天跑、只留最新 BACKUP_KEEP 份（默认 14）。只存本机盘只防误删与库损坏，防不了整盘丢失；
# 异地存放的去处还没定（等用户选），先留可选的上传钩子 BACKUP_UPLOAD_HOOK：备份写好后以备份文件的绝对路径为参数调用它，失败则本脚本以非零退出。
# 备份里有还没发出的红包口令与二维码内容：目录与文件只给属主读写，传到异地前必须先加密。
# 密码不经命令行：在 mysql 容器里用容器自己的 MYSQL_USER、MYSQL_PASSWORD、MYSQL_DATABASE 环境变量连接。
# 用法：scripts/backup_db.sh。可选环境变量：BACKUP_DIR（默认 compose 目录下的 backups，相对路径按 compose 目录算）、BACKUP_KEEP、BACKUP_UPLOAD_HOOK；
# docker compose 自己的 COMPOSE_FILE、COMPOSE_PROJECT_NAME 照常生效（演练时指向临时库）。
set -euo pipefail

# 新增长期保存的表时加在这里，并同步 README「备份与恢复」。
tables=(device friendship reward_campaign reward_prize reward_draw app_account account_identity account_device points_grant points_entry challenge_best account_social)

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
docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysqldump -u"$MYSQL_USER" --single-transaction --quick --no-tablespaces --set-gtid-purged=OFF --hex-blob --default-character-set=utf8mb4 "$MYSQL_DATABASE" "$@"' sh "${tables[@]}" | gzip -6 > "$partial"
# 压缩包完整且以 mysqldump 的结束标记收尾才算备份成功，中途断开的不留。
gzip -t "$partial"
if ! gzip -dc "$partial" | tail -n 1 | grep -q '^-- Dump completed'; then log "action=dump errorType=incomplete" >&2; exit 1; fi
mv "$partial" "$file"
log "action=dump file=$(basename "$file") bytes=$(stat -c %s "$file") tables=${#tables[@]} seconds=$((SECONDS - started))"

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
