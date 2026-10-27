import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/wallpaper_tone.dart';

// 自定义壁纸：静态图替代云雾（云雾仍是默认），按色调网格逐格淡化，直接压在背景上的文字和状态栏图标照旧可读。
// look 是模糊与淡化（0–100），拖动滑杆时连续变化；背景单独监听它重画，不重建应用。
class CampusWallpaper {
  const CampusWallpaper({required this.image, required this.tone, required this.look});
  final ImageProvider image;
  final WallpaperTone tone;
  final ValueListenable<({int blur, int fade})> look;
  // 模糊拉满时的 sigma。
  static const maxBlurSigma = 30.0;
}

// 云雾与壁纸互换、换图时交叉淡化的时长（新图已先解码好）；背景在所有玻璃之下，淡化不影响玻璃取背景。
const _backgroundSwap = Duration(milliseconds: 420);
// 模糊、淡化数值变化（读屏增减、松手吸附、预览退回）时平滑跟随的时长；拖动中逐帧跟手，几乎无延迟感。
const _lookFollow = Duration(milliseconds: 160);

// 唯一背景循环，不随路由/列表项复制。纹理固定，不逐帧生成随机噪点。设了壁纸时改画静态壁纸，不再循环；高对比度时两者都不画。
// overlays 是正在显示的弹窗、弹层层数，大于 0 时云雾停在原处：弹窗的全屏模糊压在流动的云雾上时，每一帧都要重算整屏模糊
// （模拟器上弹窗静止时每帧栅格约 80ms），停下后弹窗不动就不出帧；关掉后从原处接着流动，不跳。
class CampusAtmosphere extends StatefulWidget {
  const CampusAtmosphere({super.key, required this.child, this.phase, this.wallpaper, this.overlays});
  final Widget child;
  final double? phase;
  final CampusWallpaper? wallpaper;
  final ValueListenable<int>? overlays;
  @override
  State<CampusAtmosphere> createState() => _CampusAtmosphereState();
}

class _CampusAtmosphereState extends State<CampusAtmosphere>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );
  bool _allowed = false;
  // [人工决策-2026-10-27 00:26:51] iOS 上云雾每秒只更新约 20 次（用户选定「降帧流动」，取代 09-25 那条在 iOS 上的逐帧流动）：一圈 24 秒、走得很慢，
  // 按屏幕刷新率（ProMotion 每秒 120 次）整屏重画看不出区别，却让手机发烫；低电量模式下停（见 CampusMotion）。停下再开从原处接着走。
  // [人工决策-2026-10-27 17:42:49] 安卓也照此（用户「按照建议做」：安卓同样没有栅格缓存、手上的 OPPO 与 vivo 都是高刷屏）：每秒约 20 次、半分辨率贴图、省电模式下停。
  Timer? _tick;
  static const _step = Duration(milliseconds: 50);
  // 每一拍先画成半分辨率贴图，每帧只贴图（见 AtmosphereCache）。
  final _fogCache = AtmosphereCache();
  // 离开前台立即停：后台不出帧、不重建，等 CampusMotion 经重建传过来要到回前台，定时器会在后台一直空转。
  bool _foreground = WidgetsBinding.instance.lifecycleState == null || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  // 正在显示的壁纸。换上新图时先按铺满屏幕的尺寸解码好再换，交叉淡化直接从旧背景到新图，
  // 不会先淡到底色、等解码完图片再冒出来；恢复云雾和同一张图的外观变化立即生效。
  late CampusWallpaper? _shown = widget.wallpaper;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _allowed =
        CampusMotion.allowed(context) &&
        !MediaQuery.highContrastOf(context) &&
        !MediaQuery.accessibleNavigationOf(context);
    _updatePlayback();
  }

  void _syncWallpaper() {
    final next = widget.wallpaper;
    if (next == null || next.image == _shown?.image) {
      _shown = next;
      return;
    }
    precacheImage(_wallpaperImage(next, context), context, onError: (error, stack) {
      campusLog('[Wallpaper] action=precache errorType=${error.runtimeType}\n$stack');
    }).then((_) {
      if (!mounted || widget.wallpaper?.image != next.image) return;
      setState(() => _shown = widget.wallpaper);
      _updatePlayback();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updatePlayback();
  }

  void _updatePlayback() {
    if (_allowed && _foreground && widget.phase == null && _shown == null && (widget.overlays?.value ?? 0) == 0) {
      _tick ??= Timer.periodic(_step, (_) => _controller.value = (_controller.value + _step.inMicroseconds / _controller.duration!.inMicroseconds) % 1);
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.overlays?.addListener(_updatePlayback);
  }

  @override
  void didUpdateWidget(CampusAtmosphere oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.wallpaper != widget.wallpaper) _syncWallpaper();
    if (oldWidget.overlays != widget.overlays) {
      oldWidget.overlays?.removeListener(_updatePlayback);
      widget.overlays?.addListener(_updatePlayback);
    }
    _updatePlayback();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.overlays?.removeListener(_updatePlayback);
    _tick?.cancel();
    _fogCache.dispose();
    _controller.dispose();
    super.dispose();
  }

  Widget _layer(BuildContext context) {
    final highContrast = MediaQuery.highContrastOf(context);
    final wallpaper = highContrast ? null : _shown;
    return RepaintBoundary(
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : _backgroundSwap,
            switchInCurve: Curves.easeInOutCubic,
            switchOutCurve: Curves.easeInOutCubic,
            layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
            child: wallpaper != null
                ? _WallpaperLayer(key: ValueKey(wallpaper.image), wallpaper: wallpaper)
                : CustomPaint(
                    key: const ValueKey('fog'),
                    painter: AtmospherePainter(
                      palette: CampusPalette.of(context),
                      progress: _allowed && widget.phase == null
                          ? _controller
                          : AlwaysStoppedAnimation(widget.phase ?? .18),
                      highContrast: highContrast,
                      cache: _fogCache,
                      ratio: MediaQuery.devicePixelRatioOf(context),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Positioned.fill(child: _layer(context)),
      CampusBackdrop(layer: _layer, child: widget.child),
    ],
  );
}

// 向下提供与背景同相位的一份副本，只在两处临时用：入场遮罩叠在内容之上（内容淡入改为盖在上面的背景淡出，
// 玻璃不处在半透明图层里，从第一帧起就按真实背景绘制）；页面推在弹窗上时转场期间垫在页面下面（见 campus_transitions.dart）。
class CampusBackdrop extends InheritedWidget {
  const CampusBackdrop({super.key, required this.layer, required super.child});
  final WidgetBuilder layer;

  static WidgetBuilder? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CampusBackdrop>()?.layer;

  @override
  bool updateShouldNotify(CampusBackdrop oldWidget) => layer != oldWidget.layer;
}

// 按铺满屏幕所需的像素解码，不放大原图；预解码与绘制共用，缓存键一致。只订阅屏幕尺寸与像素密度。
ImageProvider _wallpaperImage(CampusWallpaper wallpaper, BuildContext context) {
  final tone = wallpaper.tone;
  final physical = MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
  final scale = math.min(1.0, math.max(physical.width / tone.width, physical.height / tone.height));
  return ResizeImage(wallpaper.image, width: math.max(1, (tone.width * scale).round()), height: math.max(1, (tone.height * scale).round()));
}

class _WallpaperLayer extends StatefulWidget {
  const _WallpaperLayer({super.key, required this.wallpaper});
  final CampusWallpaper wallpaper;
  @override
  State<_WallpaperLayer> createState() => _WallpaperLayerState();
}

class _WallpaperLayerState extends State<_WallpaperLayer> {
  // 可读下限只在网格或配色变化时重算；只订阅屏幕尺寸，键盘弹起等不触发重算。拖动淡化滑杆时只在绘制里做加法。
  (WallpaperTone, CampusPalette)? _key;
  Float64List _floor = Float64List(0);

  Float64List _veil(CampusPalette palette) {
    final key = (widget.wallpaper.tone, palette);
    if (key != _key) {
      _key = key;
      _floor = wallpaperVeilAlphas(widget.wallpaper.tone, palette);
    }
    return _floor;
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final wallpaper = widget.wallpaper, tone = wallpaper.tone;
    final follow = MediaQuery.disableAnimationsOf(context) ? Duration.zero : _lookFollow;
    final image = Image(
      image: _wallpaperImage(wallpaper, context),
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      errorBuilder: (context, error, stack) {
        campusLog('[Wallpaper] action=load errorType=${error.runtimeType}\n$stack');
        return const SizedBox.expand();
      },
    );
    return ValueListenableBuilder<({int blur, int fade})>(
      valueListenable: wallpaper.look,
      builder: (context, look, _) => Stack(fit: StackFit.expand, children: [
        ColoredBox(color: wallpaperVeilColor(palette)),
        TweenAnimationBuilder<double>(
          tween: Tween(end: look.blur / 100 * CampusWallpaper.maxBlurSigma),
          duration: follow,
          curve: Curves.easeOutCubic,
          child: image,
          builder: (context, sigma, image) => sigma < .1
              ? image!
              : ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp), child: image),
        ),
        TweenAnimationBuilder<double>(
          tween: Tween(end: look.fade / 100),
          duration: follow,
          curve: Curves.easeOutCubic,
          builder: (context, fade, _) => CustomPaint(painter: _VeilPainter(tone: tone, floor: _veil(palette), fade: fade, color: wallpaperVeilColor(palette))),
        ),
      ]),
    );
  }
}

// 淡化层与壁纸同一个 cover 映射。网格顶点着色：每个顶点取相邻格的最大下限，再叠上用户淡化量；
// 格内插值不低于该格所需，过渡平滑无方块。
class _VeilPainter extends CustomPainter {
  _VeilPainter({required this.tone, required this.floor, required this.fade, required this.color});
  final WallpaperTone tone;
  final Float64List floor;
  final double fade;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.max(size.width / tone.width, size.height / tone.height);
    final drawn = Size(tone.width * scale, tone.height * scale);
    final origin = Offset((size.width - drawn.width) / 2, (size.height - drawn.height) / 2);
    final columns = tone.columns, rows = tone.rows;
    final positions = <Offset>[];
    final colors = <Color>[];
    for (var row = 0; row <= rows; row++) {
      for (var column = 0; column <= columns; column++) {
        positions.add(origin + Offset(drawn.width * column / columns, drawn.height * row / rows));
        var alpha = 0.0;
        for (final (cellRow, cellColumn) in [(row - 1, column - 1), (row - 1, column), (row, column - 1), (row, column)]) {
          if (cellRow >= 0 && cellRow < rows && cellColumn >= 0 && cellColumn < columns) {
            alpha = math.max(alpha, floor[cellRow * columns + cellColumn]);
          }
        }
        colors.add(color.withValues(alpha: wallpaperVeilAlpha(alpha, fade)));
      }
    }
    final indices = <int>[];
    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        final topLeft = row * (columns + 1) + column, bottomLeft = topLeft + columns + 1;
        indices.addAll([topLeft, topLeft + 1, bottomLeft, topLeft + 1, bottomLeft + 1, bottomLeft]);
      }
    }
    final vertices = ui.Vertices(VertexMode.triangles, positions, colors: colors, indices: indices);
    canvas.drawVertices(vertices, BlendMode.dst, Paint());
    vertices.dispose();
  }

  @override
  bool shouldRepaint(_VeilPainter oldDelegate) => oldDelegate.tone != tone || oldDelegate.floor != floor || oldDelegate.fade != fade || oldDelegate.color != color;
}

class AtmospherePainter extends CustomPainter {
  AtmospherePainter({
    required this.progress,
    required this.highContrast,
    required this.palette,
    this.cache,
    this.ratio = 1,
  }) : super(repaint: progress);
  final Animation<double> progress;
  final bool highContrast;
  final CampusPalette palette;
  // 给了就先画进半分辨率贴图再整屏贴上（见 AtmosphereCache）；ratio 是设备像素密度。
  final AtmosphereCache? cache;
  final double ratio;
  final _paint = Paint();
  static const _unitBounds = Rect.fromLTRB(-1, -1, 1, 1);
  static const _clouds = [
    (x: .06, y: .24, phase: 0.0, angle: -.5, color: 0),
    (x: .93, y: .43, phase: 2.1, angle: .6, color: 1),
    (x: .22, y: .79, phase: 4.2, angle: -.4, color: 2),
    (x: .91, y: .95, phase: 1.3, angle: .5, color: 0),
  ];
  late final _colors = [
    palette.fogSage,
    palette.fogChampagne,
    palette.fogPearl,
  ];
  late final _wideShaders = [
    for (final color in _colors)
      _fogGradient(color, .92).createShader(_unitBounds),
  ];
  late final _foldShaders = [
    for (final color in _colors)
      _fogGradient(color, .40).createShader(_unitBounds),
  ];
  late final _pearlShader = _fogGradient(
    palette.surface,
    .44,
  ).createShader(_unitBounds);
  late final _baseShader = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [palette.backgroundTop, palette.backgroundBottom],
  ).createShader(const Rect.fromLTWH(0, 0, 1, 1));

  RadialGradient _fogGradient(Color color, double alpha) {
    final pearl = Color.lerp(color, palette.surface, .34)!;
    return RadialGradient(
      colors: [
        pearl.withValues(alpha: alpha),
        pearl.withValues(alpha: alpha * .82),
        pearl.withValues(alpha: alpha * .34),
        pearl.withValues(alpha: 0),
      ],
      stops: const [0, .34, .70, 1],
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cache = this.cache;
    if (cache == null) return _paintFog(canvas, size);
    cache.paint(canvas, size, ratio, (progress.value, size, palette, highContrast, ratio), _paintFog);
  }

  void _paintFog(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.save();
    canvas.scale(size.width, size.height);
    _paint.shader = _baseShader;
    canvas.drawRect(const Rect.fromLTWH(0, 0, 1, 1), _paint);
    canvas.restore();
    if (highContrast) return;
    // [人工决策-2026-09-25 20:18:09] 以大面积冷暖珠光替代低对比九瓣；保留五主题、24秒和卡片遮色，留白及边缘须可见轮廓交融。
    final phase = progress.value * math.pi * 2;
    final extent = size.shortestSide;
    canvas.save();
    canvas.clipRect(bounds);
    for (final cloud in _clouds) {
      final drift = phase + cloud.phase;
      final center = Offset(
        size.width * (cloud.x + .27 * math.sin(drift)),
        size.height * (cloud.y + .13 * math.cos(drift)),
      );
      final angle = cloud.angle + .42 * math.sin(drift);
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(angle);
      canvas.save();
      canvas.scale(
        extent * (1.04 + .18 * math.sin(drift)),
        math.max(extent * .64, size.height * .36) * (1 + .20 * math.cos(drift)),
      );
      _paint.shader = _wideShaders[cloud.color];
      canvas.drawOval(_unitBounds, _paint);
      canvas.restore();
      // 相对主体独立舒展的光褶，而不是整张彩斑平移。
      canvas.translate(
        extent * .24 * math.cos(drift + .8),
        extent * .20 * math.sin(drift + .8),
      );
      canvas.rotate(.7 * math.sin(drift + 1.2));
      canvas.scale(
        extent * (.56 + .12 * math.cos(drift)),
        extent * (.34 + .08 * math.sin(drift)),
      );
      _paint.shader = _foldShaders[(cloud.color + 1) % _colors.length];
      canvas.drawOval(_unitBounds, _paint);
      canvas.restore();
    }
    // 珠白光脊保持纸面明度，分开冷暖雾团，避免叠色变成均匀脏灰。
    canvas.save();
    canvas.translate(
      size.width * (.49 + .16 * math.sin(phase + .7)),
      size.height * (.52 + .12 * math.cos(phase + .7)),
    );
    canvas.rotate(.35 * math.sin(phase));
    canvas.scale(extent * .53, size.height * .69);
    _paint.shader = _pearlShader;
    canvas.drawOval(_unitBounds, _paint);
    canvas.restore();
    canvas.restore();
    _paint.shader = null;
  }

  @override
  bool shouldRepaint(AtmospherePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.highContrast != highContrast ||
      oldDelegate.palette != palette ||
      oldDelegate.cache != cache ||
      oldDelegate.ratio != ratio;
}

// 云雾的半分辨率贴图（[人工决策] 见 _CampusAtmosphereState 的 _tick）：每一拍按一半设备像素画一次，之后每帧只贴这一张图。
// Impeller 没有栅格缓存，直接画的话滑动时每帧都要重叠十层整屏大渐变；云雾是大片柔和渐变，半分辨率放大看不出差别（atmosphere_test.dart 对照）。
class AtmosphereCache {
  ui.Image? _image;
  Object? _key;

  void paint(Canvas canvas, Size size, double ratio, Object key, void Function(Canvas canvas, Size size) draw) {
    final scale = ratio / 2;
    if (_image == null || key != _key) {
      final recorder = ui.PictureRecorder();
      draw(Canvas(recorder)..scale(scale), size);
      final picture = recorder.endRecording();
      _image?.dispose();
      _image = picture.toImageSync(math.max(1, (size.width * scale).ceil()), math.max(1, (size.height * scale).ceil()));
      picture.dispose();
      _key = key;
    }
    final image = _image!;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, image.width / scale, image.height / scale),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  void dispose() {
    _image?.dispose();
    _image = null;
  }
}

class FrostTexture extends StatelessWidget {
  const FrostTexture({super.key, this.radius = 24});
  final double radius;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        painter: _GrainPainter(CampusPalette.of(context).onSurfaceVariant, radius),
      ),
    ),
  );
}

// 颗粒：每 12 一格一个小圆点，每行横向错开 y % 7；全部点拼成一组，一次 drawRawPoints 画完。
// Impeller 没有栅格缓存，逐个 drawCircle 的几百上千个小圆每帧都要重新细分、提交（10-27 iPhone 日志：只有背景在动的帧也要栅格约 9ms，滑动时更慢）。
// 不用离屏贴图：#153 改成 toImageSync 画的 12×84 拼贴加图像着色器后，vivo V2408A（骁龙、2K 屏）上拼贴里有几行是绿黑相间的脏像素，
// 每张卡片按拼贴周期（横 12、竖 84）整排冒出虚线（10-27 用户截图）。推测是拼贴几乎全透明、没画到的像素拿到了脏内存（云雾贴图先铺满底色，没出问题）。
class _GrainPainter extends CustomPainter {
  const _GrainPainter(this.color, this.radius);
  final Color color;
  final double radius;
  @override
  void paint(Canvas canvas, Size size) {
    // 圆角外的点不画，跨在边上的照画（露出圆角的不到半个点，卡片的 Material 还会裁掉）；点数随表面面积增长，不随业务数据增长。
    final shape = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)).inflate(.55);
    final points = <double>[];
    for (var y = 3.0; y < size.height; y += 12) {
      for (var x = 3.0; x < size.width; x += 12) {
        final center = Offset(x + (y.toInt() % 7), y);
        if (shape.contains(center)) points.addAll([center.dx, center.dy]);
      }
    }
    canvas.drawRawPoints(
      ui.PointMode.points,
      Float32List.fromList(points),
      Paint()
        ..color = color.withValues(alpha: .016)
        ..strokeWidth = 1.1
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_GrainPainter oldDelegate) => oldDelegate.color != color || oldDelegate.radius != radius;
}
