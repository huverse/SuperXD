#!/usr/bin/env bash
# 中转 HTTPS 证书（人工决策见 docker-compose.yml 的 tls）：Let's Encrypt 公网 IP 证书，shortlived 档（160 小时），webroot 验证（经 80 端口）。
# 用法（在部署目录 /opt/superxd-relay 下，root）：
#   scripts/tls_cert.sh issue <公网 IP>   第一次：没有证书时先放一张占位的自签证书让 Nginx 起来，再签发、装好、Nginx 重读
#   scripts/tls_cert.sh renew            root 的 crontab 每天跑一次：acme.sh 剩 3 天时续（--days 3），续了才让 Nginx 重读
#   scripts/tls_cert.sh status           打印现在这张证书的签发者、到期时间与 IP
# 续不上时 acme.sh 会在日志里写原因；外部探活（relay-health.yml）在证书剩不到 3 天时失败并发邮件，给三天时间处理。
set -euo pipefail
cd "$(dirname "$0")/.."

log() { echo "[TlsCert] $* time=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
acme() { docker compose run --rm -T acme "$@"; }
has_cert() { docker compose run --rm -T --entrypoint sh acme -c 'test -s /out/fullchain.pem && test -s /out/key.pem'; }
reload() { docker compose exec -T tls nginx -s reload; }

case "${1:-}" in
  issue)
    ip=${2:?用法: scripts/tls_cert.sh issue <公网 IP>}
    if ! has_cert; then
      log "action=placeholder"
      docker compose run --rm -T --entrypoint sh acme -c "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj /CN=placeholder -keyout /out/key.pem -out /out/fullchain.pem 2> /dev/null"
    fi
    docker compose up -d --no-deps tls
    acme --set-default-ca --server letsencrypt > /dev/null
    acme --issue --server letsencrypt --cert-profile shortlived -d "$ip" --webroot /webroot --days 3 --keylength ec-256
    acme --install-cert -d "$ip" --ecc --fullchain-file /out/fullchain.pem --key-file /out/key.pem
    reload
    log "action=issued ip=$ip"
    ;;
  renew)
    before=$(docker compose run --rm -T --entrypoint sh acme -c 'sha256sum /out/fullchain.pem' | cut -d' ' -f1)
    acme --cron
    after=$(docker compose run --rm -T --entrypoint sh acme -c 'sha256sum /out/fullchain.pem' | cut -d' ' -f1)
    if [ "$before" != "$after" ]; then
      reload
      log "action=renewed"
    else
      log "action=checked"
    fi
    ;;
  status)
    docker compose run --rm -T --entrypoint sh acme -c 'openssl x509 -in /out/fullchain.pem -noout -issuer -enddate -ext subjectAltName'
    ;;
  *)
    echo "用法: scripts/tls_cert.sh issue <公网 IP> | renew | status" >&2
    exit 2
    ;;
esac
