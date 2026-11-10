#!/usr/bin/env bash
# 从 backup_db.sh 的备份恢复长期数据（完整步骤与演练见 server/README.md「备份与恢复」）：先 docker compose stop relay，再跑本脚本，最后启动并核对。
# 备份里每张表是 DROP TABLE + CREATE TABLE + INSERT：只整表替换备份里的那几张，message 与 chaoxing_pack 不动；备份之后才有的设备与好友关系会丢。
# 导入前核对压缩包完整、以 mysqldump 的结束标记收尾，不完整的一律不导；要显式带 --yes 才执行。
# 密码不经命令行：在 mysql 容器里用容器自己的环境变量连接。docker compose 的 COMPOSE_FILE、COMPOSE_PROJECT_NAME 照常生效。
# 用法：scripts/restore_db.sh <备份文件.sql.gz> --yes
set -euo pipefail

log() { echo "[Restore] $* time=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }

if [ "$#" -ne 2 ] || [ "$2" != --yes ]; then echo "用法：scripts/restore_db.sh <备份文件.sql.gz> --yes" >&2; exit 2; fi
file=$(realpath -e "$1")
cd "$(dirname "$0")/.."

gzip -t "$file"
if ! gzip -dc "$file" | tail -n 1 | grep -q '^-- Dump completed'; then log "action=check file=$(basename "$file") errorType=incomplete" >&2; exit 1; fi
started=$SECONDS
# shellcheck disable=SC2016 # 变量要在容器里展开，用的是容器自己的环境变量。
gzip -dc "$file" | docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -u"$MYSQL_USER" --default-character-set=utf8mb4 "$MYSQL_DATABASE"'
log "action=restore file=$(basename "$file") seconds=$((SECONDS - started))"
