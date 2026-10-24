import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:superxd/domain/festival.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'festival_catalog.dart';
import 'festival_stage.dart';
import 'reward_card.dart';
import 'reward_kit.dart';
import 'reward_stardust.dart';

// 奖品揭晓（预制，所有节日共用；抽签与时机的人工决策见 domain/festival.dart）。本文件是入口、时间线与操作，画面分两部分：
// 开启动效（等点的那件东西与拆开的那一段，reward_stardust.dart）与奖品卡容器（reward_card.dart，外形、主题画的背景层、内容层）。
// 主题跟着这一次节日走（festival_catalog.dart 里场景的 reward，没登记用默认的流光卡 reward_glow.dart），定配色与卡面；
// 默认主题的颜色取应用配色的激活色。等点的那件东西浮起，点开（或读屏的「拆开红包」）后走完拆开的时间线，奖品卡停在屏幕正中；
// 卡上口令（大字、可复制）或二维码、附言，主操作一键复制口令并打开支付宝 / 在支付宝里打开二维码，「收下了」关闭。
// 不拆（「我的」里再打开）与减少动画时直接是卡片，不放光效与粒子、不震动。
// 支付宝没有公开的应用链接文档：二维码用社区实测可用的「扫一扫」链接带 qrcode 参数，口令只打开支付宝，都还没在真机上验过。

// [人工决策-2026-10-24 19:10:20] 用户嫌第一版（传统红封、封口翻开、礼花）单调、像广告，要现代、简洁加极致美学、不要传统红配金，
// 看过两轮实物后定稿：开启动效用「星尘」（星核外不画环）；奖品卡是第一轮流光卡小幅精修（reward_glow.dart），做成可换主题的容器；
// 镭射卡（翻面、化作星尘）没选，春节红黄主题放弃。改动画面先拿实物给用户比，只在定稿的样子上小步改。

// 二维码：「扫一扫」入口带上二维码内容直接识别；口令：只打开支付宝（口令已经复制，在支付宝里搜「口令红包」粘贴）。
Uri alipayQrUri(String content) => Uri.parse('alipays://platformapi/startapp?saId=10000007&qrcode=${Uri.encodeComponent(content)}');
final alipayHome = Uri.parse('alipays://platformapi/startapp');

// envelope 为假时不拆、直接显示卡片（「我的」里再打开）。saveQrCode 为空时不显示「保存二维码」。卡的主题按奖品那一次节日登记的找。
Future<void> showFestivalReward(BuildContext context, {required FestivalPrize prize, required String title, bool envelope = true, Future<bool> Function(Uint8List png)? saveQrCode, Future<bool> Function(Uri uri)? openUri}) =>
    Navigator.of(context, rootNavigator: true).push(_RewardRoute(prize: prize, title: title, envelope: envelope, saveQrCode: saveQrCode, openUri: openUri ?? (uri) => launchUrl(uri, mode: LaunchMode.externalApplication), theme: festivalRewardTheme(prize.occasion)));

// 浮层路由（不是页面路由，下面的页面不跟着做转场）；进出都由揭晓自己的时间线画，路由本身不做过渡。
class _RewardRoute extends PopupRoute<void> {
  _RewardRoute({required this.prize, required this.title, required this.envelope, required this.saveQrCode, required this.openUri, required this.theme});
  final FestivalPrize prize;
  final String title;
  final bool envelope;
  final Future<bool> Function(Uint8List png)? saveQrCode;
  final Future<bool> Function(Uri uri) openUri;
  final RewardTheme theme;

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
      _RewardReveal(prize: prize, title: title, envelope: envelope, saveQrCode: saveQrCode, openUri: openUri, theme: theme);
}

class _RewardReveal extends StatefulWidget {
  const _RewardReveal({required this.prize, required this.title, required this.envelope, required this.saveQrCode, required this.openUri, required this.theme});
  final FestivalPrize prize;
  final String title;
  final bool envelope;
  final Future<bool> Function(Uint8List png)? saveQrCode;
  final Future<bool> Function(Uri uri) openUri;
  final RewardTheme theme;

  @override
  State<_RewardReveal> createState() => _RewardRevealState();
}

class _RewardRevealState extends State<_RewardReveal> with TickerProviderStateMixin {
  static const RewardLook _look = StardustLook();
  // 主题的配色（默认主题取应用配色的激活色），第一次拿到上下文时定下，揭晓期间不变。
  late RewardPalette _palette;
  // 入场：压暗、等点的东西浮起（不拆时是卡片淡入）。
  late final _enter = AnimationController(vsync: this, duration: const Duration(milliseconds: 680));
  // 拆开的整段时间线（各段由开启动效定）。
  late final _open = AnimationController(vsync: this, duration: _look.openLength);
  late final _exit = AnimationController(vsync: this, duration: const Duration(milliseconds: 280));
  // 慢动效的时钟（秒）与倾斜：等点时自动缓慢摆动，手指拖动时跟手，松手弹回；减少动画时不走。
  late final Ticker _ticker = createTicker(_tick);
  final _clock = ValueNotifier(0.0);
  final _tilt = ValueNotifier(Offset.zero);
  final _pressed = ValueNotifier(false);
  Offset? _drag;
  final _cardKey = GlobalKey();
  final _qrKey = GlobalKey();
  Size? _cardSize;
  bool _burst = false;
  bool _opening = false;
  bool _closing = false;
  late bool _reduced;

  bool get _envelope => widget.envelope && !_reduced;

  @override
  void initState() {
    super.initState();
    _open.addListener(_onOpenTick);
    unawaited(widget.theme.prepare().then((_) {
      if (mounted) setState(() {});
    }));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (_enter.status != AnimationStatus.dismissed) return;
    _palette = widget.theme.palette(CampusPalette.of(context).accent);
    if (!_envelope) {
      _open.value = 1;
      _enter.duration = Duration(milliseconds: _reduced ? 200 : 420);
    }
    if (!_reduced) unawaited(_ticker.start());
    _enter.forward();
  }

  void _tick(Duration elapsed) {
    final seconds = elapsed.inMicroseconds / 1e6;
    final step = seconds - _clock.value;
    _clock.value = seconds;
    // 自动摆动是两个不同周期的正弦（李萨如），不重复、不机械。
    final idle = Offset(math.sin(seconds * .74) * .55, math.sin(seconds * .51 + 1.3) * .45);
    final target = _drag ?? idle;
    final follow = 1 - math.exp(-step * (_drag == null ? 3.2 : 12));
    _tilt.value = Offset.lerp(_tilt.value, target, follow)!;
  }

  void _onOpenTick() {
    // 拆开那一刻：轻震一下。
    if (_burst || _open.value < _look.burstAt) return;
    _burst = true;
    HapticFeedback.lightImpact();
  }

  void _tear() {
    if (_opening || _closing || !_envelope || _open.value > 0) return;
    _opening = true;
    _pressed.value = false;
    _drag = null;
    HapticFeedback.mediumImpact();
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

  // 卡片排好版后量一次大小（还在 Offstage 里也照常排版），等点的那件东西和拆开的动作按它对齐。
  void _measure(Duration _) {
    final size = _cardKey.currentContext?.size;
    if (mounted && size != null && size != _cardSize) setState(() => _cardSize = size);
  }

  // 等点的那件东西：读屏是一个「拆开红包」按钮（里面画的字不单独读）；按下有反馈，拖动时跟着倾斜。
  Widget _seal(Widget child) => Semantics(
    button: true,
    label: '拆开红包',
    excludeSemantics: true,
    onTap: _tear,
    child: Builder(builder: (context) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _pressed.value = true,
      onTapCancel: () => _pressed.value = false,
      onTapUp: (_) => _pressed.value = false,
      onTap: _tear,
      onPanStart: (_) => _pressed.value = false,
      onPanUpdate: (details) {
        final size = context.size;
        if (size == null || _open.value > 0) return;
        _drag = Offset((details.localPosition.dx / size.width * 2 - 1).clamp(-1.0, 1.0), (details.localPosition.dy / size.height * 2 - 1).clamp(-1.0, 1.0));
      },
      onPanEnd: (_) => _drag = null,
      onPanCancel: () => _drag = null,
      child: child,
    )),
  );

  // 停稳的卡跟手：手指在卡上移动时玻璃的反光与主题的视差层跟着倾斜（只听指针、不进手势竞争，卡上的按钮照常点）。
  Widget _follow(Widget card) => Builder(builder: (context) => Listener(
    onPointerMove: (event) {
      final size = context.size;
      if (size == null || _reduced) return;
      _drag = Offset((event.localPosition.dx / size.width * 2 - 1).clamp(-1.0, 1.0), (event.localPosition.dy / size.height * 2 - 1).clamp(-1.0, 1.0));
    },
    onPointerUp: (_) => _drag = null,
    onPointerCancel: (_) => _drag = null,
    child: card,
  ));

  @override
  void dispose() {
    _ticker.dispose();
    for (final controller in [_enter, _open, _exit]) {
      controller.dispose();
    }
    for (final notifier in [_clock, _tilt, _pressed]) {
      notifier.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    SchedulerBinding.instance.addPostFrameCallback(_measure);
    final password = widget.prize.kind == FestivalPrizeKind.password;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: festivalSystemOverlay,
        // 浮层路由不在任何 Material 之下：垫一层透明的，文字照常取应用字体，按钮有墨水层。
        child: Material(type: MaterialType.transparency, child: LayoutBuilder(builder: (context, constraints) {
          final screen = constraints.biggest;
          final cardWidth = math.min(screen.width - 48, 340.0);
          // 卡片内容只建一次，各帧传同一个实例（时间线每帧重建画面时不重建卡片内容），容器按每帧的进度套在外面。
          final inner = KeyedSubtree(
            key: _cardKey,
            child: SizedBox(width: cardWidth, child: RewardCard(
              prize: widget.prize,
              title: widget.title,
              palette: _palette,
              qrKey: _qrKey,
              onPrimary: _primary,
              onSave: !password && widget.saveQrCode != null ? _saveQrCode : null,
              onClose: _close,
              minHeight: cardWidth * rewardCardAspect,
            )),
          );
          return AnimatedBuilder(
            animation: Listenable.merge([_enter, _open, _exit]),
            builder: (context, _) {
              final scene = RewardScene(
                screen: screen,
                padding: MediaQuery.paddingOf(context),
                cardWidth: cardWidth,
                cardSize: _cardSize,
                enter: _enter.value,
                exit: _exit.value,
                open: _open.value,
                envelope: _envelope,
                reduced: _reduced,
                clock: _clock,
                tilt: _tilt,
                pressed: _pressed,
                palette: _palette,
                title: widget.title,
                card: ({double body = 1, double content = 1}) => _follow(RewardContainer(
                  theme: widget.theme,
                  palette: _palette,
                  clock: _clock,
                  tilt: _tilt,
                  still: _reduced,
                  body: body,
                  content: content,
                  child: IgnorePointer(ignoring: _closing || _open.value < 1, child: inner),
                )),
                seal: _seal,
              );
              return Stack(children: _look.layers(context, scene));
            },
          );
        })),
      ),
    );
  }
}
