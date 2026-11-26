#!/usr/bin/env python3
# 星空素材包：把维护者本机素材工作目录里的竖屏母版（SuperXD-sky/final/<画风>_<时段>_master.png）压成手机用的 WebP，
# 文件名带内容哈希前 12 位，并打印要写进 lib/domain/sky.dart 登记表的那几行。
# 人工决策见 lib/domain/sky.dart 文件头：素材是第三方作品，不进公开仓库，只在维护者本机与中转；仓库里只登记文件名、大小与 SHA-256。
#
# 运行（在仓库根目录）：
#   python3 tool/sky_pack.py <素材目录>          默认 ~/Projects/SelfProjects/SuperXD-sky；产物写到 <素材目录>/pack
# 之后用 tool/sky_publish.sh 传到中转（用法见那个文件头）。
# 同一份母版重跑得到同样的文件（PIL 的 WebP 编码与 numpy 运算在同一版本下是确定的）；换了母版或参数就是新文件名，登记表要一起改。
# 依赖 Pillow 与 numpy。
import hashlib
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

# 手机竖屏 9:19.5（iPhone Pro Max 1290×2796），比它小的屏按铺满缩小。
WIDTH, HEIGHT = 1290, 2796
QUALITY = 86
STYLES = {'R': 'real', 'S': 'shinkai'}
PHASES = ['dawn', 'day', 'dusk', 'night', 'late']
# 减星（用户 11-26 看了模拟器上真实的夜说「画面有点杂」：满屏暗小星透过 65% 的卡片成了字后面的噪点）：
# 只压暗大量的暗小星、留下最亮的那些与银河的大结构，地平线以下不动。每项是（暗星留下的比例、原样保留的最亮像素占比 %、地平线的高度比例）；
# 没登记的（两张白天、新海诚的黎明、黄昏与夜）本来就干净，不处理。
STARS = {
    'R_dawn': (.25, .1, .5),
    'R_dusk': (.25, .1, .52),
    'R_night': (.2, .12, .8),
    'R_late': (.3, .12, .78),
    'S_late': (.35, .2, .64),
}


# 天文摄影常用的减星：开运算（先最小后最大，5 像素）去掉小于星点的亮细节得到底图，星点 = 原图 − 底图；
# 星点按亮度分档，暗的只留 remain，最亮的 keep_top% 原样留（中间平滑过渡）；从地平线往上 6% 的高度内渐变到不处理。
def reduce_stars(image, remain, keep_top, horizon, feather=.06):
    pixels = np.asarray(image, dtype=np.float32) / 255
    base = image.filter(ImageFilter.MinFilter(5)).filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.GaussianBlur(1.2))
    base = np.minimum(np.asarray(base, dtype=np.float32) / 255, pixels)
    stars = pixels - base
    brightness = stars @ np.array([.2126, .7152, .0722], dtype=np.float32)
    high = np.percentile(brightness, 100 - keep_top)
    low = high * .45
    t = np.clip((brightness - low) / (high - low), 0, 1)
    weight = remain + (1 - remain) * t * t * (3 - 2 * t)
    rows = np.arange(pixels.shape[0], dtype=np.float32) / pixels.shape[0]
    sky = np.clip((horizon - rows) / feather, 0, 1)[:, None]
    weight = 1 - (1 - weight) * sky
    result = base + stars * weight[..., None]
    return Image.fromarray(np.clip(result * 255 + .5, 0, 255).astype(np.uint8))


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
            if f'{key}_{phase}' in STARS:
                image = reduce_stars(image, *STARS[f'{key}_{phase}'])
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
