#!/usr/bin/env bash
# 灰度配置的发布（人工决策见 lib/domain/rollout.dart 文件头 11-16 那两条）：维护者本机运行，配置与签名私钥都不进仓库、不上服务器。
# 用法：RELAY_URL=<中转地址> RELAY_TARGET=<rsync 目标：主机:发布目录/> bash tool/rollout_publish.sh [配置文件] [私钥.pem]
#   配置文件默认 ~/.local/share/superxd-rollout/rollout.json（写法见 tool/rollout_config.dart 文件头），
#   私钥默认 ~/.local/share/superxd-signing/content_signing_notes.pem（信件那把钥，能签 rollout）。
# 步骤：检查格式 → 签出第 2 版 flags.json 与第 1 版 rollout.json 并按客户端内置公钥核对 → 确认中转已有 /v1/app/flags →
#   两份一起上传（644，容器只读挂载） → 从公网取回与签好的逐字节比对。客户端一小时内、回到前台时生效。
set -euo pipefail
source=${1:-$HOME/.local/share/superxd-rollout/rollout.json}
key=${2:-$HOME/.local/share/superxd-signing/content_signing_notes.pem}
: "${RELAY_URL:?要设 RELAY_URL（中转地址）}" "${RELAY_TARGET:?要设 RELAY_TARGET（rsync 目标）}"
export PUB_HOSTED_URL=https://pub.dev
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cd "$(dirname "$0")/.."

dart run tool/rollout_config.dart --in "$source" --out-dir "$out" --signing-key "$key"
dart run tool/content_signing.dart check-flags "$out/flags.json"
dart run tool/content_signing.dart check-rollout "$out/rollout.json"
curl -fsS --max-time 30 -o /dev/null "$RELAY_URL/v1/app/flags" || { echo '中转还没部署 /v1/app/flags，先部署服务端（server/README.md 部署一节）' >&2; exit 1; }
rsync -t --chmod=F644 "$out/flags.json" "$out/rollout.json" "$RELAY_TARGET"
for name in flags rollout; do
  curl -fsS --max-time 30 -o "$out/served_$name.json" "$RELAY_URL/v1/app/$name"
  python3 -I -c 'import json, sys; built, served = (json.load(open(path, encoding="utf-8")) for path in sys.argv[1:3]); assert served.get("envelope") is not None, "中转返回里没有签名信封"; assert built == served, "中转上的 %s 与签好的不一致" % sys.argv[3]; print("[RolloutPublish] action=relay_check file=%s signed=true" % sys.argv[3])' "$out/$name.json" "$out/served_$name.json" "$name"
done
