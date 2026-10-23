import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/painting.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 关于页「开屏画作」（人工决策见 painting_splash.dart）：清单里的全部画作按顺序列出，这次开屏的那幅标出来；每幅可把原图存进相册，
// 按钮原地转圈、存好原地变成「已保存」；点画作从卡片里原地放大成全屏（同快递身份码的全屏出示），可双指缩放，点一下或返回原路缩回。
class PaintingsPage extends StatefulWidget {
  const PaintingsPage({super.key, required this.gallery});
  final PaintingGallery gallery;

  @override
  State<PaintingsPage> createState() => _PaintingsPageState();
}

// 保存状态：列表与全屏页共用，哪边点的另一边都跟着变。
class _SaveState extends ChangeNotifier {
  _SaveState(this.gallery);
  final PaintingGallery gallery;
  final saving = <String>{};
  final saved = <String>{};

  // 存好返回空，没存上返回要提示的原因。
  Future<String?> save(Painting painting) async {
    if (saving.contains(painting.id) || saved.contains(painting.id)) return null;
    saving.add(painting.id);
    notifyListeners();
    final ok = await gallery.save(painting);
    saving.remove(painting.id);
    if (ok) saved.add(painting.id);
    notifyListeners();
    if (!ok) return '保存失败，请重试';
    HapticFeedback.lightImpact();
    return null;
  }
}

class _PaintingsPageState extends State<PaintingsPage> {
  late final _state = _SaveState(widget.gallery);
  final _frames = <String, GlobalKey>{};
  // 正在全屏看的那幅：卡片里那张隐藏、位置保留，飞行时只看得到一张。
  String? _zoomed;

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  Future<void> _save(BuildContext context, Painting painting) async {
    final failure = await _state.save(painting);
    if (failure != null && context.mounted) showCampusToast(context, failure);
  }

  Future<void> _zoom(Painting painting) async {
    final box = _frames[painting.id]?.currentContext?.findRenderObject();
    if (_zoomed != null || box is! RenderBox || !box.hasSize) return;
    final route = _PaintingZoomRoute(
      painting: painting,
      source: _frames[painting.id]!,
      origin: box.localToGlobal(Offset.zero) & box.size,
      state: _state,
      onSave: _save,
      instant: MediaQuery.disableAnimationsOf(context),
    );
    setState(() => _zoomed = painting.id);
    final popped = Navigator.of(context).push(route);
    // 缩回动画结束的同一帧卡片里那张重新露出来（等路由销毁再换要晚一帧，中间会空一下）。
    late final AnimationStatusListener landed;
    landed = (status) {
      if (!status.isDismissed) return;
      route.animation!.removeStatusListener(landed);
      if (mounted) setState(() => _zoomed = null);
    };
    route.animation!.addStatusListener(landed);
    await popped;
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    final current = widget.gallery.current?.id;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('开屏画作'),
      ),
      body: CampusScrollFade(child: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: ListenableBuilder(
        listenable: _state,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final painting in widget.gallery.paintings)
              CampusSurface(
                margin: const EdgeInsets.only(bottom: 16),
                padding: EdgeInsets.zero,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Semantics(
                    button: true,
                    label: '全屏看《${painting.title}》',
                    child: GestureDetector(
                      onTap: () => _zoom(painting),
                      child: AspectRatio(
                        aspectRatio: painting.aspect,
                        child: Visibility.maintain(
                          visible: _zoomed != painting.id,
                          child: LayoutBuilder(
                            key: _frames.putIfAbsent(painting.id, GlobalKey.new),
                            builder: (context, constraints) => Image.asset(
                              painting.asset,
                              fit: BoxFit.cover,
                              cacheWidth: math.min(painting.width, (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context)).round()),
                              filterQuality: FilterQuality.medium,
                              excludeFromSemantics: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                    child: Row(children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('《${painting.title}》', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface)),
                        const SizedBox(height: 2),
                        // 说明与「这次开屏」按项换行，不在窄处折出孤字。
                        DotSeparatedText(painting.id == current ? '${painting.note} · 这次开屏' : painting.note, style: secondary),
                      ])),
                      _SaveButton(painting: painting, state: _state, onSave: () => _save(context, painting)),
                    ]),
                  ),
                ]),
              ),
          ],
        ),
      ))))),
    );
  }
}

// 「保存到相册」：存的时候原地转圈，存好原地变成「已保存」（不可再点）；同名的已经存过时直接算存好。
class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.painting, required this.state, required this.onSave, this.onDark = false});
  final Painting painting;
  final _SaveState state;
  final VoidCallback onSave;
  // 全屏页的黑底上：白字白边。
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final saved = state.saved.contains(painting.id), saving = state.saving.contains(painting.id);
    final content = CampusBusyContent(
      busy: saving,
      label: saved ? '已保存' : '保存到相册',
      busyLabel: '保存中',
      icon: CampusIcon(saved ? CampusIcons.check : CampusIcons.download),
      color: onDark ? Colors.white : null,
    );
    return onDark
        ? OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white54), backgroundColor: Colors.white.withValues(alpha: .08)),
            onPressed: saved || saving ? null : onSave,
            child: content,
          )
        : OutlinedButton(onPressed: saved || saving ? null : onSave, child: content);
  }
}

// 全屏看画的路由：黑底渐显到不透明（半透明时下面卡片的标题、按钮会和全屏页的说明叠在一起），画作从卡片里那张的位置按页面转场同一条弹簧曲线飞到屏幕正中（完整显示、不裁），停稳后可双指缩放。
// 是浮层（登记层数，背景动效停住）；返回键、点一下都原路缩回。
class _PaintingZoomRoute extends PopupRoute<void> with CampusOverlayDepthRoute<void> {
  _PaintingZoomRoute({required this.painting, required this.source, required this.origin, required this.state, required this.onSave, required this.instant});
  final Painting painting;
  final GlobalKey source;
  final Rect origin;
  final _SaveState state;
  final Future<void> Function(BuildContext context, Painting painting) onSave;
  final bool instant;

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => false;
  @override
  String? get barrierLabel => null;
  @override
  Duration get transitionDuration => instant ? Duration.zero : campusEnter;
  @override
  Duration get reverseTransitionDuration => instant ? Duration.zero : campusExit;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) => _PaintingZoom(route: this, animation: animation);
}

class _PaintingZoom extends StatefulWidget {
  const _PaintingZoom({required this.route, required this.animation});
  final _PaintingZoomRoute route;
  final Animation<double> animation;

  @override
  State<_PaintingZoom> createState() => _PaintingZoomState();
}

class _PaintingZoomState extends State<_PaintingZoom> {
  late final _progress = CurvedAnimation(parent: widget.animation, curve: campusSpringCurve, reverseCurve: campusSpringCurve.flipped);
  late Rect _origin = widget.route.origin;
  final _viewer = TransformationController();

  @override
  void dispose() {
    _progress.dispose();
    _viewer.dispose();
    super.dispose();
  }

  // 卡片里那张此刻的位置：缩回时列表可能滚过，每帧重新取，取不到就用上一次的。
  Rect _source() {
    final box = widget.route.source.currentContext?.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) _origin = box.localToGlobal(Offset.zero) & box.size;
    return _origin;
  }

  // 缩回前先把双指放大还原，画作从当前大小原路飞回卡片。
  void _close() {
    _viewer.value = Matrix4.identity();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final painting = route.painting;
    final media = MediaQuery.of(context);
    final footerHeight = 24 + media.textScaler.scale(16) * 1.5 + media.textScaler.scale(14) * 1.5 + 56;
    final area = Rect.fromLTRB(16, media.padding.top + 64, media.size.width - 16, media.size.height - media.padding.bottom - footerHeight);
    final scale = math.min(area.width / painting.width, area.height / painting.height);
    final target = Rect.fromCenter(center: area.center, width: painting.width * scale, height: painting.height * scale);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(statusBarColor: Colors.transparent, systemNavigationBarColor: Colors.transparent, statusBarIconBrightness: Brightness.light, statusBarBrightness: Brightness.dark),
      child: Material(
        type: MaterialType.transparency,
        child: AnimatedBuilder(
          animation: _progress,
          builder: (context, _) {
            final progress = _progress.value.clamp(0.0, 1.0);
            final rect = Rect.lerp(_source(), target, progress)!;
            final chrome = Curves.easeOut.transform(((progress - .5) / .5).clamp(0.0, 1.0));
            final settled = widget.animation.status == AnimationStatus.completed;
            return Stack(children: [
              Positioned.fill(child: GestureDetector(onTap: _close, child: ColoredBox(color: Colors.black.withValues(alpha: progress)))),
              Positioned.fromRect(
                rect: rect,
                child: Semantics(
                  label: '《${painting.title}》，${painting.note}',
                  image: true,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24 * (1 - progress)),
                    // 停稳后才接双指缩放（飞行途中由路由进度决定大小）；点一下照样关闭。
                    child: GestureDetector(
                      onTap: _close,
                      child: InteractiveViewer(
                        transformationController: _viewer,
                        panEnabled: settled,
                        scaleEnabled: settled,
                        maxScale: 4,
                        clipBehavior: Clip.none,
                        child: Image(image: ExactAssetImage(painting.asset), fit: BoxFit.cover, width: rect.width, height: rect.height, filterQuality: FilterQuality.medium, gaplessPlayback: true),
                      ),
                    ),
                  ),
                ),
              ),
              // 关闭按钮与底部说明随画作停稳淡入；黑底上用半透明深色圆底加白色图标（同相机取景页的按钮）。
              Positioned(
                left: 8,
                top: media.padding.top + 8,
                child: Opacity(
                  opacity: chrome,
                  child: IconButton(
                    tooltip: '关闭',
                    onPressed: _close,
                    style: ButtonStyle(backgroundColor: WidgetStatePropertyAll(Colors.white.withValues(alpha: .14)), foregroundColor: const WidgetStatePropertyAll(Colors.white)),
                    icon: const CampusIcon(CampusIcons.close, color: Colors.white),
                  ),
                ),
              ),
              Positioned(
                left: 24,
                right: 24,
                bottom: media.padding.bottom + 16,
                child: Opacity(
                  opacity: chrome,
                  child: ListenableBuilder(
                    listenable: route.state,
                    builder: (context, _) => Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text('《${painting.title}》', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
                        const SizedBox(height: 4),
                        Text(painting.note, style: const TextStyle(fontSize: 14, color: Colors.white70)),
                      ])),
                      _SaveButton(painting: painting, state: route.state, onSave: () => route.onSave(context, painting), onDark: true),
                    ]),
                  ),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}
