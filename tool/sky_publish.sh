#!/usr/bin/env bash
# 星空背景素材的发布（人工决策见 lib/domain/sky.dart 文件头：素材是第三方作品，不进公开仓库，只在维护者本机与中转）：维护者本机运行。
# 用法：RELAY_URL=<中转地址> RELAY_TARGET=<rsync 目标：主机:发布目录/> bash tool/sky_publish.sh [素材目录]
#   素材目录默认 ~/Projects/SelfProjects/SuperXD-sky，先用 python3 tool/sky_pack.py 生成 pack/ 下的 WebP 并把打印的登记行写进 lib/domain/sky.dart。
# 步骤：核对 pack 里的文件与 lib/domain/sky.dart 登记的名字、大小、SHA-256 一一对得上 → 传到中转的发布目录（644，同名不覆盖：文件名带内容哈希，同名即同一份）
# → 从公网逐个取回、核对 SHA-256。发版流水线清理发布目录时保护 sky_*.webp（.github/workflows/release.yml），不会被当旧文件删掉。
set -euo pipefail
root=${1:-$HOME/Projects/SelfProjects/SuperXD-sky}
: "${RELAY_URL:?要设 RELAY_URL（中转地址）}" "${RELAY_TARGET:?要设 RELAY_TARGET（rsync 目标）}"
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# 登记表：lib/domain/sky.dart 里每一行 SkyFile 的名字、大小与 SHA-256。
python3 -I - "$root/pack" lib/domain/sky.dart > "$out/files.txt" <<'EOF'
import hashlib, re, sys
from pathlib import Path
pack, registry = Path(sys.argv[1]), Path(sys.argv[2]).read_text(encoding='utf-8')
entries = re.findall(r"SkyFile\(phase: SkyPhase\.\w+, name: '([^']+)', size: (\d+), sha256: '([0-9a-f]{64})'\)", registry)
assert entries, 'lib/domain/sky.dart 里没有登记的星空素材'
for name, size, digest in entries:
    data = (pack / name).read_bytes()
    assert len(data) == int(size) and hashlib.sha256(data).hexdigest() == digest, f'{name} 与登记的大小或 SHA-256 对不上'
    print(name, digest)
EOF
mapfile -t files < <(cut -d' ' -f1 "$out/files.txt" | sed "s#^#$root/pack/#")
rsync -t --chmod=F644 --ignore-existing "${files[@]}" "$RELAY_TARGET"
while read -r name digest; do
  curl -fsS --max-time 120 -o "$out/served" "$RELAY_URL/v1/app/files/$name"
  served=$(sha256sum "$out/served" | cut -d' ' -f1)
  if [ "$served" != "$digest" ]; then echo "中转上的 $name 与登记的不一致" >&2; exit 1; fi
  echo "[SkyPublish] action=relay_check file=$name"
done < "$out/files.txt"
