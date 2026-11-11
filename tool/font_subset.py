#!/usr/bin/env python3
# 字体裁剪：把内置的 Maple Mono NF CN 与按需下载的 Noto Serif SC 裁到 tool/font_charset.txt 的字符集，逐字节可复现。
# [人工决策-2026-11-10 13:15:54] 用户选定字体裁剪到常用汉字加拉丁字符（《通用规范汉字表》8105 字加界面用到的符号），
# 去掉 Maple 的 Nerd Font 图标（代码里没用到），集合外的生僻字回落系统字体；衬线字体不再随安装包，选用时再下载（见 lib/domain/font_pack.dart）。
# 没选可变字体（Flutter 不按 FontWeight 映射字重轴，守护在 test/code_conventions_test.dart），也没选只压缩不裁字（无损重编码不减体积）。
#
# 运行（在仓库根目录，一条命令；第一次会在 build/font_subset 建 venv、装固定版本的 fontTools，并下载原始字体）：
#   python3 tool/font_subset.py            裁剪，写 assets/fonts 的 Maple 三个字重与 font_packs 的衬线三个字重
#   python3 tool/font_subset.py charset    按 Unihan 与 lib 里的文字重新生成 tool/font_charset.txt（改了字符集要重跑上一条并换文件）
#   --sources <目录>                        原始文件放在别处时指定（默认 build/font_subset/sources，缺的才下载）
# 产物逐字节可复现：原始文件、字符集与 fontTools 版本都核对 SHA-256 或版本号，保存时不改时间戳、不重算外框；
# 同一份输入重跑后 git status 不应有变化。衬线包的文件名带内容哈希前 12 位，换了内容就是新文件名，lib/domain/font_pack.dart 的登记要一起改。
import hashlib
import io
import os
import subprocess
import sys
import unicodedata
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / 'build' / 'font_subset'
CHARSET = ROOT / 'tool' / 'font_charset.txt'
FONTTOOLS = '4.66.1'

# 原始字体（不入库）：地址、版本与 SHA-256。
MAPLE_ZIP = ('MapleMono-NF-CN.zip', 'https://github.com/subframe7536/maple-font/releases/download/v7.9/MapleMono-NF-CN.zip',
             'af913b6322905348b3f50e4397fedc35b3a880db5effcce7969003051dcd3e94')
# Maple Mono NF CN 7.900（发布 v7.9）：压缩包里三个字重的 SHA-256，同裁剪前随安装包的文件。
MAPLE = {
    'regular': ('MapleMono-NF-CN-Regular.ttf', 'bb8e8e8c263896f42555107202f1847f7a42c340a3e532df9c4d585c9794411c'),
    'medium': ('MapleMono-NF-CN-Medium.ttf', '6ffdd917c83f397ea021c96f23a54f23f5da835d75f8ddf77f8252ccb35d914f'),
    'semibold': ('MapleMono-NF-CN-SemiBold.ttf', '62a707a1c155e971055ce22bbdfacfa5bab50cd09d27bcb27e3ecbf1ac154aab'),
}
# Noto Serif SC 2.003 可变字体（google/fonts 提交 8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5）。
NOTO_VARIABLE = ('NotoSerifSC[wght].ttf', 'https://raw.githubusercontent.com/google/fonts/8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5/ofl/notoserifsc/NotoSerifSC%5Bwght%5D.ttf',
                 '050080d9255a86808f2945bffac582b31ef32bc36411ce29563b4961670c66f9')
# 先导出静态字重（同裁剪前随安装包的文件：fontTools 4.66.1 instancer、updateFontNames，修改时间取当时导出的值），核对 SHA-256 一致再裁剪。
NOTO = {
    'regular': (400, 3873870525, 'c6703a84c9fc049f8c528f4ac0680fa19907d79cf627724a5ed21ca9199f1440'),
    'medium': (500, 3873870585, '7e2e4943ef89ed89ddd97558f76aff7ef72a1f39d85014ece03df28125d6c02a'),
    'semibold': (600, 3873870600, '738b5fab642d8cf91769e57c06323cde6dc268a153cd5cf2e370ae10c37ee91e'),
}
# 《通用规范汉字表》取自 Unihan 的 kTGH 字段（值为「2013:序号」，共 8105 字）。
UNIHAN = ('Unihan.zip', 'https://www.unicode.org/Public/17.0.0/ucd/Unihan.zip', 'f7a48b2b545acfaa77b2d607ae28747404ce02baefee16396c5d2d7a8ef34b5e')
# 字符集文件（连同说明行）的 SHA-256：重新生成字符集后改这里。
CHARSET_SHA256 = '4d71fc2db4557c37853fb96f77c7d92d204abf287b0d9e9216d62c454080e88e'

# 界面里用得到的非汉字区段（含两端）：生僻的整区不收，常用的整区收下，字体里没有的码位裁剪时自然跳过。
SYMBOL_RANGES = [
    (0x0020, 0x007E, '基本拉丁'),
    (0x00A0, 0x00FF, '拉丁补充'),
    (0x0100, 0x017F, '拉丁扩展 A'),
    (0x01CD, 0x01DC, '拼音声调字母'),
    (0x01F8, 0x01F9, '拼音声调字母'),
    (0x0251, 0x0251, '拼音 ɑ'),
    (0x0261, 0x0261, '拼音 ɡ'),
    (0x02B0, 0x02FF, '间距修饰符（注音声调等）'),
    (0x0391, 0x03A9, '希腊大写'),
    (0x03B1, 0x03C9, '希腊小写'),
    (0x0401, 0x0401, '西里尔 Ё'),
    (0x0410, 0x044F, '西里尔'),
    (0x0451, 0x0451, '西里尔 ё'),
    (0x1E3E, 0x1E3F, '拼音 ḿ'),
    (0x2000, 0x206F, '常用标点'),
    (0x2070, 0x209F, '上标与下标'),
    (0x20A0, 0x20CF, '货币'),
    (0x2100, 0x214F, '类字母符号（℃ № ™）'),
    (0x2150, 0x218F, '数字形式（Ⅰ Ⅱ ⅰ）'),
    (0x2190, 0x21FF, '箭头'),
    (0x2200, 0x22FF, '数学运算符'),
    (0x2300, 0x23FF, '杂项技术符号'),
    (0x2460, 0x24FF, '带圈字母数字（①）'),
    (0x2500, 0x259F, '制表符与方块'),
    (0x25A0, 0x25FF, '几何图形'),
    (0x2600, 0x26FF, '杂项符号（★ ♪）'),
    (0x2700, 0x27BF, '装饰符号（✓ ✕）'),
    (0x3000, 0x303F, '中日韩符号与标点'),
    (0x3040, 0x30FF, '平假名与片假名'),
    (0x3100, 0x312F, '注音符号'),
    (0x3200, 0x32FF, '带圈或括号的中日韩字符（㈠ ㊣）'),
    (0x3380, 0x33DF, '中日韩兼容单位（㎡ ㎏）'),
    (0xFE30, 0xFE4F, '中日韩兼容形式'),
    (0xFE50, 0xFE6F, '小写变体'),
    (0xFF00, 0xFFEF, '半角与全角'),
    (0xFFFD, 0xFFFD, '替换字符'),
]
# FreeType 自动微调（autofit，安卓与 Flutter 测试画没有微调指令的汉字时用）算中日韩字的基准线与标准笔画宽用到的参考字：
# afblue.dat 的 CJK 四组与 afscript.h 里 hani 的标准字「田 囗」（FreeType VER-2-13-3，
# https://gitlab.freedesktop.org/freetype/freetype/-/raw/VER-2-13-3/src/autofit/afblue.dat，SHA-256 3c48ae2da14b128767d1d7a89997e6367057415997aede34be382a04b6e68c80）。
# 缺了其中的繁体字，算出的基准线会变，汉字灰度边缘差一两个像素（裁剪前后的预览图对比查出），所以一并收下。
AUTOHINT_CHARS = '他们你來們到和地对對就席我时時會来為能舰說说这這齊军同已愿既星是景民照现現理用置要軍那配里開雷露面顾个为人以個大有主些因它想意生當看着者自著裡过还进進過道還她将將年得情最样樣通即吗吧听呢品响嗎师師收断斷明眼間间际陈限除陳随際隨事前學或政斯新沒没然特球第經谁起例別别制动動增指朝期构物确种調调費费都田囗'
# 生成字符集时一并扫描的界面文字：lib 下的源码（含注释，比只取字符串多收不多几个字）与界面里直接显示的文本文件。
SCANNED = ['lib', 'assets/third_party_notices.txt', 'assets/fonts/LICENSE.txt', 'assets/fonts/noto_serif_sc_license.txt', 'LICENSE']


def log(message):
    print(f'[FontSubset] {message}', flush=True)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# 不在固定版本的 fontTools 下就建 venv 装上再用它重跑自己（只装 fontTools，不装 uharfbuzz 等会改变产物的可选加速）。
def ensure_fonttools():
    try:
        import fontTools
        if fontTools.version == FONTTOOLS:
            return
    except ImportError:
        pass
    venv = WORK / 'venv'
    python = venv / 'bin' / 'python'
    # venv 里的 python 是指向系统 python 的链接，按 sys.prefix 认是不是已经在 venv 里。
    if Path(sys.prefix).resolve() == venv.resolve():
        sys.exit(f'venv 里的 fontTools 不是 {FONTTOOLS}，删掉 {venv} 重跑')
    if not python.exists():
        log(f'action=venv path={venv}')
        subprocess.run([sys.executable, '-m', 'venv', str(venv)], check=True)
        subprocess.run([str(python), '-m', 'pip', 'install', '--quiet', f'fonttools=={FONTTOOLS}'], check=True)
    os.execv(str(python), [str(python), '-I', str(Path(__file__).resolve()), *sys.argv[1:]])


# 原始文件：缺了就下载，在与不在都核对 SHA-256，对不上就停。
def source(directory, entry):
    name, url, digest = entry
    path = directory / name
    if not path.exists():
        directory.mkdir(parents=True, exist_ok=True)
        log(f'action=download file={name}')
        partial = path.with_name(name + '.part')
        with urllib.request.urlopen(url, timeout=60) as response, open(partial, 'wb') as out:
            while chunk := response.read(1 << 20):
                out.write(chunk)
        partial.rename(path)
    data = path.read_bytes()
    if sha256(data) != digest:
        sys.exit(f'{name} 的 SHA-256 对不上（{sha256(data)}），删掉 {path} 重下或核对版本')
    return data


def read_charset():
    data = CHARSET.read_bytes()
    if sha256(data) != CHARSET_SHA256:
        sys.exit(f'{CHARSET.relative_to(ROOT)} 的 SHA-256 是 {sha256(data)}，与脚本里的 CHARSET_SHA256 不一致：确认改动后更新 CHARSET_SHA256')
    return {int(line.split('\t')[0][2:], 16) for line in data.decode('utf-8').splitlines() if line.startswith('U+')}


def subset(font_bytes, unicodes):
    from fontTools import subset as fonttools_subset
    from fontTools.ttLib import TTFont
    options = fonttools_subset.Options()
    # 保留全部排版特性、文字方向、名字表与提示（hinting），不重算外框、平均字宽、码位范围与时间戳：只去掉集合外的字形，度量与排版和裁剪前一致。
    options.layout_features = ['*']
    options.layout_scripts = ['*']
    options.name_IDs = ['*']
    options.name_languages = ['*']
    options.name_legacy = True
    options.legacy_cmap = True
    options.notdef_glyph = True
    options.notdef_outline = True
    options.hinting = True
    options.legacy_kern = True
    options.recalc_bounds = False
    options.recalc_timestamp = False
    options.recalc_average_width = False
    options.recalc_max_context = False
    options.prune_unicode_ranges = False
    options.prune_codepage_ranges = False
    options.harfbuzz_repacker = False
    # meta（设计语言标记）不引用字形，原样保留。
    options.no_subset_tables = options.no_subset_tables + ['meta']
    font = TTFont(io.BytesIO(font_bytes), recalcBBoxes=False, recalcTimestamp=False)
    subsetter = fonttools_subset.Subsetter(options=options)
    subsetter.populate(unicodes=unicodes)
    subsetter.subset(font)
    out = io.BytesIO()
    font.save(out)
    return out.getvalue()


def noto_static(variable_bytes, weight, modified):
    from fontTools.ttLib import TTFont
    from fontTools.varLib import instancer
    font = instancer.instantiateVariableFont(TTFont(io.BytesIO(variable_bytes)), {'wght': weight}, updateFontNames=True)
    font['head'].modified = modified
    font.recalcTimestamp = False
    out = io.BytesIO()
    font.save(out)
    return out.getvalue()


def build(sources):
    unicodes = read_charset()
    log(f'action=charset codepoints={len(unicodes)}')
    outputs = []
    with zipfile.ZipFile(io.BytesIO(source(sources, MAPLE_ZIP))) as archive:
        for weight, (member, digest) in MAPLE.items():
            original = archive.read(member)
            if sha256(original) != digest:
                sys.exit(f'{member} 的 SHA-256 对不上')
            target = ROOT / 'assets' / 'fonts' / f'maple_mono_nf_cn_{weight}.ttf'
            outputs.append((target, len(original), subset(original, unicodes)))
    variable = source(sources, NOTO_VARIABLE)
    packs = ROOT / 'font_packs'
    for weight, (value, modified, digest) in NOTO.items():
        static = noto_static(variable, value, modified)
        if sha256(static) != digest:
            sys.exit(f'Noto Serif SC {weight} 导出的静态字重与裁剪前的文件不一致（{sha256(static)}）')
        data = subset(static, unicodes)
        outputs.append((packs / f'noto_serif_sc_{weight}-{sha256(data)[:12]}.ttf', len(static), data))
    packs.mkdir(exist_ok=True)
    for target, before, data in outputs:
        target.write_bytes(data)
        log(f'action=write file={target.relative_to(ROOT)} before={before} after={len(data)} sha256={sha256(data)}')
    stale = sorted(path.name for path in packs.glob('*.ttf') if path not in [target for target, _, _ in outputs])
    if stale:
        log(f'action=stale files={",".join(stale)}（旧版本：还在支持的旧客户端可能要下载，按 lib/domain/font_pack.dart 的说明决定何时删）')


def generate_charset(sources):
    tgh = set()
    with zipfile.ZipFile(io.BytesIO(source(sources, UNIHAN))) as archive:
        for line in archive.read('Unihan_OtherMappings.txt').decode('utf-8').splitlines():
            parts = line.split('\t')
            if len(parts) == 3 and parts[1] == 'kTGH':
                tgh.add(int(parts[0][2:], 16))
    if len(tgh) != 8105:
        sys.exit(f'kTGH 有 {len(tgh)} 字，不是 8105')
    symbols = {code for start, end, _ in SYMBOL_RANGES for code in range(start, end + 1)}
    autohint = {ord(char) for char in AUTOHINT_CHARS}
    scanned = set()
    for entry in SCANNED:
        path = ROOT / entry
        for file in sorted(path.rglob('*.dart')) if path.is_dir() else [path]:
            scanned.update(ord(char) for char in file.read_text(encoding='utf-8'))
    # 控制字符、私用区（图标）与代理码位不进字体。
    scanned = {code for code in scanned if unicodedata.category(chr(code)) not in ('Cc', 'Co', 'Cs')}
    codes = sorted(tgh | symbols | autohint | scanned)
    extra = sorted(scanned - tgh - symbols - autohint)
    header = [
        '# 字体裁剪的字符集：tool/font_subset.py 用它裁剪 Maple Mono NF CN 与 Noto Serif SC（python3 tool/font_subset.py charset 重新生成）。',
        f'# 1. 《通用规范汉字表》（2013）{len(tgh)} 字：Unicode 17.0.0 Unihan 数据库 Unihan_OtherMappings.txt 的 kTGH 字段，',
        f'#    {UNIHAN[1]}（SHA-256 {UNIHAN[2]}）。',
        '# 2. 界面符号：tool/font_subset.py 的 SYMBOL_RANGES 列出的区段（基本拉丁、拉丁补充、标点、全角、中日韩标点、数字形式、货币、箭头等）。',
        f'# 3. FreeType 自动微调算中日韩基准线用到的参考字（tool/font_subset.py 的 AUTOHINT_CHARS），不在第 1 项里的 {len(autohint - tgh)} 个（多是繁体）。',
        f'# 4. lib 源码与界面显示的文本文件里出现、又不在上几项里的字符（生成时扫描）：{len(extra)} 个。',
        f'# 共 {len(codes)} 个码位，一行一个：码位、制表符、字符（空白与组合字符不写字符）。本文件的 SHA-256 记在 tool/font_subset.py 的 CHARSET_SHA256。',
    ]
    lines = []
    for code in codes:
        char = chr(code)
        printable = unicodedata.category(char)[0] not in ('Z', 'M', 'C')
        lines.append(f'U+{code:04X}\t{char}' if printable else f'U+{code:04X}')
    data = ('\n'.join(header + lines) + '\n').encode('utf-8')
    CHARSET.write_bytes(data)
    log(f'action=charset codepoints={len(codes)} tgh={len(tgh)} symbols={len(symbols)} autohint={len(autohint - tgh)} extra={len(extra)} sha256={sha256(data)}')


def main():
    args = sys.argv[1:]
    sources = WORK / 'sources'
    if '--sources' in args:
        index = args.index('--sources')
        sources = Path(args[index + 1]).resolve()
        del args[index:index + 2]
    if args == ['charset']:
        generate_charset(sources)
        return
    if args:
        sys.exit('用法见文件头')
    ensure_fonttools()
    build(sources)


if __name__ == '__main__':
    main()
