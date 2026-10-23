import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/painting.dart';
import 'package:superxd/page/splash_signature.dart';

// [人工决策-2026-10-23 16:48:13] 开屏画作（用户要求用自己以莫奈风格 AI 生成的画作做开屏背景，视觉交给助手；四项都选推荐）：
// 每次冷启动显示，恢复好账号再溶解进应用，点任意处立即进入，从后台切回不出现；画作随安装包内置、按清单驱动（不写死，加画只加图与清单一行），
// 按清单顺序轮换；画作单独声明保留所有权利、不随 GPL（README 许可一节与开源许可页）。
// 构图：画作贴底铺满屏宽（不够高时放大到约四成屏高、按 focus 裁两边，不把小图拉满整屏发糊），顶边渐隐融进上方的天空；天空横向按画作顶边的分段色铺开、
// 往上过渡到 sky 色。系统启动图（只有底色，不画应用图标，[人工决策] 在 android res/values-v31/styles.xml）淡出后，天空先在，画作从下方浮起淡入、极慢地推近；
// 离开时整层淡出、画作再推近一点。减少动画时只淡入淡出，不位移不缩放。
// [人工决策-2026-10-23 21:12:25] 天空里只写应用名，不写画名与「仿莫奈风格 · AI 生成」（画名与说明只在关于页的开屏画作里看）；应用名改成一笔写出的手写体
// （同苹果开机的 hello，见 splash_signature.dart）。用户选「写完再溶解」（未选保持 1.2 秒、字写得急）：上屏后 0.1 秒起笔、约 1.6 秒写完、停 0.3 秒，
// 开屏至少约 2 秒；点一下随时进入。减少动画时不写、直接显示写好的字，至少 1.2 秒。
class PaintingSplash extends StatefulWidget {
  const PaintingSplash({super.key, required this.painting, required this.image, required this.ready, required this.child, this.shown});
  final Painting painting;
  // 组合根在 runApp 之前就开始解码的同一个图片（见 paintingSplashImage），开屏第一帧多半已经有图。
  final ImageProvider image;
  // 账号恢复完成：之后页面从启动页换到今天或登录页，等这段转场走完再溶解。
  final Future<void> ready;
  final Widget child;
  // 开屏第一帧真正上屏（栅格化完）；为空用引擎报的首帧（WidgetsBinding.waitUntilFirstFrameRasterized），测试里引擎不报帧耗时，传一个已完成的。
  final Future<void>? shown;

  static const writeDelay = Duration(milliseconds: 100);
  static const writing = Duration(milliseconds: 1600);
  // 起笔前 0.1 秒、书写 1.6 秒，再停 0.3 秒。
  static const minimum = Duration(milliseconds: 2000);
  static const reducedMinimum = Duration(milliseconds: 1200);
  static const settle = Duration(milliseconds: 450);
  // 恢复一直不完成时最多等这么久，之后照常溶解（下面是启动页的加载动画）。
  static const longest = Duration(seconds: 4);

  @override
  State<PaintingSplash> createState() => _PaintingSplashState();
}

// 画作在屏幕上的高度：贴底铺满屏宽；比四成屏高矮就放大到四成（宽出来的按 focus 裁掉），比七成高就裁到七成（宽屏、横屏）。
double _paintingHeight(Painting painting, Size screen) => (screen.width / painting.aspect).clamp(screen.height * .42, screen.height * .72);

// 开屏要的图：按画作在屏幕上实际占的物理像素解码，原图更小就用原图，不多占内存。
ImageProvider paintingSplashImage(Painting painting, Size screen, double devicePixelRatio) {
  final width = math.max(screen.width, _paintingHeight(painting, screen) * painting.aspect) * devicePixelRatio;
  return ResizeImage.resizeIfNeeded(math.min(width.round(), painting.width), null, ExactAssetImage(painting.asset));
}

// 天空上应用名的墨色从画里调：取画作顶边最冷、最暖的两色，亮天空压成深色（红橙黄压暗发脏，色相转到梅紫），暗天空提成浅色；
// 沿书写方向从冷到暖渐变（雾城日出是靛蓝到梅紫，河畔树影两端都是蓝、几乎看不出渐变）。
({(Color, Color) ink, Brightness icons}) _inkOn(Painting painting) {
  final light = Color(painting.sky).computeLuminance() > .3;
  final horizon = [for (final color in painting.horizon) Color(color)];
  double warmth(Color color) => color.r - color.b;
  Color ink(Color color) {
    final hsl = HSLColor.fromColor(color);
    final hue = hsl.hue <= 75 ? 330 + hsl.hue * .3 : hsl.hue;
    return light ? HSLColor.fromAHSL(1, hue, (hsl.saturation * 2).clamp(.3, .65), .22).toColor() : HSLColor.fromAHSL(1, hue, hsl.saturation.clamp(.2, .5), .9).toColor();
  }

  final cool = horizon.reduce((a, b) => warmth(a) <= warmth(b) ? a : b), warm = horizon.reduce((a, b) => warmth(a) >= warmth(b) ? a : b);
  return (ink: (ink(cool), ink(warm)), icons: light ? Brightness.dark : Brightness.light);
}

class _PaintingSplashState extends State<PaintingSplash> with TickerProviderStateMixin {
  late final _entry = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  // 一笔写出应用名；书写的快慢（转弯慢、直线快、提笔停顿）在 SplashSignature 里按进度换算，这里匀速走进度。
  late final _write = AnimationController(vsync: this, duration: PaintingSplash.writing);
  // 极慢的推近（Ken Burns），整段开屏都在动，不停在一帧静止画面上。
  late final _drift = AnimationController(vsync: this, duration: const Duration(seconds: 6));
  late final _exit = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));
  // 两个条件都到了才溶解：满 minimum，且账号恢复后又过了 settle（页面换到今天或登录页的转场走完）。
  final _timers = <Timer>[];
  bool _minimumPassed = false;
  bool _settled = false;
  bool _gone = false;
  // 开屏挂在应用的 MaterialApp 之外，减少动画直接读系统设置（同组合根的主题过渡）。
  final _reduced = WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations || WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.reduceMotion;

  @override
  void initState() {
    super.initState();
    if (_reduced) {
      _entry.value = 1;
      _write.value = 1;
      _exit.duration = const Duration(milliseconds: 240);
    }
    // 计时与入场动画都从开屏第一帧真正上屏之后开始：首帧要编译着色器、runApp 之后还有初始化，上屏可能比建好晚一两秒（模拟器调试包实测），
    // 从 initState 或建好那一帧起算的话，开屏一出现就已经满了 1.2 秒、紧接着溶解，入场动画也在上屏之前就走完了。
    (widget.shown ?? WidgetsBinding.instance.waitUntilFirstFrameRasterized).then((_) {
      if (!mounted) return;
      if (!_reduced) {
        _entry.forward();
        _drift.forward();
        _timers.add(Timer(PaintingSplash.writeDelay, _write.forward));
      }
      _timers
        ..add(Timer(_reduced ? PaintingSplash.reducedMinimum : PaintingSplash.minimum, () {
          _minimumPassed = true;
          if (_settled) _leave();
        }))
        ..add(Timer(PaintingSplash.longest, _leave));
    });
    widget.ready.then((_) {
      if (!mounted) return;
      _timers.add(Timer(PaintingSplash.settle, () {
        _settled = true;
        if (_minimumPassed) _leave();
      }));
    }, onError: (Object error, StackTrace stack) => _leave());
  }

  // 溶解进应用：只走一次；途中手指已能点到下面的页面。走完从树上拿掉（子树位置不变，下面的应用不重建）。
  void _leave() {
    for (final timer in _timers) {
      timer.cancel();
    }
    if (!mounted || _exit.status != AnimationStatus.dismissed) return;
    _exit.forward().whenCompleteOrCancel(() {
      _drift.stop();
      if (mounted) setState(() => _gone = true);
    });
    setState(() {});
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _entry.dispose();
    _write.dispose();
    _drift.dispose();
    _exit.dispose();
    super.dispose();
  }

  // 应用在下面照常启动；开屏这层自带 MediaQuery 与文字方向（它在应用的 MaterialApp 之外）。
  @override
  Widget build(BuildContext context) => Stack(textDirection: TextDirection.ltr, children: [
    widget.child,
    if (!_gone)
      Positioned.fill(
        child: MediaQuery.fromView(
          view: View.of(context),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: IgnorePointer(ignoring: _exit.status != AnimationStatus.dismissed, child: Builder(builder: _splash)),
          ),
        ),
      ),
  ]);

  Widget _splash(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final painting = widget.painting;
    final sky = Color(painting.sky);
    final ink = _inkOn(painting);
    final height = _paintingHeight(painting, screen);
    final focus = painting.focus * 2 - 1;
    // 画作按 cover 铺进「屏宽 × height」时左右边缘在屏幕上的位置（换成 Alignment 的 -1 到 1），天空的分段色按同样的位置铺，和画作顶边逐段对上。
    final shown = math.max(screen.width, height * painting.aspect);
    final left = -(shown - screen.width) * painting.focus;
    final from = left / screen.width * 2 - 1, to = (left + shown) / screen.width * 2 - 1;
    final top = (screen.height - height) / screen.height * 2 - 1;
    final reduced = _reduced;
    // 签名宽约屏宽的八成（宽屏不超过 360），高按字形比例。
    final signatureWidth = math.min(screen.width * .8, 360.0);
    final signatureBounds = SplashSignature.shared.bounds;
    final signatureHeight = signatureWidth * signatureBounds.height / signatureBounds.width;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        statusBarIconBrightness: ink.icons,
        statusBarBrightness: ink.icons == Brightness.dark ? Brightness.light : Brightness.dark,
      ),
      child: Semantics(
        container: true,
        button: true,
        label: '开屏画作《${painting.title}》，轻点进入应用',
        onTap: _leave,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _leave,
          child: ExcludeSemantics(
            child: AnimatedBuilder(
              animation: Listenable.merge([_entry, _write, _drift, _exit]),
              builder: (context, _) {
                final rise = Curves.easeOutCubic.transform((_entry.value / .78).clamp(0.0, 1.0));
                final leave = Curves.easeInOutCubic.transform(_exit.value);
                final zoom = reduced ? 1.0 : 1 + .05 * (1 - rise) + .035 * _drift.value + .02 * leave;
                return Opacity(
                  opacity: 1 - leave,
                  child: Stack(fit: StackFit.expand, children: [
                    // 天空：画作顶边那条按分段色横向铺开，往上渐变到屏幕顶端的 sky 色。
                    DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment(from, 0), end: Alignment(to, 0), colors: [for (final color in painting.horizon) Color(color)]))),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment(0, top), colors: [sky, sky, sky.withValues(alpha: 0)], stops: const [0, .3, 1]),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: height,
                      child: Opacity(
                        opacity: rise,
                        child: Transform.translate(
                          offset: Offset(0, reduced ? 0 : 28 * (1 - rise)),
                          // 顶边两成多渐隐，融进天空（画作推近时顶边换了位置，也藏在这段渐隐里）。
                          child: ShaderMask(
                            blendMode: BlendMode.dstIn,
                            shaderCallback: (rect) => const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black], stops: [0, .24]).createShader(rect),
                            child: ClipRect(
                              child: Transform.scale(
                                scale: zoom,
                                alignment: Alignment(focus, 1),
                                child: Image(image: widget.image, fit: BoxFit.cover, alignment: Alignment(focus, 1), filterQuality: FilterQuality.medium, gaplessPlayback: true),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 应用名一笔写出，写在天空里约四成高的地方；离开时随整层淡出、略微上浮。
                    Positioned(
                      left: 0,
                      right: 0,
                      top: media.padding.top + (screen.height - height - media.padding.top) * .4 - signatureHeight / 2,
                      child: Center(
                        child: Transform.translate(
                          offset: Offset(0, reduced ? 0 : -8 * leave),
                          child: CustomPaint(size: Size(signatureWidth, signatureHeight), painter: SplashSignaturePainter(progress: _write.value, ink: ink.ink)),
                        ),
                      ),
                    ),
                  ]),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
