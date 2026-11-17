#!/usr/bin/env bash
# 中转看门狗：docker 不会重启 unhealthy 的容器（restart 只管进程退出），由 root 的 crontab 每分钟跑一次本脚本（安装见 server/README.md「探活与告警」）。
# [人工决策-2026-11-17 21:24:25] unhealthy 自动重启（用户同意审查建议 P2-7）：中转容器 unhealthy（就绪探测连续 3 次失败，约一分半）且 MySQL、Redis 都 healthy 时，
# 问题在中转自己（连接池卡死、内存将满），重启中转；依赖本身不健康时重启中转没用，只记一行、等依赖恢复。MySQL 与 Redis 不由这里重启（崩溃恢复中被重启更糟）。
# 两次重启至少隔 WATCHDOG_COOLDOWN 秒（默认 600），防止反复重启。没选 autoheal 一类的容器：要把 docker.sock 挂进去（等于 root 权限）、还多一个第三方镜像。
# 一切正常时什么也不写；同一种情况只在变化时记一行（日志按事件增长，不按分钟）。状态在 WATCHDOG_STATE_DIR（默认 /var/lib/superxd-relay-watchdog）。
# 用法：* * * * * /opt/superxd-relay/scripts/relay_watchdog.sh >> /var/log/superxd-relay-watchdog.log 2>&1
# docker compose 自己的 COMPOSE_FILE、COMPOSE_PROJECT_NAME 照常生效（演练时指向临时的 compose）。
set -euo pipefail

log() { echo "[Watchdog] $* time=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }

cd "$(dirname "$0")/.."
state_dir=${WATCHDOG_STATE_DIR:-/var/lib/superxd-relay-watchdog}
cooldown=${WATCHDOG_COOLDOWN:-600}
mkdir -p "$state_dir"

health() {
  local id
  id=$(docker compose ps -q "$1")
  if [ -z "$id" ]; then echo missing; return; fi
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id"
}

# 只在情况变了时记一行。
note() {
  local previous
  previous=$(cat "$state_dir/note" 2> /dev/null || true)
  if [ "$previous" != "$1" ]; then log "$1"; fi
  printf '%s\n' "$1" > "$state_dir/note"
}

relay=$(health relay)
if [ "$relay" != unhealthy ]; then
  note "action=watch relay=$relay"
  exit 0
fi
mysql=$(health mysql)
redis=$(health redis)
if [ "$mysql" != healthy ] || [ "$redis" != healthy ]; then
  note "action=skip relay=unhealthy mysql=$mysql redis=$redis"
  exit 0
fi
now=$(date +%s)
last=$(cat "$state_dir/last_restart" 2> /dev/null || echo 0)
if (( now - last < cooldown )); then
  note "action=cooldown relay=unhealthy"
  exit 0
fi
printf '%s\n' "$now" > "$state_dir/last_restart"
note "action=restart relay=unhealthy mysql=healthy redis=healthy"
docker compose restart relay
