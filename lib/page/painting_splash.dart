import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/painting.dart';

// [人工决策-2026-10-23 16:48:13] 开屏画作（用户要求用自己以莫奈风格 AI 生成的画作做开屏背景，视觉交给助手；四项都选推荐）：
// 每次冷启动显示，至少 1.2 秒、恢复好账号再溶解进应用，点任意处立即进入，从后台切回不出现；画作随安装包内置、按清单驱动（不写死，加画只加图与清单一行），
// 按清单顺序轮换；画作单独声明保留所有权利、不随 GPL（README 许可一节与开源许可页）。
// 构图：画作贴底铺满屏宽（不够高时放大到约四成屏高、按 focus 裁两边，不把小图拉满整屏发糊），顶边渐隐融进上方的天空；天空横向按画作顶边的分段色铺开、
// 往上过渡到 sky 色，应用名与画名写在天空里（像画册封面）。系统启动图（应用图标）淡出后，天空先在，画作从下方浮起淡入、极慢地推近，
// 应用名与画名依次淡入；离开时整层淡出、画作再推近一点。减少动画时只淡入淡出，不位移不缩放。
class PaintingSplash extends StatefulWidget {
  const PaintingSplash({super.key, required this.painting, required this.image, required this.ready, required this.fontFamily, required this.child, this.shown});
  final Painting painting;
  // 组合根在 runApp 之前就开始解码的同一个图片（见 paintingSplashImage），开屏第一帧多半已经有图。
  final ImageProvider image;
  // 账号恢复完成：之后页面从启动页换到今天或登录页，等这段转场走完再溶解。
  final Future<void> ready;
  final String fontFamily;
  final Widget child;
  // 开屏第一帧真正上屏（栅格化完）；为空用引擎报的首帧（WidgetsBinding.waitUntilFirstFrameRasterized），测试里引擎不报帧耗时，传一个已完成的。
  final Future<void>? shown;

  static const minimum = Duration(milliseconds: 1200);
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

// 天空上应用名的颜色：亮天空用同色相的深墨色，暗天空用浅色；次要文字对天空也不低于 4.5:1。
({Color ink, Color soft, Brightness icons}) _inkOn(Color sky) {
  final light = sky.computeLuminance() > .3;
  return light
      ? (ink: Color.lerp(sky, Colors.black, .8)!, soft: Color.lerp(sky, Colors.black, .66)!, icons: Brightness.dark)
      : (ink: Color.lerp(sky, Colors.white, .9)!, soft: Color.lerp(sky, Colors.white, .74)!, icons: Brightness.light);
}

class _PaintingSplashState extends State<PaintingSplash> with TickerProviderStateMixin {
  late final _entry = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
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
      _exit.duration = const Duration(milliseconds: 240);
    }
    // 计时与入场动画都从开屏第一帧真正上屏之后开始：首帧要编译着色器、runApp 之后还有初始化，上屏可能比建好晚一两秒（模拟器调试包实测），
    // 从 initState 或建好那一帧起算的话，开屏一出现就已经满了 1.2 秒、紧接着溶解，入场动画也在上屏之前就走完了。
    (widget.shown ?? WidgetsBinding.instance.waitUntilFirstFrameRasterized).then((_) {
      if (!mounted) return;
      if (!_reduced) {
        _entry.forward();
        _drift.forward();
      }
      _timers
        ..add(Timer(PaintingSplash.minimum, () {
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
    final ink = _inkOn(sky);
    final height = _paintingHeight(painting, screen);
    final focus = painting.focus * 2 - 1;
    // 画作按 cover 铺进「屏宽 × height」时左右边缘在屏幕上的位置（换成 Alignment 的 -1 到 1），天空的分段色按同样的位置铺，和画作顶边逐段对上。
    final shown = math.max(screen.width, height * painting.aspect);
    final left = -(shown - screen.width) * painting.focus;
    final from = left / screen.width * 2 - 1, to = (left + shown) / screen.width * 2 - 1;
    final top = (screen.height - height) / screen.height * 2 - 1;
    final reduced = _reduced;
    final textScaler = media.textScaler.clamp(maxScaleFactor: 1.3);
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
              animation: Listenable.merge([_entry, _drift, _exit]),
              builder: (context, _) {
                double phase(double begin, double end) => Curves.easeOutCubic.transform(((_entry.value - begin) / (end - begin)).clamp(0.0, 1.0));
                final rise = phase(0, .78), title = phase(.14, .66), caption = phase(.3, .86);
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
                    // 应用名与画名：写在天空里约三成高的地方，依次淡入、略微上浮。
                    Positioned(
                      left: 32,
                      right: 32,
                      top: media.padding.top + (screen.height - height - media.padding.top) * .36,
                      child: MediaQuery(
                        data: media.copyWith(textScaler: textScaler),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Opacity(
                            opacity: title,
                            child: Transform.translate(
                              offset: Offset(0, reduced ? 0 : 10 * (1 - title) - 8 * leave),
                              child: Text('SuperXD', textAlign: TextAlign.center, textDirection: TextDirection.ltr, style: TextStyle(fontFamily: widget.fontFamily, fontSize: 34, fontWeight: FontWeight.w500, letterSpacing: 3, color: ink.ink, decoration: TextDecoration.none)),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Opacity(
                            opacity: caption,
                            child: Transform.translate(
                              offset: Offset(0, reduced ? 0 : 8 * (1 - caption) - 6 * leave),
                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                Container(width: 28, height: 1, color: ink.soft),
                                const SizedBox(height: 14),
                                Text('《${painting.title}》', textAlign: TextAlign.center, textDirection: TextDirection.ltr, style: TextStyle(fontFamily: widget.fontFamily, fontSize: 16, letterSpacing: 1, color: ink.ink, decoration: TextDecoration.none)),
                                const SizedBox(height: 4),
                                Text(painting.note, textAlign: TextAlign.center, textDirection: TextDirection.ltr, style: TextStyle(fontFamily: widget.fontFamily, fontSize: 14, color: ink.soft, decoration: TextDecoration.none)),
                              ]),
                            ),
                          ),
                        ]),
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
