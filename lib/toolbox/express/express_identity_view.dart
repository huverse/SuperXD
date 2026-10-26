import 'dart:async';
import 'dart:math' as math;

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:screen_brightness/screen_brightness.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/toolbox/express/express_controller.dart';
import 'package:superxd/toolbox/express/express_models.dart';

enum _IdentityStyle { barcode, qr }

// 码牌白底的留白与圆角：卡片里一份、全屏一份，放大过程中在两者之间插值；全屏码牌离安全区边缘 _zoomMargin。
const _inlinePadding = 16.0;
const _inlineRadius = 12.0;
const _zoomPadding = 24.0;
const _zoomRadius = 20.0;
const _zoomMargin = 24.0;

// 倒计时那一行：卡片与全屏页共用。到期自动刷新没成功时停在「已过期」，卡片里原地给「刷新」。
String _identityStatus(ExpressController controller, int remaining) => controller.refreshing || controller.running == ExpressAction.identity
    ? '正在刷新身份码'
    : remaining > 0
    ? '有效期剩余 $remaining 秒'
    : '身份码已过期';

void _brightness(Future<void> Function() change) => change().catchError((Object error, StackTrace stack) {
  campusLog('[Express] action=brightness errorType=${error.runtimeType}\n$stack');
});

// 身份码展示：Code128 条码与二维码两种样式（值都是同一串服务端下发的 identification_code），
// 按剩余有效期倒计时，到期由控制器刷新；不缓存、不打印身份码。
// [人工决策-2026-10-19 23:35:59] 本轮不给身份码页加截屏/录屏保护（FLAG_SECURE）：只做不落盘、不打印与「请勿分享」提示；
// 用户选定本轮不加（FLAG_SECURE 需改原生 MainActivity 做按页开关，属额外工程）。
class ExpressIdentityView extends StatefulWidget {
  const ExpressIdentityView({super.key, required this.controller, this.zoomOnOpen = false, this.onZoomed, this.onPin});
  // 身份码、刷新中与到期刷新都取自控制器；全屏页也直接听它，码到期换新时跟着换。
  final ExpressController controller;
  // 从快捷入口来：卡片一出现就直接全屏出示（不从卡片飞入），全屏页推上去后调 onZoomed（人工决策见 express_page.dart 的 _openIdentity）。
  final bool zoomOnOpen;
  final VoidCallback? onZoomed;
  // 「添加到桌面」：为空（系统不支持、测试）时不显示这个按钮。
  final VoidCallback? onPin;

  @override
  State<ExpressIdentityView> createState() => _ExpressIdentityViewState();
}

class _ExpressIdentityViewState extends State<ExpressIdentityView> {
  _IdentityStyle _style = _IdentityStyle.barcode;
  late IdentityCodeResult _result = widget.controller.identityCode!;
  // 剩余秒数单独通知：卡片和全屏页里的倒计时都听它，每秒只重画这一行。
  final _remaining = ValueNotifier<int>(0);
  Timer? _ticker;
  final _plate = GlobalKey();
  _IdentityZoomRoute? _zoom;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_follow);
    _resetCountdown();
    if (widget.zoomOnOpen) WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_zoomIn(appear: true)));
  }

  @override
  void didUpdateWidget(covariant ExpressIdentityView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_follow);
    widget.controller.addListener(_follow);
  }

  // 控制器拿到新码（到期刷新、重新生成）就重新倒计时；控制器只在请求结束时通知，不在构建期间。
  void _follow() {
    final result = widget.controller.identityCode;
    if (result == null || identical(result, _result)) return;
    setState(() => _result = result);
    _resetCountdown();
  }

  void _resetCountdown() {
    _ticker?.cancel();
    _remaining.value = math.max(0, (_result.expireMills / 1000).floor());
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remaining.value > 0) _remaining.value--;
      if (_remaining.value > 0) return;
      timer.cancel();
      widget.controller.refreshIdentityCode().catchError((Object error, StackTrace stack) {
        campusLog('[Express] action=refresh_code errorType=${error.runtimeType}\n$stack');
      });
    });
  }

  // 到期自动刷新没成功时手动再取一次；失败原因用提示条（登录失效时页面已回到登录态，原因写在登录页）。
  Future<void> _refresh() async {
    final controller = widget.controller;
    await controller.refreshIdentityCode();
    if (mounted && controller.loggedIn && controller.error != null) showCampusToast(context, controller.error!);
  }

  // [人工决策-2026-10-20 13:03:42] 点码牌全屏出示（用户选定，同支付宝、微信付款码）：码牌从卡片里原地放大进整屏白底，条码转 90° 沿屏幕长边铺开、
  // 码值与倒计时随码牌一起转，二维码只放大；全屏期间本页屏幕亮度调到最高、关掉即恢复（只改本应用窗口，同添加好友页）。
  // 点任意处或返回关闭，码牌原路缩回卡片；时长与曲线同页面转场。白底不随深色模式变：高拍仪要扫，对比度优先。
  // appear：从快捷入口来时直接出现在全屏（不从卡片飞入），推上去后告诉页面（onZoomed）；关掉时照样缩回卡片。
  Future<void> _zoomIn({bool appear = false}) async {
    final box = _plate.currentContext?.findRenderObject();
    if (_zoom != null || box is! RenderBox || !box.hasSize) return;
    final route = _IdentityZoomRoute(
      express: widget.controller,
      remaining: _remaining,
      style: _style,
      source: _plate,
      origin: box.localToGlobal(Offset.zero) & box.size,
      instant: MediaQuery.disableAnimationsOf(context),
      appear: appear,
    );
    _zoom = route;
    _brightness(() => ScreenBrightness.instance.setApplicationScreenBrightness(1));
    final popped = Navigator.of(context).push(route);
    if (appear) widget.onZoomed?.call();
    // 缩回动画走完才算关掉，之后才能再点开。
    late final AnimationStatusListener landed;
    landed = (status) {
      if (!status.isDismissed) return;
      route.animation!.removeStatusListener(landed);
      _zoom = null;
    };
    route.animation!.addStatusListener(landed);
    await popped;
    _brightness(ScreenBrightness.instance.resetApplicationScreenBrightness);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_follow);
    _ticker?.cancel();
    // 退出登录、会话失效时卡片被拿掉：全屏页跟着关、亮度复原（不能在销毁过程中改路由，放到这一帧之后）。
    final zoom = _zoom;
    if (zoom != null) {
      _brightness(ScreenBrightness.instance.resetApplicationScreenBrightness);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (zoom.isActive) zoom.navigator?.removeRoute(zoom);
      });
    }
    _remaining.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final code = _result.identificationCode;
    final mobileDesc = _result.mobileInfo?.desc ?? '';
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CampusSegmented<_IdentityStyle>(
          values: const [_IdentityStyle.barcode, _IdentityStyle.qr],
          selected: _style,
          label: (value) => value == _IdentityStyle.barcode ? '条码' : '二维码',
          onSelected: (value) => setState(() => _style = value),
        ),
        const SizedBox(height: 16),
        // [人工决策-2026-10-26 18:57:10] 身份码默认盖遮罩（用户选定，同微信付款码的数字平时打码）：卡片里只画一块与码牌同大的色调盖板、写「点击展开」，
        // 码与码值都不在卡片里露出；点一下直接全屏出示（见 _zoomIn），缩回后仍盖着。快捷入口照旧直接全屏（见 express_page.dart 的 _openIdentity）。
        // 未选「只揭开遮罩、码留在卡片里」「模糊的码」「快捷入口也先盖遮罩」。码牌照原尺寸排在盖板下面但不画，只给全屏的飞出与缩回定位。
        Center(
          child: LayoutBuilder(builder: (context, constraints) {
            final size = _style == _IdentityStyle.qr ? const Size.square(220) : Size(math.min(260, constraints.maxWidth - 2 * _inlinePadding), 120);
            return Semantics(
              button: true,
              label: '展开身份码',
              onTap: _zoomIn,
              excludeSemantics: true,
              child: Stack(children: [
                Visibility.maintain(
                  visible: false,
                  child: _CodePlate(key: _plate, code: code, style: _style, size: size, padding: _inlinePadding, radius: _inlineRadius),
                ),
                Positioned.fill(child: _IdentityMask(onTap: _zoomIn)),
              ]),
            );
          }),
        ),
        const SizedBox(height: 4),
        if (mobileDesc.isNotEmpty) ...[
          const SizedBox(height: 8),
          Center(child: Text(mobileDesc, style: textTheme.bodyMedium?.copyWith(color: palette.onSurfaceVariant))),
        ],
        const SizedBox(height: 8),
        ValueListenableBuilder<int>(
          valueListenable: _remaining,
          builder: (context, remaining, _) {
            final controller = widget.controller;
            final expired = remaining <= 0 && !controller.refreshing && controller.running != ExpressAction.identity;
            return Column(children: [
              Text(_identityStatus(controller, remaining), style: textTheme.bodyMedium?.copyWith(color: palette.attention)),
              if (expired)
                Padding(padding: const EdgeInsets.only(top: 8), child: OutlinedButton.icon(onPressed: controller.busy ? null : _refresh, icon: const CampusIcon(CampusIcons.sync), label: const Text('刷新'))),
            ]);
          },
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            '为避免快递丢失，请勿随意分享身份码',
            style: textTheme.bodyMedium?.copyWith(color: palette.onSurfaceVariant),
          ),
        ),
        if (widget.onPin != null) ...[
          const SizedBox(height: 8),
          Center(child: TextButton.icon(onPressed: widget.onPin, icon: const CampusIcon(CampusIcons.pin), label: const Text('添加到桌面'))),
        ],
      ],
    );
  }
}

// 从快捷入口打开、身份码还在生成时盖住快递页的白底（同全屏出示的白底，生成好直接换成全屏码），原地转圈。
// 白底不随深色模式变，转圈与文字取浅色配色。
class ExpressIdentityPending extends StatelessWidget {
  const ExpressIdentityPending({super.key});

  @override
  Widget build(BuildContext context) {
    final light = CampusPalette.byId(CampusPalette.of(context).id);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: campusSystemOverlay(light),
      child: Material(
        color: Colors.white,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CampusLoader(color: light.primary),
            const SizedBox(height: 12),
            Text('正在生成身份码', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: light.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}

// 卡片里盖住身份码的盖板：色调底（同内容区按钮的色调胶囊，按下加深一档）、眼睛图标加「点击展开」，看不出码。
class _IdentityMask extends StatefulWidget {
  const _IdentityMask({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_IdentityMask> createState() => _IdentityMaskState();
}

class _IdentityMaskState extends State<_IdentityMask> {
  bool _pressed = false;

  void _press(bool pressed) => setState(() => _pressed = pressed);

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final alpha = palette.isDark ? (_pressed ? .22 : .14) : (_pressed ? .14 : .08);
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => _press(true),
      onTapUp: (_) => _press(false),
      onTapCancel: () => _press(false),
      child: DecoratedBox(
        decoration: BoxDecoration(color: palette.primary.withValues(alpha: alpha), borderRadius: BorderRadius.circular(_inlineRadius)),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CampusIcon(CampusIcons.eye, size: 28, color: palette.primary),
            const SizedBox(height: 8),
            Text('点击展开', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: palette.primary)),
          ]),
        ),
      ),
    );
  }
}

// 码牌：白底圆角里一张条码或二维码；全屏时下面带码值与倒计时，footerFactor 从 0 到 1 展开并淡入。
class _CodePlate extends StatelessWidget {
  const _CodePlate({super.key, required this.code, required this.style, required this.size, required this.padding, required this.radius, this.footer, this.footerFactor = 0});
  final String code;
  final _IdentityStyle style;
  final Size size;
  final double padding;
  final double radius;
  final Widget? footer;
  final double footerFactor;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(padding),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(radius)),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox.fromSize(
        size: size,
        child: style == _IdentityStyle.qr
            ? PrettyQrView.data(
                data: code,
                decoration: const PrettyQrDecoration(
                  shape: PrettyQrSmoothSymbol(color: Colors.black, roundFactor: 0),
                  background: Colors.white,
                ),
              )
            : BarcodeWidget(
                barcode: Barcode.code128(),
                data: code,
                width: size.width,
                height: size.height,
                drawText: false,
                color: Colors.black,
                backgroundColor: Colors.white,
              ),
      ),
      if (footer != null && footerFactor > 0)
        ClipRect(child: Align(alignment: Alignment.topCenter, heightFactor: footerFactor, child: Opacity(opacity: footerFactor, child: footer))),
    ]),
  );
}

// 全屏出示的路由：不透明度、位置、大小、旋转都按同一条路由进度插值，码牌从卡片里那张的位置飞到屏幕正中。
// 是浮层（登记层数，背景动效停住）；返回键、点任意处都关闭。
class _IdentityZoomRoute extends PopupRoute<void> with CampusOverlayDepthRoute<void> {
  _IdentityZoomRoute({required this.express, required this.remaining, required this.style, required this.source, required this.origin, required this.instant, required this.appear});
  final ExpressController express;
  final ValueListenable<int> remaining;
  final _IdentityStyle style;
  final GlobalKey source;
  final Rect origin;
  // 减少动画时直接出现、直接消失。
  final bool instant;
  // 从快捷入口来：直接出现（关掉时照样缩回卡片）。
  final bool appear;

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => false;
  @override
  String? get barrierLabel => null;
  @override
  Duration get transitionDuration => instant || appear ? Duration.zero : campusEnter;
  @override
  Duration get reverseTransitionDuration => instant ? Duration.zero : campusExit;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) => _IdentityZoom(route: this, animation: animation);
}

class _IdentityZoom extends StatefulWidget {
  const _IdentityZoom({required this.route, required this.animation});
  final _IdentityZoomRoute route;
  final Animation<double> animation;

  @override
  State<_IdentityZoom> createState() => _IdentityZoomState();
}

class _IdentityZoomState extends State<_IdentityZoom> {
  // 同页面转场的临界阻尼弹簧曲线（先快后慢、不回弹，见 campus_motion.dart）。
  late final _progress = CurvedAnimation(parent: widget.animation, curve: campusSpringCurve, reverseCurve: campusSpringCurve.flipped);
  late Rect _origin = widget.route.origin;

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  // 卡片里那张码牌此刻的位置：缩回时它可能挪过（列表重排），每帧重新取，取不到就用上一次的。
  Rect _source() {
    final box = widget.route.source.currentContext?.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) _origin = box.localToGlobal(Offset.zero) & box.size;
    return _origin;
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final media = MediaQuery.of(context);
    final light = CampusPalette.byId(CampusPalette.of(context).id);
    final area = media.padding.deflateRect(Offset.zero & media.size);
    final rotated = route.style == _IdentityStyle.barcode;
    // 码值一行加倒计时一行的高度（宁大勿小，只用来给码让出位置）。
    final footerHeight = 16 + media.textScaler.scale(20) * 1.5 + media.textScaler.scale(14) * 1.5;
    // 全屏码牌在未旋转朝向下的尺寸：条码转 90° 后长边沿屏幕高度铺开，二维码按短边放大。
    final along = (rotated ? area.height : area.width) - 2 * (_zoomMargin + _zoomPadding);
    final across = (rotated ? area.width : area.height) - 2 * (_zoomMargin + _zoomPadding) - footerHeight;
    final target = rotated ? Size(along, math.min(across, along * .4)) : Size.square(math.min(along, across));
    // 浮层路由下没有页面的 Material：补一层透明的，文字才有应用的默认字体与样式。
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: campusSystemOverlay(light),
      child: Material(
        type: MaterialType.transparency,
        child: Semantics(
          button: true,
          label: '关闭全屏身份码',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).pop(),
            child: ListenableBuilder(
              listenable: Listenable.merge([_progress, route.express]),
              builder: (context, _) {
                final progress = _progress.value.clamp(0.0, 1.0);
                final result = route.express.identityCode;
                final source = _source();
                final from = Size(source.width - 2 * _inlinePadding, source.height - 2 * _inlinePadding);
                final center = Offset.lerp(source.center, area.center, progress)!;
                final size = Size.lerp(from, target, progress)!;
                final footer = result == null ? null : SizedBox(
                  width: size.width,
                  child: Column(children: [
                    const SizedBox(height: 12),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(result.identificationCode, maxLines: 1, style: TextStyle(fontFamily: 'monospace', fontSize: 20, fontWeight: FontWeight.w600, color: light.onSurface)),
                    ),
                    const SizedBox(height: 4),
                    ValueListenableBuilder<int>(
                      valueListenable: route.remaining,
                      builder: (context, remaining, _) => Text(
                        _identityStatus(route.express, remaining),
                        style: TextStyle(fontSize: 14, color: light.attention),
                      ),
                    ),
                  ]),
                );
                return Stack(children: [
                  Positioned.fill(child: ColoredBox(color: Colors.white.withValues(alpha: progress))),
                  if (result != null)
                    Positioned(
                      left: center.dx,
                      top: center.dy,
                      child: FractionalTranslation(
                        translation: const Offset(-.5, -.5),
                        // 卡片里是盖板：码牌出发时从盖板上淡入、缩回到底前淡出，不在盖板上突然闪出一块白。
                        child: Opacity(
                          opacity: const Interval(0, .2).transform(progress),
                          child: Transform.rotate(
                            angle: rotated ? progress * math.pi / 2 : 0,
                            child: _CodePlate(
                              code: result.identificationCode,
                              style: route.style,
                              size: size,
                              padding: _inlinePadding + (_zoomPadding - _inlinePadding) * progress,
                              radius: _inlineRadius + (_zoomRadius - _inlineRadius) * progress,
                              footer: footer,
                              footerFactor: const Interval(.4, 1).transform(progress),
                            ),
                          ),
                        ),
                      ),
                    ),
                ]);
              },
            ),
          ),
        ),
      ),
    );
  }
}
