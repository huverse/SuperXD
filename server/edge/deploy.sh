#!/usr/bin/env bash
# 部署电影院的境外转发（Cloudflare Worker，人工决策见同目录 cinema_forward.ts 文件头），维护者本机运行：
#   server/edge/deploy.sh [配置文件]
# 配置文件放在仓库外（默认 ~/.local/share/superxd-cinema/edge.env），两行 shell 赋值：
#   FORWARD_HOST=转发用的域名（要在 Cloudflare 上托管；workers.dev 在国内被封）
#   ALLOWED_HOSTS=逗号分隔的片源站接口主机（跟着签名的片源规则包里标了 forward 的源改，改完重新部署）
# 第一次先登录：npx --yes wrangler@4.162.0 login。部署后按 server/README.md「电影院的境外转发」从国内的中转核对。
# wrangler.toml 现生成在临时目录（域名与白名单不进公开仓库），不开 workers.dev 与预览地址，不开 observability（不记日志）。
set -euo pipefail

config=${1:-$HOME/.local/share/superxd-cinema/edge.env}
# shellcheck source=/dev/null
source "$config"
: "${FORWARD_HOST:?配置文件里要有 FORWARD_HOST}" "${ALLOWED_HOSTS:?配置文件里要有 ALLOWED_HOSTS}"

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/wrangler.toml" <<TOML
name = "superxd-cinema-forward"
main = "$here/cinema_forward.ts"
compatibility_date = "2026-11-01"
workers_dev = false
preview_urls = false
routes = [{ pattern = "$FORWARD_HOST", custom_domain = true }]

[vars]
ALLOWED_HOSTS = "$ALLOWED_HOSTS"

[observability]
enabled = false

# 每个 IP 每分钟最多 120 次（一次搜索最多十几个源，够用；挡住拿它当通用代理刷）。
[[ratelimits]]
name = "LIMITER"
namespace_id = "1001"
simple = { limit = 120, period = 60 }
TOML

# 在临时目录里跑：wrangler 会在当前目录留 .wrangler 缓存，别落在仓库里。
cd "$work"
npx --yes wrangler@4.162.0 deploy --config "$work/wrangler.toml"
