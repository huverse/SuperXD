#!/usr/bin/env python3
# 星空素材包：把维护者本机素材工作目录里的竖屏母版（SuperXD-sky/final/<画风>_<时段>_master.png）压成手机用的 WebP，
# 文件名带内容哈希前 12 位，并打印要写进 lib/domain/sky.dart 登记表的那几行。
# 人工决策见 lib/domain/sky.dart 文件头：素材是第三方作品，不进公开仓库，只在维护者本机与中转；仓库里只登记文件名、大小与 SHA-256。
#
# 运行（在仓库根目录）：
#   python3 tool/sky_pack.py <素材目录>          默认 ~/Projects/SelfProjects/SuperXD-sky；产物写到 <素材目录>/pack
# 之后用 tool/sky_publish.sh 传到中转（用法见那个文件头）。
# 同一份母版重跑得到同样的文件（PIL 的 WebP 编码在同一版本下是确定的）；换了母版就是新文件名，登记表要一起改。
import hashlib
import sys
from pathlib import Path

from PIL import Image

# 手机竖屏 9:19.5（iPhone Pro Max 1290×2796），比它小的屏按铺满缩小。
WIDTH, HEIGHT = 1290, 2796
QUALITY = 86
STYLES = {'R': 'real', 'S': 'shinkai'}
PHASES = ['dawn', 'day', 'dusk', 'night', 'late']


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else Path.home() / 'Projects/SelfProjects/SuperXD-sky')
    out = root / 'pack'
    out.mkdir(exist_ok=True)
    for old in out.glob('*.webp'):
        old.unlink()
    Image.MAX_IMAGE_PIXELS = None
    for key, style in STYLES.items():
        print(f"  '{style}': SkyPack(style: SkyStyle.{style}, files: [")
        for phase in PHASES:
            master = Image.open(root / 'final' / f'{key}_{phase}_master.png').convert('RGB')
            # 母版已是 9:19.5，铺满后居中裁掉取整误差。
            scale = max(WIDTH / master.width, HEIGHT / master.height)
            size = (round(master.width * scale), round(master.height * scale))
            image = master.resize(size, Image.LANCZOS)
            left, top = (size[0] - WIDTH) // 2, (size[1] - HEIGHT) // 2
            image = image.crop((left, top, left + WIDTH, top + HEIGHT))
            temp = out / f'{style}_{phase}.tmp.webp'
            image.save(temp, 'WEBP', quality=QUALITY, method=6)
            data = temp.read_bytes()
            digest = hashlib.sha256(data).hexdigest()
            name = f'sky_{style}_{phase}-{digest[:12]}.webp'
            temp.rename(out / name)
            print(f"    SkyFile(phase: SkyPhase.{phase}, name: '{name}', size: {len(data)}, sha256: '{digest}'),")
        print('  ]),')


if __name__ == '__main__':
    main()
