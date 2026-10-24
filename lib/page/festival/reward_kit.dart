import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';

// 奖品揭晓共用的部件（入口与时间线在 festival_reward.dart，开启动效在 reward_stardust.dart，奖品卡容器在 reward_card.dart，主题各一个文件）：
// 取色 RewardTone、主题的接口 RewardTheme 与配色 RewardPalette、流光卡面 RewardSurface、
// 一帧的状态 RewardScene、开启动效的接口 RewardLook、着色器缓存 RewardShaders、粒子贴图 RewardSprites。

// 在 OKLCH 里取色（同 CSS Color 4 的 oklch()）：明度、彩度、色相分开调，换色相时看起来一样亮（HSL 换色相忽明忽暗，黄比蓝亮得多）。
// 默认主题的颜色都从应用配色的激活色（种子）的色相出发，按明度、彩度、色相偏移取。
class RewardTone {
  factory RewardTone(Color seed) {
    final (_, a, b) = _toOklab(seed);
    return RewardTone._(math.atan2(b, a));
  }
  const RewardTone._(this.hue);
  final double hue;

  // 明度 0–1、彩度（OKLCH 的 C，常用 0–0.3）、相对种子的色相偏移（度）。
  Color pick(double lightness, double chroma, {double turn = 0, double alpha = 1}) => _pick(lightness, chroma, hue + turn * math.pi / 180, alpha);

  // 超出 sRGB 时逐步降彩度直到能显示。
  static Color _pick(double lightness, double chroma, double angle, double alpha) {
    var reach = chroma;
    while (true) {
      final rgb = _fromOklab(lightness, reach * math.cos(angle), reach * math.sin(angle));
      final inside = rgb.$1 >= -1e-4 && rgb.$1 <= 1.0001 && rgb.$2 >= -1e-4 && rgb.$2 <= 1.0001 && rgb.$3 >= -1e-4 && rgb.$3 <= 1.0001;
      if (inside || reach < 1e-3) return Color.from(alpha: alpha, red: _encode(rgb.$1), green: _encode(rgb.$2), blue: _encode(rgb.$3));
      reach *= .92;
    }
  }

  static double _linear(double channel) => channel <= .04045 ? channel / 12.92 : math.pow((channel + .055) / 1.055, 2.4).toDouble();
  static double _encode(double linear) {
    final value = linear.clamp(0.0, 1.0);
    return value <= .0031308 ? 12.92 * value : 1.055 * math.pow(value, 1 / 2.4) - .055;
  }

  static double _cbrt(double value) => value < 0 ? -math.pow(-value, 1 / 3).toDouble() : math.pow(value, 1 / 3).toDouble();

  static (double, double, double) _toOklab(Color color) {
    final red = _linear(color.r), green = _linear(color.g), blue = _linear(color.b);
    final l = _cbrt(.4122214708 * red + .5363325363 * green + .0514459929 * blue);
    final m = _cbrt(.2119034982 * red + .6806995451 * green + .1073969566 * blue);
    final s = _cbrt(.0883024619 * red + .2817188376 * green + .6299787005 * blue);
    return (.2104542553 * l + .7936177850 * m - .0040720468 * s, 1.9779984951 * l - 2.4285922050 * m + .4505937099 * s, .0259040371 * l + .7827717662 * m - .8086757660 * s);
  }

  // 返回线性 sRGB（可能超出 0–1，调用方据此判断是否在色域内）。
  static (double, double, double) _fromOklab(double lightness, double a, double b) {
    final l = math.pow(lightness + .3963377774 * a + .2158037573 * b, 3).toDouble();
    final m = math.pow(lightness - .1055613458 * a - .0638541728 * b, 3).toDouble();
    final s = math.pow(lightness - .0894841775 * a - 1.2914855480 * b, 3).toDouble();
    return (4.0767416621 * l - 3.3077115913 * m + .2309699292 * s, -1.2684380046 * l + 2.6097574011 * m - .3413193965 * s, -.0041960863 * l - .7034186147 * m + 1.7076147010 * s);
  }
}

// 浮层压暗下面页面的程度（房间熄了灯，只剩发光的那件东西）。
const rewardScrim = .975;

// 奖品卡至少是宽的这么多倍高（像一张卡，口令卡内容少时不至于近乎正方形）与圆角。
const rewardCardAspect = 1.3;
const rewardCardRadius = 28.0;

// 一个主题的全部颜色：night 是浮层压暗的底，flows 是卡头网格渐变与边缘流光的四个颜色（种子色与两侧相邻的色相），body 是玻璃卡的近黑底，
// light 是开启动效的主光，dust 是星尘的几种颜色，ink、muted 是卡上的字，slot 是口令框的底，button、buttonInk 是主按钮。
class RewardPalette {
  const RewardPalette({
    required this.night,
    required this.flows,
    required this.body,
    required this.light,
    required this.dust,
    required this.ink,
    required this.muted,
    required this.slot,
    required this.button,
    required this.buttonInk,
  });
  final Color night;
  final List<Color> flows;
  final Color body;
  final Color light;
  final List<Color> dust;
  final Color ink;
  final Color muted;
  final Color slot;
  final Color button;
  final Color buttonInk;
}

// 奖品卡的主题（一次节日一个，登记在 festival_catalog.dart 的场景上；没登记的用默认的流光卡 reward_glow.dart）：配色与卡面。
// 卡的外形、内容与操作是容器定的，主题只管卡面画什么。
abstract class RewardTheme {
  const RewardTheme();
  // seed 是应用配色的激活色。
  RewardPalette palette(Color seed);
  Future<void> prepare() => RewardShaders.load(RewardSurface.asset);
  // 卡面：card 是卡在画布上的位置，可以画到卡外（外面的一圈光）；time 是秒；reveal 是卡形从中间长出来的进度；tilt 是倾斜；still 为真时是静止的一帧（减少动画）。
  void paintCard(Canvas canvas, Rect card, RewardPalette palette, {required double time, required double reveal, required Offset tilt, required bool still});
}

// 流光卡面（材质在 shaders/reward_aurora.frag）。每种用途一个着色器实例（同一帧里不同用途的参数互不覆盖）。
abstract final class RewardSurface {
  static const asset = 'shaders/reward_aurora.frag';
  // 卡头渐变铺开的高度（往下 1.5 倍处暗进卡身）。
  static const header = 108.0;
  static final _shaders = <Object, ui.FragmentShader>{};

  // 着色器没加载好时为空，调用方画退路。
  static ui.FragmentShader? shader(Object use, {required Rect card, required double time, required Offset tilt, required RewardPalette palette, double morph = 1}) {
    final program = RewardShaders.of(asset);
    if (program == null) return null;
    final shader = _shaders[use] ??= program.fragmentShader();
    var index = 0;
    for (final value in [card.right, card.bottom, card.left, card.top, card.width, card.height, rewardCardRadius, time, morph, header, tilt.dx, tilt.dy]) {
      shader.setFloat(index++, value);
    }
    for (final color in [...palette.flows, palette.body]) {
      index = setShaderColor(shader, index, color);
    }
    return shader;
  }
}

// 揭晓的一帧：开启动效按它画整个画面。时间线的数值都是 0–1；clock 是秒（等点和停稳后的慢动效用），tilt 是手指或自动的倾斜（各分量 −1–1）。
class RewardScene {
  const RewardScene({
    required this.screen,
    required this.padding,
    required this.cardWidth,
    required this.cardSize,
    required this.enter,
    required this.exit,
    required this.open,
    required this.envelope,
    required this.reduced,
    required this.clock,
    required this.tilt,
    required this.pressed,
    required this.palette,
    required this.title,
    required this.card,
    required this.seal,
  });
  final Size screen;
  final EdgeInsets padding;
  final double cardWidth;
  // 奖品卡排好版后的大小（第一帧之前为空，用宽乘最小高宽比估）。
  final Size? cardSize;
  final double enter;
  final double exit;
  final double open;
  // 走拆开的流程（假时是「我的」里再打开，或减少动画）：直接是卡片。
  final bool envelope;
  final bool reduced;
  final ValueListenable<double> clock;
  final ValueListenable<Offset> tilt;
  final ValueListenable<bool> pressed;
  final RewardPalette palette;
  final String title;
  // 奖品卡（主题的容器套着同一份内容，内容带 key，同一时刻只能放在一处；还没揭晓时放进 Offstage，照常排版、不画、不响应、读屏和测试都找不到）。
  // body 是卡的背景层从中心往外显出来的进度，content 是内容层显出来的进度，都是 0–1。
  final Widget Function({double body, double content}) card;
  // 把等点的那件东西包成「拆开」按钮（读屏名、点按、按下、拖动倾斜）。
  final Widget Function(Widget child) seal;

  bool get sealed => envelope && open == 0;
  Size get size => cardSize ?? Size(cardWidth, cardWidth * rewardCardAspect);
  // 卡片停在安全区正中。
  Offset get center => Offset(screen.width / 2, padding.top + (screen.height - padding.top - padding.bottom) / 2);
  Rect get cardRect => Rect.fromCenter(center: center, width: size.width, height: size.height);
}

// 一个开启动效：拆开的时长、拆开那一刻在时间线上的位置，以及按帧画出的各层（自下而上）。
abstract class RewardLook {
  const RewardLook();
  Duration get openLength;
  double get burstAt;
  List<Widget> layers(BuildContext context, RewardScene scene);
}

// 着色器程序按文件缓存（加载一次，全应用共用）；没加载好或加载失败时主题用渐变退路画。
class RewardShaders {
  static final _programs = <String, ui.FragmentProgram>{};
  static final _loading = <String, Future<void>>{};

  static ui.FragmentProgram? of(String asset) => _programs[asset];

  static Future<void> load(String asset) => _loading[asset] ??= ui.FragmentProgram.fromAsset(asset).then<void>(
        (program) => _programs[asset] = program,
        onError: (Object error, StackTrace stack) => campusLog('[festival] action=loadShader asset=$asset errorType=${error.runtimeType}\n$error\n$stack'),
      );
}

// 着色器的颜色参数：按顺序写三个分量。
int setShaderColor(ui.FragmentShader shader, int index, Color color) {
  shader
    ..setFloat(index, color.r)
    ..setFloat(index + 1, color.g)
    ..setFloat(index + 2, color.b);
  return index + 3;
}

// 粒子贴图（只画一次）：一张 192×64 的图上三格，依次是柔光点、四角星、拖尾（朝右）；
// 粒子用 drawRawAtlas 按颜色调制、加色叠加，一次画完。
class RewardSprites {
  static ui.Image? _image;
  static const dot = Rect.fromLTWH(0, 0, 64, 64);
  static const star = Rect.fromLTWH(64, 0, 64, 64);
  static const streak = Rect.fromLTWH(128, 0, 64, 64);

  static ui.Image get image => _image ??= _draw();

  static ui.Image _draw() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const white = Color(0xFFFFFFFF);
    canvas.drawCircle(const Offset(32, 32), 32, Paint()..shader = ui.Gradient.radial(const Offset(32, 32), 32, [white, white.withValues(alpha: .42), white.withValues(alpha: .1), white.withValues(alpha: 0)], [0, .18, .5, 1]));
    // 四角星：细长的十字光芒（中间亮、往外收尖）加一团小光晕。
    canvas.drawCircle(const Offset(96, 32), 14, Paint()..shader = ui.Gradient.radial(const Offset(96, 32), 14, [white.withValues(alpha: .7), white.withValues(alpha: 0)]));
    final star = Path();
    for (var arm = 0; arm < 4; arm++) {
      final angle = arm * math.pi / 2;
      final tip = Offset(96 + math.cos(angle) * 30, 32 + math.sin(angle) * 30);
      final side = Offset(math.cos(angle + math.pi / 2), math.sin(angle + math.pi / 2)) * 2.6;
      star
        ..moveTo(96 + side.dx, 32 + side.dy)
        ..lineTo(tip.dx, tip.dy)
        ..lineTo(96 - side.dx, 32 - side.dy)
        ..close();
    }
    canvas.drawPath(star, Paint()..shader = ui.Gradient.radial(const Offset(96, 32), 30, [white, white.withValues(alpha: .55), white.withValues(alpha: 0)], [0, .35, 1]));
    canvas.drawRRect(RRect.fromLTRBR(132, 27, 188, 37, const Radius.circular(5)), Paint()..shader = ui.Gradient.linear(const Offset(132, 0), const Offset(188, 0), [white.withValues(alpha: 0), white.withValues(alpha: .45), white], [0, .7, 1]));
    final picture = recorder.endRecording();
    final image = picture.toImageSync(192, 64);
    picture.dispose();
    return image;
  }
}

// 一批粒子：每个粒子写一组变换（缩放、旋转、中心）、贴图格与颜色，最后一次 drawRawAtlas 加色叠加。
class RewardParticles {
  final _transforms = <double>[];
  final _rects = <double>[];
  final _colors = <int>[];

  bool get isEmpty => _colors.isEmpty;

  // size 是粒子画出来的直径（逻辑像素），rotation 弧度。
  void add(Rect sprite, Offset center, double size, Color color, {double rotation = 0}) {
    if (color.a <= 0.002 || size <= 0.05) return;
    final scale = size / sprite.width;
    final cos = math.cos(rotation) * scale, sin = math.sin(rotation) * scale;
    final half = sprite.width / 2;
    _transforms.addAll([cos, sin, center.dx - cos * half + sin * half, center.dy - sin * half - cos * half]);
    _rects.addAll([sprite.left, sprite.top, sprite.right, sprite.bottom]);
    _colors.add(color.toARGB32());
  }

  // 加色叠加（光在暗处）。
  void paint(Canvas canvas) {
    if (isEmpty) return;
    canvas.drawRawAtlas(RewardSprites.image, Float32List.fromList(_transforms), Float32List.fromList(_rects), Int32List.fromList(_colors), BlendMode.modulate, null, Paint()..blendMode = BlendMode.plus);
  }
}

// 时间线上的一段：t 在 from–to 之间时从 0 走到 1。
double rewardSpan(double t, double from, double to) => ((t - from) / (to - from)).clamp(0.0, 1.0);

// 把子组件的中心放在 center（子组件按自己的大小排）。
class RewardCenter extends SingleChildLayoutDelegate {
  RewardCenter(this.center);
  final Offset center;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();
  @override
  Offset getPositionForChild(Size size, Size childSize) => center - Offset(childSize.width / 2, childSize.height / 2);
  @override
  bool shouldRelayout(RewardCenter oldDelegate) => oldDelegate.center != center;
}
