#!/usr/bin/env bash
# 电影院片源规则包的发布（人工决策见 lib/toolbox/cinema/cinema_service.dart 文件头：规则不进公开仓库）：维护者本机运行，规则包与签名私钥都不进仓库、不上服务器。
# 用法：RELAY_URL=<中转地址> RELAY_TARGET=<rsync 目标：主机:发布目录/> bash tool/cinema_publish.sh [规则包] [私钥.pem]
#   规则包默认 ~/.local/share/superxd-cinema/rules.json（写法见 lib/toolbox/cinema/cinema_rule.dart，每次发布 version 加一），
#   私钥默认 ~/.local/share/superxd-signing/content_signing_notes.pem（信件那把钥，能签 cinema）。
# 步骤：检查格式并签出 cinema.json → 按客户端内置公钥核对 → 确认中转已有 /v1/app/cinema → 上传（644，容器只读挂载） → 从公网取回与签好的逐字节比对。
# 客户端打开电影院时拉（两次至少隔一小时），版本只升不降。
set -euo pipefail
source=${1:-$HOME/.local/share/superxd-cinema/rules.json}
key=${2:-$HOME/.local/share/superxd-signing/content_signing_notes.pem}
: "${RELAY_URL:?要设 RELAY_URL（中转地址）}" "${RELAY_TARGET:?要设 RELAY_TARGET（rsync 目标）}"
export PUB_HOSTED_URL=https://pub.dev
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cd "$(dirname "$0")/.."

dart run tool/cinema_rules.dart --in "$source" --out "$out/cinema.json" --signing-key "$key"
dart run tool/content_signing.dart check-cinema "$out/cinema.json"
curl -fsS --max-time 30 -o /dev/null "$RELAY_URL/v1/app/cinema" || { echo '中转还没部署 /v1/app/cinema，先部署服务端（server/README.md 部署一节）' >&2; exit 1; }
rsync -t --chmod=F644 "$out/cinema.json" "$RELAY_TARGET"
curl -fsS --max-time 30 -o "$out/served.json" "$RELAY_URL/v1/app/cinema"
python3 -I -c 'import json, sys; built, served = (json.load(open(path, encoding="utf-8")) for path in sys.argv[1:3]); assert served.get("envelope") is not None, "中转返回里没有签名信封"; assert built == served, "中转上的 cinema.json 与签好的不一致"; print("[CinemaPublish] action=relay_check signed=true")' "$out/cinema.json" "$out/served.json"
