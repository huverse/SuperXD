import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:superxd/domain/festival.dart';
import 'package:superxd/theme/campus_confetti.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_transitions.dart';

// 奖品揭晓（预制，所有节日共用；人工决策见 domain/festival.dart）：同微信拆红包的手感、Apple Pay 与订阅成功页的礼花收尾。
// 红包从下方浮起，金色「開」在等你点（轻轻呼吸、隔一会儿掠过一道光）；点开后「開」绕竖轴转两圈消失，封口沿上沿向后翻开，
// 奖品卡从红包里升起、红包沉下去，卡片停在屏幕正中，同时从封口处喷出金红两色的纸片礼花、卡片后面亮起缓慢转动的光芒。
// 卡片：节日名、口令（大字、可复制）或二维码、附言，主操作一键复制口令并打开支付宝 / 在支付宝里打开二维码，「收下了」关闭。
// 红包与卡片固定用中国红与金、象牙白（同真实红包与 Apple Wallet 卡券），不随配色与深浅色变；减少动画时不拆、不转、不喷，直接淡入卡片。
// 支付宝没有公开的应用链接文档：二维码用社区实测可用的「扫一扫」链接带 qrcode 参数，口令只打开支付宝，都还没在真机上验过。

const _crimson = Color(0xFFD2342A);
const _crimsonDeep = Color(0xFFAE1F1B);
const _flapLight = Color(0xFFEF5B47);
const _flapDeep = Color(0xFFDC4232);
const _inside = Color(0xFF8C1714);
const _goldLight = Color(0xFFFFF0C2);
const _gold = Color(0xFFF1C969);
const _goldDeep = Color(0xFFC58D2C);
const _ink = Color(0xFF9C1E19);
const _paper = Color(0xFFFFFBF2);
const _paperEdge = Color(0xFFE9D3A2);
const _brown = Color(0xFF7D5C3C);

// 二维码：「扫一扫」入口带上二维码内容直接识别；口令：只打开支付宝（口令已经复制，在支付宝里搜「口令红包」粘贴）。
Uri alipayQrUri(String content) => Uri.parse('alipays://platformapi/startapp?saId=10000007&qrcode=${Uri.encodeComponent(content)}');
final alipayHome = Uri.parse('alipays://platformapi/startapp');

// envelope 为假时不拆红包、直接显示卡片（「我的」里再打开）。saveQrCode 为空时不显示「保存二维码」。
Future<void> showFestivalReward(BuildContext context, {required FestivalPrize prize, required String title, bool envelope = true, Future<bool> Function(Uint8List png)? saveQrCode, Future<bool> Function(Uri uri)? openUri}) =>
    Navigator.of(context, rootNavigator: true).push(_RewardRoute(prize: prize, title: title, envelope: envelope, saveQrCode: saveQrCode, openUri: openUri ?? (uri) => launchUrl(uri, mode: LaunchMode.externalApplication)));

// 浮层路由（不是页面路由，下面的页面不跟着做转场）；进出都由揭晓自己的时间线画，路由本身不做过渡。
class _RewardRoute extends PopupRoute<void> {
  _RewardRoute({required this.prize, required this.title, required this.envelope, required this.saveQrCode, required this.openUri});
  final FestivalPrize prize;
  final String title;
  final bool envelope;
  final Future<bool> Function(Uint8List png)? saveQrCode;
  final Future<bool> Function(Uri uri) openUri;

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => false;
  @override
  String? get barrierLabel => null;
  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      _RewardReveal(prize: prize, title: title, envelope: envelope, saveQrCode: saveQrCode, openUri: openUri);
}

class _RewardReveal extends StatefulWidget {
  const _RewardReveal({required this.prize, required this.title, required this.envelope, required this.saveQrCode, required this.openUri});
  final FestivalPrize prize;
  final String title;
  final bool envelope;
  final Future<bool> Function(Uint8List png)? saveQrCode;
  final Future<bool> Function(Uri uri) openUri;

  @override
  State<_RewardReveal> createState() => _RewardRevealState();
}

class _RewardRevealState extends State<_RewardReveal> with TickerProviderStateMixin {
  // 入场：压暗、红包浮起（不拆红包时是卡片淡入）。
  late final _enter = AnimationController(vsync: this, duration: const Duration(milliseconds: 720));
  // 等点的时候「開」轻轻呼吸，隔一会儿掠过一道光。
  late final _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
  late final _shine = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800));
  // 拆开的整段时间线（各段见 _Phases）。
  late final _open = AnimationController(vsync: this, duration: const Duration(milliseconds: 2100));
  // 卡片后面光芒的慢转。
  late final _rays = AnimationController(vsync: this, duration: const Duration(seconds: 28));
  late final _exit = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  // 礼花按秒驱动（闭式解，见 theme/campus_confetti.dart）。
  final _confettiSeconds = ValueNotifier(0.0);
  late final AnimationController _confetti = AnimationController(vsync: this, duration: const Duration(seconds: 4))..addListener(() => _confettiSeconds.value = _confetti.value * 4);
  final _qrKey = GlobalKey();
  ConfettiShow? _show;
  bool _opening = false;
  bool _burst = false;
  bool _closing = false;
  late bool _reduced;

  @override
  void initState() {
    super.initState();
    _open.addListener(_onOpenTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (_enter.status != AnimationStatus.dismissed) return;
    if (_reduced || !widget.envelope) {
      // 不拆红包（「我的」里再打开）或减少动画：直接是卡片，不喷礼花、不震。
      _burst = true;
      _open.value = 1;
      _enter.duration = Duration(milliseconds: _reduced ? 200 : 380);
      if (!_reduced) _rays.repeat();
    } else {
      _breath.repeat(reverse: true);
      _shine.repeat();
    }
    _enter.forward();
  }

  void _onOpenTick() {
    // 卡片升出封口时喷礼花、亮光芒，轻震一下。
    if (_burst || _open.value < _Phases.burst) return;
    _burst = true;
    HapticFeedback.lightImpact();
    _confetti.forward(from: 0);
    _rays.repeat();
  }

  void _tear() {
    if (_opening || _closing || _open.value > 0) return;
    _opening = true;
    HapticFeedback.mediumImpact();
    _breath.stop();
    _shine.stop();
    _open.forward();
    setState(() {});
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    await _exit.forward();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _primary() async {
    final prize = widget.prize;
    if (prize.kind == FestivalPrizeKind.password) {
      await Clipboard.setData(ClipboardData(text: prize.content));
      HapticFeedback.selectionClick();
      final opened = await _launch(alipayHome);
      if (mounted) showCampusToast(context, opened ? '口令已复制，在支付宝里搜「口令红包」粘贴' : '口令已复制，没找到支付宝');
      return;
    }
    // 二维码：先用支付宝扫一扫直接识别；不行而内容是网页链接时交给系统打开（支付宝的红包链接会跳回支付宝）。
    final content = Uri.tryParse(prize.content);
    final opened = await _launch(alipayQrUri(prize.content)) || content != null && content.isScheme('https') && await _launch(content);
    if (!opened && mounted) showCampusToast(context, widget.saveQrCode == null ? '没找到支付宝' : '没找到支付宝，可以保存二维码后用支付宝扫一扫识别');
  }

  Future<bool> _launch(Uri uri) async {
    try {
      return await widget.openUri(uri);
    } catch (error) {
      return false;
    }
  }

  Future<void> _saveQrCode() async {
    final boundary = _qrKey.currentContext?.findRenderObject();
    final save = widget.saveQrCode;
    if (boundary is! RenderRepaintBoundary || save == null) return;
    final image = await boundary.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final saved = data != null && await save(data.buffer.asUint8List());
    if (mounted) showCampusToast(context, saved ? '二维码已存到相册（Download/SuperXD）' : '保存失败，请重试');
  }

  @override
  void dispose() {
    for (final controller in [_enter, _breath, _shine, _open, _rays, _exit, _confetti]) {
      controller.dispose();
    }
    _confettiSeconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        // 浮层路由不在任何 Material 之下：垫一层透明的，文字照常取应用字体，按钮有墨水层。
        child: Material(type: MaterialType.transparency, child: LayoutBuilder(builder: (context, constraints) {
          final screen = constraints.biggest;
          final geometry = _Geometry(screen, MediaQuery.paddingOf(context));
          _show ??= ConfettiShow(
            papers: _papers,
            bursts: [
              ConfettiBurst(origin: geometry.mouth(screen, -.32), angle: -math.pi / 2 - .55, spread: .9, count: 46),
              ConfettiBurst(origin: geometry.mouth(screen, .32), angle: -math.pi / 2 + .55, spread: .9, count: 46),
              ConfettiBurst(origin: geometry.mouth(screen, 0), angle: -math.pi / 2, spread: .7, count: 40, speed: (720, 1250), delay: const Duration(milliseconds: 90)),
            ],
          );
          return AnimatedBuilder(
            animation: Listenable.merge([_enter, _open, _exit, _breath, _shine]),
            builder: (context, _) => _layers(context, geometry),
          );
        })),
      ),
    );
  }

  Widget _layers(BuildContext context, _Geometry geometry) {
    final phases = _Phases(_open.value);
    final enter = Curves.easeOutCubic.transform(_enter.value), exit = Curves.easeInCubic.transform(_exit.value);
    final opened = _open.value > 0;
    // 压暗的底：中间带一点暖色的光晕，像红包在发光。
    final scrim = enter * (1 - exit);
    return Stack(children: [
      Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _ScrimPainter(opacity: scrim, warmth: widget.envelope && !_reduced ? 1 - phases.sink : .35)))),
      // 光芒：卡片升出后亮起，慢慢转。
      if (!_reduced)
        Positioned.fill(child: IgnorePointer(child: Opacity(
          opacity: (phases.rays * (1 - exit)).clamp(0, 1),
          child: RotationTransition(turns: _rays, child: CustomPaint(painter: _RaysPainter(center: geometry.cardCenter, radius: geometry.screen.shortestSide * .9))),
        ))),
      if (widget.envelope && !_reduced && phases.sink < 1) _envelope(geometry, phases, enter),
      if (opened) _card(context, geometry, phases, enter, exit),
      if (!_reduced) Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: ConfettiPainter(show: _show!, seconds: _confettiSeconds)))),
    ]);
  }

  Widget _envelope(_Geometry geometry, _Phases phases, double enter) {
    final size = geometry.envelope;
    // 入场从下方浮起、略微放大（带一点点回弹），拆开后沉下去淡出。
    final rise = Curves.easeOutBack.transform(_enter.value.clamp(0, 1)) ;
    final dy = (1 - rise) * geometry.screen.height * .32 + phases.sink * geometry.screen.height * .55;
    final scale = .9 + .1 * rise;
    final flap = phases.flap * math.pi * .92;
    final coinTurn = phases.spin * math.pi * 4;
    final coinScale = (1 + .07 * math.sin(phases.spin * math.pi)) * (1 - .35 * phases.coinGone) * (opened ? 1 : 1 + .045 * Curves.easeInOut.transform(_breath.value));
    final flapBehind = flap > math.pi / 2;
    final flapLayer = Transform(
      alignment: Alignment.topCenter,
      transform: Matrix4.identity()
        ..setEntry(3, 2, .0011)
        ..rotateX(-flap),
      child: CustomPaint(size: size, painter: _FlapPainter(title: widget.title, inside: flapBehind, fade: phases.flapFade)),
    );
    return Positioned(
      left: geometry.envelopeOrigin.dx,
      top: geometry.envelopeOrigin.dy,
      width: size.width,
      height: size.height,
      child: Opacity(
        opacity: (enter * (1 - phases.sinkFade)).clamp(0, 1),
        child: Transform.translate(
          offset: Offset(0, dy),
          child: Transform.scale(
            scale: scale,
            child: Semantics(
              button: !opened,
              label: opened ? null : '拆开红包',
              onTap: opened ? null : _tear,
              child: GestureDetector(
                onTap: _tear,
                child: Stack(clipBehavior: Clip.none, children: [
                  Positioned.fill(child: CustomPaint(painter: const _BackPainter())),
                  if (flapBehind) Positioned.fill(child: flapLayer),
                  // 卡片在红包里时画在后片与前袋之间（见 _card 里的升起），这里只留前袋。
                  Positioned.fill(child: CustomPaint(painter: _PocketPainter(caption: '开发者送你一个红包'))),
                  if (!flapBehind) Positioned.fill(child: flapLayer),
                  if (phases.coinGone < 1)
                    Positioned(
                      left: size.width / 2 - geometry.coin / 2,
                      top: geometry.arcBottom - geometry.coin / 2,
                      width: geometry.coin,
                      height: geometry.coin,
                      child: Opacity(
                        opacity: 1 - phases.coinGone,
                        child: Transform(
                          alignment: Alignment.center,
                          transform: Matrix4.identity()
                            ..setEntry(3, 2, .002)
                            ..rotateY(coinTurn)
                            ..scaleByDouble(coinScale, coinScale, 1, 1),
                          child: CustomPaint(painter: _CoinPainter(face: math.cos(coinTurn) >= 0, glow: opened ? 0 : _breath.value, shine: opened ? -1 : _shine.value)),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool get opened => _open.value > 0;

  Widget _card(BuildContext context, _Geometry geometry, _Phases phases, double enter, double exit) {
    final envelope = widget.envelope && !_reduced;
    // 从红包里升起：起点在红包中间（被前袋挡住），升到封口之上，再落到屏幕正中、放大到正常大小。
    final insideCenter = geometry.envelopeCenter + Offset(0, geometry.screen.height * .55 * phases.sink);
    final aboveCenter = Offset(geometry.envelopeCenter.dx, geometry.envelopeOrigin.dy - geometry.envelope.height * .08);
    final center = envelope
        ? Offset.lerp(Offset.lerp(insideCenter, aboveCenter, phases.rise), geometry.cardCenter, phases.settle)!
        : geometry.cardCenter + Offset(0, 18 * (1 - enter));
    final inner = geometry.envelope.width * .86 / geometry.cardWidth;
    final scale = (envelope ? ui.lerpDouble(inner, 1, phases.settle)! : .94 + .06 * enter) * (1 - .04 * exit);
    // 封口翻过一半（约 90°）之前卡片还被封口盖着，不画。
    final opacity = (envelope ? (phases.flap >= .55 ? 1.0 : 0.0) : enter) * (1 - exit);
    // 还在红包里的那段：只露出封口以上的部分（前袋挡住下面），卡片升出前袋后整张露出。
    final clipTop = envelope && phases.settle < 1 ? geometry.envelopeOrigin.dy + geometry.flapLine + geometry.screen.height * .55 * phases.sink : null;
    Widget card = SizedBox(
      width: geometry.cardWidth,
      child: _PrizeCard(
        prize: widget.prize,
        title: widget.title,
        qrKey: _qrKey,
        onPrimary: _primary,
        onSave: widget.prize.kind == FestivalPrizeKind.qrCode && widget.saveQrCode != null ? _saveQrCode : null,
        onClose: _close,
      ),
    );
    card = Transform.scale(scale: scale, child: card);
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: phases.settle < 1 || _closing,
        child: ClipPath(
          clipper: _AboveLine(clipTop, enabled: envelope && phases.rise < 1),
          child: CustomSingleChildLayout(
            delegate: _CenterAt(center),
            child: Opacity(opacity: opacity.clamp(0, 1), child: card),
          ),
        ),
      ),
    );
  }
}

// 纸片的颜色：金、浅金、玫瑰金、红、象牙白，正反两面。
const _papers = [
  ConfettiPaper(Color(0xFFF6D46E), Color(0xFFC79A35)),
  ConfettiPaper(Color(0xFFFFEFB5), Color(0xFFD9BE76)),
  ConfettiPaper(Color(0xFFF3B489), Color(0xFFC47F58)),
  ConfettiPaper(Color(0xFFE8473B), Color(0xFFA42420)),
  ConfettiPaper(Color(0xFFFFFCF2), Color(0xFFD8D0BE)),
];

// 拆开时间线的各段（0–1 的 _open 进度里各占一段，彼此交叠，动作接得上）。
class _Phases {
  _Phases(double t)
    : spin = Curves.easeInOutCubic.transform(_span(t, 0, .40)),
      coinGone = Curves.easeIn.transform(_span(t, .34, .46)),
      flap = Curves.easeInOutCubic.transform(_span(t, .40, .64)),
      flapFade = _span(t, .56, .70),
      rise = Curves.easeOutCubic.transform(_span(t, .50, .80)),
      sink = Curves.easeInQuad.transform(_span(t, .60, .88)),
      sinkFade = Curves.easeIn.transform(_span(t, .74, .90)),
      settle = Curves.easeOutCubic.transform(_span(t, .70, 1)),
      rays = Curves.easeOut.transform(_span(t, .60, .92));
  static const burst = .62;
  final double spin, coinGone, flap, flapFade, rise, sink, sinkFade, settle, rays;

  static double _span(double t, double from, double to) => ((t - from) / (to - from)).clamp(0, 1);
}

// 版面：红包宽约屏宽七成（最宽 300）、高宽比 3:2，稍偏上；封口两侧接在 30% 高处，弧底在 44%；「開」直径约宽的 28%。
// 卡片宽 = 屏宽减两侧各 24（最宽 340），停在安全区内的正中。
class _Geometry {
  _Geometry(this.screen, EdgeInsets padding)
    : envelope = Size(math.min(screen.width * .72, 300), math.min(screen.width * .72, 300) * 1.5),
      cardWidth = math.min(screen.width - 48, 340),
      safeCenter = Offset(screen.width / 2, padding.top + (screen.height - padding.top - padding.bottom) / 2);
  final Size screen;
  final Size envelope;
  final double cardWidth;
  final Offset safeCenter;

  Offset get envelopeCenter => Offset(screen.width / 2, safeCenter.dy - screen.height * .02);
  Offset get envelopeOrigin => envelopeCenter - Offset(envelope.width / 2, envelope.height / 2);
  Offset get cardCenter => safeCenter;
  double get flapLine => envelope.height * .30;
  double get arcBottom => envelope.height * .44;
  double get coin => envelope.width * .28;

  // 礼花从封口处喷出：offset 是相对红包宽的横向偏移（−0.5 到 0.5），返回画布上的相对坐标。
  Offset mouth(Size canvas, double offset) => Offset((envelopeCenter.dx + offset * envelope.width) / canvas.width, (envelopeOrigin.dy + flapLine * .5) / canvas.height);
}

class _CenterAt extends SingleChildLayoutDelegate {
  _CenterAt(this.center);
  final Offset center;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();
  @override
  Offset getPositionForChild(Size size, Size childSize) => center - Offset(childSize.width / 2, childSize.height / 2);
  @override
  bool shouldRelayout(_CenterAt oldDelegate) => oldDelegate.center != center;
}

// 卡片还在红包里时只画封口线以上的部分（前袋挡住的部分不画，不然会从红包下沿露出来）。
class _AboveLine extends CustomClipper<Path> {
  _AboveLine(this.line, {required this.enabled});
  final double? line;
  final bool enabled;
  @override
  Path getClip(Size size) => Path()..addRect(Rect.fromLTRB(0, 0, size.width, enabled && line != null ? line! : size.height));
  @override
  bool shouldReclip(_AboveLine oldClipper) => oldClipper.line != line || oldClipper.enabled != enabled;
}

class _ScrimPainter extends CustomPainter {
  _ScrimPainter({required this.opacity, required this.warmth});
  final double opacity;
  final double warmth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = Colors.black.withValues(alpha: .66 * opacity));
    canvas.drawRect(rect, Paint()..shader = RadialGradient(colors: [const Color(0xFFB4281F).withValues(alpha: .38 * opacity * warmth), const Color(0x00B4281F)], radius: .75).createShader(rect));
  }

  @override
  bool shouldRepaint(_ScrimPainter oldDelegate) => oldDelegate.opacity != opacity || oldDelegate.warmth != warmth;
}

// 卡片后面的光：一团暖金的柔光，加上从中心放出的细光束（扫描渐变的条纹，按距离渐隐），整体很淡，只衬出卡片。
class _RaysPainter extends CustomPainter {
  _RaysPainter({required this.center, required this.radius});
  final Offset center;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final area = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(center, radius, Paint()..shader = RadialGradient(colors: [_gold.withValues(alpha: .30), _gold.withValues(alpha: .10), _gold.withValues(alpha: 0)], stops: const [0, .4, 1]).createShader(area));
    canvas.saveLayer(area, Paint());
    const beams = 18;
    canvas.drawCircle(center, radius, Paint()..shader = SweepGradient(
      center: Alignment.center,
      colors: [_goldLight.withValues(alpha: 0), _goldLight.withValues(alpha: .22), _goldLight.withValues(alpha: 0)],
      stops: const [.3, .5, .7],
      endAngle: math.pi * 2 / beams,
      tileMode: TileMode.repeated,
    ).createShader(area));
    // 光束按距离渐隐：中心最亮，外缘没有。
    canvas.drawCircle(center, radius, Paint()
      ..blendMode = BlendMode.dstIn
      ..shader = RadialGradient(colors: [Colors.white, Colors.white.withValues(alpha: .35), Colors.white.withValues(alpha: 0)], stops: const [.15, .5, 1]).createShader(area));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RaysPainter oldDelegate) => oldDelegate.center != center || oldDelegate.radius != radius;
}

// 红包的后片（里面）：拆开后从封口看进去是它。投影也由它画。
class _BackPainter extends CustomPainter {
  const _BackPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final shape = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(20));
    canvas.drawShadow(Path()..addRRect(shape), Colors.black, 18, false);
    canvas.drawRRect(shape, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_inside, Color(0xFFA51E1A)]).createShader(Offset.zero & size));
  }

  @override
  bool shouldRepaint(_BackPainter oldDelegate) => false;
}

// 前袋：封口线以下，自上而下由亮到深，左上来光；同色暗纹是从下方荡开的几道细水波；下部金色小饰线与金字「开发者送你一个红包」。
class _PocketPainter extends CustomPainter {
  _PocketPainter({required this.caption});
  final String caption;

  @override
  void paint(Canvas canvas, Size size) {
    final top = size.height * .30;
    final body = RRect.fromLTRBAndCorners(0, top, size.width, size.height, bottomLeft: const Radius.circular(20), bottomRight: const Radius.circular(20));
    final rect = Offset.zero & size;
    canvas.drawRRect(body, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_crimson, _crimsonDeep]).createShader(rect));
    canvas.drawRRect(body, Paint()..shader = RadialGradient(center: const Alignment(-.55, -.2), radius: .9, colors: [Colors.white.withValues(alpha: .09), Colors.white.withValues(alpha: 0)]).createShader(rect));
    canvas.save();
    canvas.clipRRect(body);
    final ripple = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = const Color(0xFF7A0F0C).withValues(alpha: .13);
    for (var ring = 0; ring < 7; ring++) {
      canvas.drawCircle(Offset(size.width / 2, size.height * 1.08), size.width * (.32 + ring * .1), ripple);
    }
    canvas.restore();
    final ornament = size.height * .675, half = size.width * .16;
    final line = Paint()
      ..strokeWidth = 1
      ..color = _gold.withValues(alpha: .65);
    canvas.drawLine(Offset(size.width / 2 - half, ornament), Offset(size.width / 2 - 9, ornament), line);
    canvas.drawLine(Offset(size.width / 2 + 9, ornament), Offset(size.width / 2 + half, ornament), line);
    canvas.drawPath(
      Path()
        ..moveTo(size.width / 2, ornament - 3.5)
        ..lineTo(size.width / 2 + 3.5, ornament)
        ..lineTo(size.width / 2, ornament + 3.5)
        ..lineTo(size.width / 2 - 3.5, ornament)
        ..close(),
      Paint()..color = _gold.withValues(alpha: .85),
    );
    final text = TextPainter(
      text: TextSpan(text: caption, style: TextStyle(fontSize: 15, letterSpacing: 3, color: _goldLight.withValues(alpha: .92), fontWeight: FontWeight.w500)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 40);
    text.paint(canvas, Offset((size.width - text.width) / 2, size.height * .75 - text.height / 2));
    text.dispose();
  }

  @override
  bool shouldRepaint(_PocketPainter oldDelegate) => oldDelegate.caption != caption;
}

// 封口：上沿圆角，两侧接在 30% 高处，下沿是向下凸的弧（弧底 44%）；正面亮红带金色细线与金字节日名，翻过去是里面的暗红。
class _FlapPainter extends CustomPainter {
  _FlapPainter({required this.title, required this.inside, required this.fade});
  final String title;
  final bool inside;
  final double fade;

  static Path shape(Size size) {
    final join = size.height * .30, bottom = size.height * .44;
    const radius = 20.0;
    return Path()
      ..moveTo(0, radius)
      ..arcToPoint(const Offset(radius, 0), radius: const Radius.circular(radius))
      ..lineTo(size.width - radius, 0)
      ..arcToPoint(Offset(size.width, radius), radius: const Radius.circular(radius))
      ..lineTo(size.width, join)
      ..quadraticBezierTo(size.width / 2, 2 * bottom - join, 0, join)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (fade >= 1) return;
    final path = shape(size), rect = Offset.zero & Size(size.width, size.height * .44);
    canvas.saveLayer(Offset.zero & size, Paint()..color = Colors.white.withValues(alpha: 1 - fade));
    if (inside) {
      canvas.drawPath(path, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF7E1412), _inside]).createShader(rect));
      canvas.restore();
      return;
    }
    // 封口压在前袋上的影子：同形状往下错一点、模糊，比材质投影更贴纸。
    canvas.drawPath(path.shift(const Offset(0, 5)), Paint()
      ..color = const Color(0xFF4A0705).withValues(alpha: .38)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    canvas.drawPath(path, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_flapLight, _flapDeep]).createShader(rect));
    canvas.drawPath(path, Paint()..shader = RadialGradient(center: const Alignment(-.6, -.9), radius: 1.1, colors: [Colors.white.withValues(alpha: .16), Colors.white.withValues(alpha: 0)]).createShader(rect));
    final join = size.height * .30, bottom = size.height * .44;
    canvas.drawPath(
      Path()
        ..moveTo(size.width, join)
        ..quadraticBezierTo(size.width / 2, 2 * bottom - join, 0, join),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = _gold.withValues(alpha: .7),
    );
    final text = TextPainter(
      text: TextSpan(text: title, style: const TextStyle(fontSize: 21, letterSpacing: 6, color: _goldLight, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: size.width - 48);
    text.paint(canvas, Offset((size.width - text.width) / 2, size.height * .135 - text.height / 2));
    text.dispose();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FlapPainter oldDelegate) => oldDelegate.title != title || oldDelegate.inside != inside || oldDelegate.fade != fade;
}

// 金色「開」：球面感的金（左上高光、边缘压深）、内圈细线、深红字；呼吸时背后一圈金色光晕，隔一会儿斜着掠过一道光。转到背面只画金面。
class _CoinPainter extends CustomPainter {
  _CoinPainter({required this.face, required this.glow, required this.shine});
  final bool face;
  final double glow;
  // 掠光的位置（0–1 是一次扫过的进度，只用前四成扫，其余停着；负数不画）。
  final double shine;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero), radius = size.width / 2;
    if (glow > 0) {
      canvas.drawCircle(center, radius * 1.55, Paint()..shader = RadialGradient(colors: [_gold.withValues(alpha: .22 + .22 * glow), _gold.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: center, radius: radius * 1.55)));
    }
    final disc = Path()..addOval(Rect.fromCircle(center: center, radius: radius));
    canvas.drawShadow(disc, Colors.black, 6, false);
    canvas.drawCircle(center, radius, Paint()..shader = const RadialGradient(center: Alignment(-.35, -.4), radius: 1.05, colors: [_goldLight, _gold, _goldDeep], stops: [0, .5, 1]).createShader(Rect.fromCircle(center: center, radius: radius)));
    canvas.drawCircle(center, radius * .84, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = _goldDeep.withValues(alpha: .75));
    if (shine >= 0 && shine < .4) {
      final sweep = shine / .4;
      canvas.save();
      canvas.clipPath(disc);
      final x = center.dx - radius * 1.6 + sweep * radius * 3.2;
      canvas.drawRect(
        Rect.fromLTWH(x - radius * .35, center.dy - radius * 1.2, radius * .7, radius * 2.4),
        Paint()..shader = LinearGradient(colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: .55), Colors.white.withValues(alpha: 0)]).createShader(Rect.fromLTWH(x - radius * .35, 0, radius * .7, 1)),
      );
      canvas.restore();
    }
    if (!face) return;
    final text = TextPainter(
      text: TextSpan(text: '開', style: TextStyle(fontSize: radius * .92, height: 1, color: _ink, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, center - Offset(text.width / 2, text.height / 2));
    text.dispose();
  }

  @override
  bool shouldRepaint(_CoinPainter oldDelegate) => oldDelegate.face != face || oldDelegate.glow != glow || oldDelegate.shine != shine;
}

// 奖品卡：卡头同红包封口（红底、下沿金线弧、金字节日名与奖品类型），下面象牙白卡纸、金色细边；口令或二维码、附言、操作。
class _PrizeCard extends StatelessWidget {
  const _PrizeCard({required this.prize, required this.title, required this.qrKey, required this.onPrimary, required this.onSave, required this.onClose});
  final FestivalPrize prize;
  final String title;
  final GlobalKey qrKey;
  final VoidCallback onPrimary;
  final VoidCallback? onSave;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final password = prize.kind == FestivalPrizeKind.password;
    // 卡头同红包的封口：红底、下沿向下凸的弧带金细线，金字节日名；下面是象牙白卡纸。
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _paper,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _paperEdge),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 36, offset: Offset(0, 18))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(23),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          CustomPaint(
            painter: const _CardHeaderPainter(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 34),
              child: Column(children: [
                Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: 3, color: _goldLight)),
                const SizedBox(height: 4),
                Text(password ? '支付宝口令红包' : '支付宝红包', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, letterSpacing: 1, color: _goldLight.withValues(alpha: .82))),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (password)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(color: const Color(0xFFFBEFD6), borderRadius: BorderRadius.circular(16), border: Border.all(color: _gold.withValues(alpha: .6))),
                  child: SelectableText(prize.content, textAlign: TextAlign.center, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600, letterSpacing: 3, height: 1.3, color: _ink)),
                )
              else
                Center(child: RepaintBoundary(
                  key: qrKey,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _gold.withValues(alpha: .6))),
                    child: SizedBox.square(dimension: 188, child: PrettyQrView.data(data: prize.content, errorCorrectLevel: QrErrorCorrectLevel.M)),
                  ),
                )),
              if (prize.note.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(prize.note, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, height: 1.5, color: _brown)),
              ],
              const SizedBox(height: 20),
              _RedButton(icon: password ? CampusIcons.copy : CampusIcons.open, label: password ? '复制口令，去支付宝' : '在支付宝里打开', onPressed: onPrimary),
              const SizedBox(height: 4),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (onSave case final onSave?) _PlainButton(icon: CampusIcons.download, label: '保存二维码', onPressed: onSave),
                _PlainButton(icon: CampusIcons.check, label: '收下了', onPressed: onClose),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _CardHeaderPainter extends CustomPainter {
  const _CardHeaderPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final join = size.height - 18, bottom = size.height - 2;
    final shape = Path()
      ..lineTo(size.width, 0)
      ..lineTo(size.width, join)
      ..quadraticBezierTo(size.width / 2, 2 * bottom - join, 0, join)
      ..close();
    final rect = Offset.zero & size;
    canvas.drawPath(shape, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_flapLight, _flapDeep]).createShader(rect));
    canvas.drawPath(shape, Paint()..shader = RadialGradient(center: const Alignment(-.7, -1), radius: 1.2, colors: [Colors.white.withValues(alpha: .14), Colors.white.withValues(alpha: 0)]).createShader(rect));
    canvas.drawPath(
      Path()
        ..moveTo(size.width, join)
        ..quadraticBezierTo(size.width / 2, 2 * bottom - join, 0, join),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = _gold.withValues(alpha: .8),
    );
  }

  @override
  bool shouldRepaint(_CardHeaderPainter oldDelegate) => false;
}

// 卡上的主按钮：红底金字的胶囊，按下整块变暗（全应用的按压反馈，不用水波）。
class _RedButton extends StatefulWidget {
  const _RedButton({required this.icon, required this.label, required this.onPressed});
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  State<_RedButton> createState() => _RedButtonState();
}

class _RedButtonState extends State<_RedButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          constraints: const BoxConstraints(minHeight: 50),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(25),
            gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_flapLight, _crimsonDeep]),
            boxShadow: [BoxShadow(color: _crimsonDeep.withValues(alpha: .35), blurRadius: 12, offset: const Offset(0, 6))],
          ),
          foregroundDecoration: BoxDecoration(borderRadius: BorderRadius.circular(25), color: Colors.black.withValues(alpha: _down ? .16 : 0)),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            CampusIcon(widget.icon, size: 20, color: _goldLight),
            const SizedBox(width: 8),
            Flexible(child: Text(widget.label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _goldLight))),
          ]),
        ),
      ),
    );
  }
}

// 卡上的次要按钮：只有图标与褐色字，按下变暗；不用应用主题的中性胶囊（灰底压在象牙白卡纸上发脏）。
class _PlainButton extends StatefulWidget {
  const _PlainButton({required this.icon, required this.label, required this.onPressed});
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  State<_PlainButton> createState() => _PlainButtonState();
}

class _PlainButtonState extends State<_PlainButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 90),
              opacity: _down ? .55 : 1,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                CampusIcon(widget.icon, size: 18, color: _brown),
                const SizedBox(width: 6),
                Text(widget.label, style: const TextStyle(fontSize: 15, color: _brown)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
