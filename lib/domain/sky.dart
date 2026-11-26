import 'dart:math' as math;

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/download_pack.dart';

// 星空背景：外观页背景的第三种（云雾、星空、自定义图片），按一天里的时段换五幕画面，几幕之间按真实的太阳高度慢慢过渡。
// [人工决策-2026-11-26 20:33:55] 用户提出把星空与宇宙放进应用并选定（宣传片之后的想法，原话「SuperXD始终是一个艺术品」）：
// 星空模式固定深色（没选跟着天色、仍按设置的深浅色）；外观页背景多一个「星空」，云雾仍是默认（没选设为新默认、灰度放量）；
// 开屏到主页做成「一笔画」：从地平线一笔写出签名、化成星光，镜头上摇，界面在同一片天里升起（没选原地浮现、保留开屏画作；开屏另做）。
// [人工决策-2026-11-26 20:55:20] 星空模式下卡片透一些（约 65% 不透明、不加模糊，用户看了 91/78/65 三档对比图选的；没选照旧 91%），
// 银河与亮星从卡片里隐约透出；按真实时段算的地点是济南（城市级经纬度，见 skyLatitude）。
// [人工决策-2026-11-26 21:18:06] 画面改用好看的现成作品（用户看了程序渲染的几版说「很不好看」，要艺术品）：天体位置不再按真实计算，
// 只保留真实时段（按济南真实的日出日落决定现在是哪一幕、何时过渡，见 skyMoment）；画里的星空用作品本身的，以后只叠极淡的闪烁与偶尔的流星；
// 动起来用高清静图加局部动态（云、水波、星光用 Muse 视频叠回，用户生成）。取代 20:33:55 那条里「天体按真实位置算」的画法。
// [人工决策-2026-11-26 21:03:04] 星空不只一种（用户原话「每个人心中都有一片承载着梦想的星空」）：分画风，先做真实（摄影）与新海诚（动画），
// 天体与时段口径相同、只有画法不同，以后可加（没选「属于自己的一颗星」）。
// [人工决策-2026-11-26 21:38:00] 十幅画面用户看了候选板后全部采用推荐（每个画风黎明、白天、黄昏、夜、深夜各一幅，出处记在维护者本机的
// SuperXD-sky/notes/sources.json 与开源许可第七节）。
// [人工决策-2026-11-26 21:42:06] 素材按需下载（用户选，同衬线字体包；没选静图打包、全部打包）：外观页选了星空与某个画风才下那一套，原地显示进度、可取消，
// 下好才换上；我按最佳实践定：素材是第三方作品，不进公开仓库（同电影院的规则包），仓库只登记文件名、大小与 SHA-256，
// 图片由维护者本机 tool/sky_pack.py 打包、tool/sky_publish.sh 传到中转（文件名带内容哈希，换了画面就是新文件，登记表一起改）。

enum SkyStyle {
  real('真实'),
  shinkai('新海诚');

  const SkyStyle(this.label);
  final String label;
  // 存进显示设置、作素材包 id 的名字（发出后不改）。
  String get id => name;
}

enum SkyPhase { dawn, day, dusk, night, late }

class SkyFile extends PackFile {
  const SkyFile({required this.phase, required super.name, required super.size, required super.sha256});
  final SkyPhase phase;
}

class SkyPack implements DownloadPack {
  const SkyPack({required this.style, required this.files});
  final SkyStyle style;
  @override
  String get id => style.id;
  @override
  final List<SkyFile> files;
  SkyFile fileOf(SkyPhase phase) => files.firstWhere((file) => file.phase == phase);
}

// 竖屏 1290×2796 的 WebP（tool/sky_pack.py 生成），每个画风一幅一时段。
const skyPacks = <String, SkyPack>{
  'real': SkyPack(style: SkyStyle.real, files: [
    SkyFile(phase: SkyPhase.dawn, name: 'sky_real_dawn-8beeddfe0040.webp', size: 892660, sha256: '8beeddfe0040ac4cfea4cbe3f6d813ea4f98d77b3ed8f44ed528d3c9863ebf79'),
    SkyFile(phase: SkyPhase.day, name: 'sky_real_day-91be9e24de9a.webp', size: 63950, sha256: '91be9e24de9a326ec89dd573991b100ee78a3f7d33fb197ad8053f8c09c6065c'),
    SkyFile(phase: SkyPhase.dusk, name: 'sky_real_dusk-b7b43a8711ce.webp', size: 776186, sha256: 'b7b43a8711ce02f55a476c4b7719d2f994adba67632ea8bec072973c76e4f1e0'),
    SkyFile(phase: SkyPhase.night, name: 'sky_real_night-ae34f8819f18.webp', size: 1014082, sha256: 'ae34f8819f186538e13682ef8c6bcdd0e54da84dc5bb2b2e085873c41b752baf'),
    SkyFile(phase: SkyPhase.late, name: 'sky_real_late-8b3f12a0847a.webp', size: 949694, sha256: '8b3f12a0847a73266cd462bd259386f8c11907faf12c2367ad2cc65a34970b2c'),
  ]),
  'shinkai': SkyPack(style: SkyStyle.shinkai, files: [
    SkyFile(phase: SkyPhase.dawn, name: 'sky_shinkai_dawn-cbc8a8f94f5c.webp', size: 98788, sha256: 'cbc8a8f94f5cae21bfbae8be9f48b839473fef951a13992b475599d4f295b275'),
    SkyFile(phase: SkyPhase.day, name: 'sky_shinkai_day-7a05ae90057d.webp', size: 370464, sha256: '7a05ae90057d5aeeb75285d1b7dd29cbd20e0a1905de0705ee738891ecd1b94a'),
    SkyFile(phase: SkyPhase.dusk, name: 'sky_shinkai_dusk-57d719aa4d5b.webp', size: 85794, sha256: '57d719aa4d5bef805c41e52be1bec0094734727c0fbe0a88acf7d14ba9ee0e16'),
    SkyFile(phase: SkyPhase.night, name: 'sky_shinkai_night-d8056401a3f5.webp', size: 174534, sha256: 'd8056401a3f5a5f2aea722056062f28541ea8d12af1a98ee2586c34d275b189d'),
    SkyFile(phase: SkyPhase.late, name: 'sky_shinkai_late-7d388475988d.webp', size: 359090, sha256: '7d388475988d733f46d14177734e9f006e0ae0043fb751bcf914eb3f3d2635a0'),
  ]),
};

// 算时段用的地点：济南（城市级，用户 11-26 告知；同教务地址，单校写死）。
const skyLatitude = 36.65;
const skyLongitude = 117.0;

// 太阳高度（度）：低精度太阳位置（误差约 0.01°，够分晨昏）。
double sunAltitude(DateTime instant, {double latitude = skyLatitude, double longitude = skyLongitude}) {
  double rad(double degrees) => degrees * math.pi / 180;
  final days = instant.toUtc().millisecondsSinceEpoch / 86400000 + 2440587.5 - 2451545.0;
  final anomaly = rad(357.529 + 0.98560028 * days);
  final longitudeOfSun = rad(280.459 + 0.98564736 * days + 1.915 * math.sin(anomaly) + 0.020 * math.sin(2 * anomaly));
  final obliquity = rad(23.439 - 0.00000036 * days);
  final ascension = math.atan2(math.cos(obliquity) * math.sin(longitudeOfSun), math.cos(longitudeOfSun));
  final declination = math.asin(math.sin(obliquity) * math.sin(longitudeOfSun));
  final sidereal = rad((280.46061837 + 360.98564736629 * days + longitude) % 360);
  final hour = sidereal - ascension;
  final lat = rad(latitude);
  return math.asin(math.sin(lat) * math.sin(declination) + math.cos(lat) * math.cos(declination) * math.cos(hour)) * 180 / math.pi;
}

// 此刻的画面：from 与 to 两幕按 mix 交叉过渡（0 只有 from，1 只有 to；不在过渡里时两幕相同、mix 为 0）。
class SkyMoment {
  const SkyMoment(this.from, [SkyPhase? to, this.mix = 0]) : to = to ?? from;
  final SkyPhase from;
  final SkyPhase to;
  final double mix;
  @override
  bool operator ==(Object other) => other is SkyMoment && other.from == from && other.to == to && other.mix == mix;
  @override
  int get hashCode => Object.hash(from, to, mix);
  @override
  String toString() => 'SkyMoment($from → $to, ${mix.toStringAsFixed(2)})';
}

// 按济南真实的太阳高度分幕（时段口径同上面 21:18:06 那条）：
// 太阳高过 6° 是白天；傍晚太阳从 6° 落到 0° 时白天过渡到黄昏，0° 到 -6°（民用晨昏）是黄昏，-6° 到 -12° 黄昏过渡到夜；
// 夜里按校园时钟分夜与深夜：23:30 到 0:30 由夜过渡到深夜，之后到天亮前是深夜；清晨太阳从 -18° 升到 -10° 由深夜过渡到黎明，
// -10° 到 0° 是黎明，0° 到 6° 黎明过渡到白天。过渡都按先慢后快再慢的曲线。上午还是下午看太阳是在升还是在落。
SkyMoment skyMoment(DateTime instant) {
  final height = sunAltitude(instant);
  final rising = sunAltitude(instant.add(const Duration(minutes: 10))) > height;
  double ease(double t) {
    final x = t.clamp(0.0, 1.0);
    return x * x * (3 - 2 * x);
  }
  SkyMoment blend(SkyPhase from, SkyPhase to, double t) {
    final mix = ease(t);
    return mix <= 0 ? SkyMoment(from) : mix >= 1 ? SkyMoment(to) : SkyMoment(from, to, mix);
  }
  if (height >= 6) return const SkyMoment(SkyPhase.day);
  if (rising) {
    if (height >= 0) return blend(SkyPhase.dawn, SkyPhase.day, height / 6);
    if (height >= -10) return const SkyMoment(SkyPhase.dawn);
    if (height >= -18) return blend(SkyPhase.late, SkyPhase.dawn, (height + 18) / 8);
  } else {
    if (height >= 0) return blend(SkyPhase.day, SkyPhase.dusk, (6 - height) / 6);
    if (height >= -6) return const SkyMoment(SkyPhase.dusk);
    if (height >= -12) return blend(SkyPhase.dusk, SkyPhase.night, (-6 - height) / 6);
  }
  // 太阳在地平线下 12°（傍晚）或 18°（清晨）以下：按校园时钟分夜与深夜。
  final local = campusInstant(instant);
  final minute = local.hour * 60 + local.minute;
  if (minute >= 23 * 60 + 30) return blend(SkyPhase.night, SkyPhase.late, (minute - (23 * 60 + 30)) / 60);
  if (minute < 30) return blend(SkyPhase.night, SkyPhase.late, (minute + 30) / 60);
  return minute < 12 * 60 ? const SkyMoment(SkyPhase.late) : const SkyMoment(SkyPhase.night);
}
