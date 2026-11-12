import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/ice/ice_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';

// 冰面滑行对局页：在棋盘上朝上下左右滑动（或点棋盘下方的方向按钮）推动小企鹅，它一直滑到撞上岩石或边界才停；
// 正好停在终点（插旗的光圈）上就解开。滑行时长按距离算、前快后慢，撞停时轻轻一压再弹回；滑不动时轻震、朝那边抖一下，不算步数。
class IcePage extends StatefulWidget {
  const IcePage({super.key, required this.game, required this.store, this.seeds});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;

  @override
  State<IcePage> createState() => _IcePageState();
}

class _IcePageState extends State<IcePage> with TickerProviderStateMixin {
  late final _session = PlaySession<IcePuzzle, List<int>>(game: widget.game, rules: const IceRules(), store: widget.store, seeds: widget.seeds);
  // 走过的每一步：方向与滑之前在哪一格，撤销按步退回。
  final _moves = <({int direction, int from})>[];
  late int _cell = _session.puzzle.start;
  // 正在画的这一段：从哪格滑到哪格、朝哪个方向；撤销是倒放（匀称地滑回去，不撞停）。
  late int _from = _cell, _to = _cell;
  int _direction = iceDown, _facing = iceDown, _nudgeDirection = iceDown;
  bool _rewind = false;
  // 滑行占这段动画的比例，余下的是撞停那一下。
  double _split = 1;
  late final _slide = AnimationController(vsync: this, value: 1);
  late final _nudge = AnimationController(vsync: this, duration: const Duration(milliseconds: 280));
  late final _cheer = AnimationController(vsync: this, duration: const Duration(milliseconds: 760));
  late final _motion = Listenable.merge([_slide, _nudge, _cheer]);
  final _art = _IceArt();

  // 每格约 40ms、最长 300ms；撞停那一下 160ms。
  static const _impact = 160;
  // 起步快、到头仍带一点速度（撞上岩石才停，不是自己缓停到零）。
  static const _glide = Cubic(.3, .6, .65, .88);

  @override
  void dispose() {
    _slide.dispose();
    _nudge.dispose();
    _cheer.dispose();
    _session.dispose();
    super.dispose();
  }

  int get _least => _session.draw.solution.length;

  void _reset() {
    _moves.clear();
    _cell = _from = _to = _session.puzzle.start;
    _direction = _facing = iceDown;
    _rewind = false;
    _split = 1;
    _slide.value = 1;
    _nudge.value = 0;
    _cheer.value = 0;
  }

  void _newGame(PuzzleTier? tier) => setState(() {
    _session.next(tier: tier);
    _reset();
  });

  void _restart() => setState(() {
    _session.restart();
    _reset();
  });

  // 推一下：滑得动就记一步并播滑行，停在终点即解开；滑不动轻震、朝那个方向抖一下，不算步数。
  void _push(int direction) {
    if (_session.finished) return;
    final puzzle = _session.puzzle;
    final stop = iceSlide(puzzle, _cell, direction);
    if (stop == _cell) {
      playRejected();
      _slide.value = 1;
      _nudgeDirection = direction;
      setState(() => _facing = direction);
      if (!MediaQuery.disableAnimationsOf(context)) unawaited(_nudge.forward(from: 0));
      return;
    }
    playTick();
    _session.moved();
    final slide = _animate(from: _cell, to: stop, direction: direction, rewind: false);
    setState(() {
      _moves.add((direction: direction, from: _cell));
      _cell = stop;
      _facing = direction;
    });
    if (stop == puzzle.goal) unawaited(_finish(slide));
  }

  // 播一段滑行（撤销时倒放），返回播完的那一刻；减少动画时直接到位。
  // 上一段没播完又推了一下：上一段直接到位，从它的终点接着滑（快手连推时不排队等动画）。
  TickerFuture _animate({required int from, required int to, required int direction, required bool rewind}) {
    final width = _session.puzzle.width;
    final distance = (from % width - to % width).abs() + (from ~/ width - to ~/ width).abs();
    _from = from;
    _to = to;
    _direction = direction;
    _rewind = rewind;
    _nudge.value = 0;
    if (MediaQuery.disableAnimationsOf(context)) {
      _split = 1;
      _slide.value = 1;
      return TickerFuture.complete();
    }
    final glide = rewind ? (30 * distance + 90).clamp(120, 240) : (40 * distance).clamp(80, 300);
    final total = rewind ? glide : glide + _impact;
    _split = glide / total;
    _slide.duration = Duration(milliseconds: total);
    return _slide.forward(from: 0);
  }

  void _undo() {
    if (_moves.isEmpty || _session.finished) return;
    playTick();
    final move = _moves.removeLast();
    _animate(from: _cell, to: move.from, direction: (move.direction + 2) % iceDirections, rewind: true);
    setState(() => _cell = move.from);
  }

  // 解开：停表记成绩，等滑到终点、在终点上轻轻一跳（光圈同时漾开）再弹结果；减少动画时直接弹。
  // 中途换题或从头来会停掉动画，等着的这一段就不再往下走。
  Future<void> _finish(TickerFuture slide) async {
    final newBest = await _session.finish(moves: _moves.length);
    await slide;
    if (!mounted) return;
    if (!MediaQuery.disableAnimationsOf(context)) await _cheer.forward(from: 0);
    if (!mounted) return;
    final least = _least;
    final choice = await showPlayResult(context, session: _session, newBest: newBest, detail: _moves.length == least ? '$least 步，正好最少' : '${_moves.length} 步，最少 $least 步');
    if (!mounted) return;
    switch (choice) {
      case PlayResultChoice.again:
        _newGame(null);
      case PlayResultChoice.harder:
        _newGame(PuzzleTier.values[_session.tier.index + 1]);
      case PlayResultChoice.close:
        break;
    }
  }

  // 棋子此刻的样子：位置（格坐标，格中心是 .5）、压扁多少与沿哪个方向、跳多高、划痕与终点光圈。
  _Pose _pose() {
    final width = _session.puzzle.width;
    Offset center(int cell) => Offset(cell % width + .5, cell ~/ width + .5);
    final from = center(_from), to = center(_to);
    final t = _slide.value;
    final gliding = t < _split;
    final travel = _rewind ? Curves.easeInOutCubic.transform(t) : gliding ? _glide.transform(t / _split) : 1.0;
    // 撞停：很快压扁、再慢一点弹回（sin(π√u) 在四分之一处到顶），整个人往岩石那边蹭一点。
    final impactProgress = _rewind || gliding || t >= 1 ? 0.0 : (t - _split) / (1 - _split);
    final impact = impactProgress == 0 ? 0.0 : math.sin(math.pi * math.sqrt(impactProgress));
    var at = Offset.lerp(from, to, travel)! + _unit(_direction) * (.07 * impact);
    var squash = .13 * impact;
    var squashDirection = _direction;
    // 滑不动：朝那个方向顶一下、回弹一点再停，同时轻轻压扁。
    final nudge = _nudge.value;
    final push = math.sin(nudge * math.pi * 2.5) * (1 - nudge);
    if (push != 0) {
      at += _unit(_nudgeDirection) * (.12 * push);
      squash = math.max(0, push) * .1;
      squashDirection = _nudgeDirection;
    }
    // 解开：前半段跳起落下，落地压一下；光圈从终点漾开。
    final cheer = _cheer.value;
    var hop = 0.0;
    if (cheer > 0 && cheer < .46) hop = math.sin(math.pi * cheer / .46) * .34;
    if (cheer >= .46 && cheer < .7) {
      squash = .12 * math.sin(math.pi * (cheer - .46) / .24);
      squashDirection = iceDown;
    }
    final trail = _rewind || t >= 1 ? 0.0 : gliding ? 1.0 : 1 - impactProgress;
    return _Pose(at: at, facing: _facing, squash: squash, squashDirection: squashDirection, hop: hop, trailFrom: from, trail: trail, ring: cheer > 0 && cheer < 1 ? cheer : 0);
  }

  @override
  Widget build(BuildContext context) {
    final finished = _session.finished;
    return PlayFrame(
      session: _session,
      onNewGame: _newGame,
      onRestart: _restart,
      status: '${_moves.length} 步 · 最少 $_least 步',
      controls: [
        FilledButton.icon(onPressed: _moves.isEmpty || finished ? null : _undo, icon: const CampusIcon(CampusIcons.undo), label: const Text('撤销')),
      ],
      board: Column(children: [
        Expanded(child: PlayBoardBox(aspectRatio: _session.puzzle.width / _session.puzzle.height, builder: _board)),
        const SizedBox(height: 16),
        _Pad(onPush: finished ? null : _push),
      ]),
    );
  }

  Widget _board(BuildContext context, Size size) {
    final palette = CampusPalette.of(context);
    final puzzle = _session.puzzle;
    final scene = _art.prepare(puzzle, size, palette);
    String place(int cell) => '第${cell ~/ puzzle.width + 1}行第${cell % puzzle.width + 1}列';
    return Semantics(
      container: true,
      label: '冰面 ${puzzle.width}×${puzzle.height}，棋子在${place(_cell)}，终点在${place(puzzle.goal)}${_cell == puzzle.goal ? '，已到达' : ''}',
      hint: '上下左右滑动推动棋子，也可以用下方的方向按钮',
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        gestures: {
          _SwipeRecognizer: GestureRecognizerFactoryWithHandlers<_SwipeRecognizer>(_SwipeRecognizer.new, (recognizer) => recognizer.onSwipe = _push),
        },
        child: Stack(fit: StackFit.expand, children: [
          RepaintBoundary(child: CustomPaint(painter: _IcePainter(scene))),
          RepaintBoundary(child: CustomPaint(painter: _PiecePainter(scene: scene, pose: _pose, repaint: _motion))),
        ]),
      ),
    );
  }
}

Offset _unit(int direction) => switch (direction) {
  iceUp => const Offset(0, -1),
  iceRight => const Offset(1, 0),
  iceDown => const Offset(0, 1),
  _ => const Offset(-1, 0),
};

// 棋盘上的滑动：手指一落下就赢下手势竞争（iOS 的页面任意位置右滑返回也在抢横向移动，见 campus_transitions.dart 的 _IosBackSwipe），
// 走过触摸门槛后按横竖哪边走得多认一个方向，这一笔里只认一次；只跟第一根手指。
class _SwipeRecognizer extends OneSequenceGestureRecognizer {
  void Function(int direction)? onSwipe;
  int? _pointer;
  Offset _origin = Offset.zero;
  bool _fired = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_pointer != null) return;
    super.addAllowedPointer(event);
    _pointer = event.pointer;
    _origin = event.position;
    _fired = false;
    resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent && !_fired) {
      final delta = event.position - _origin;
      if (delta.distance < kTouchSlop) return;
      _fired = true;
      final direction = delta.dx.abs() > delta.dy.abs() ? (delta.dx > 0 ? iceRight : iceLeft) : (delta.dy > 0 ? iceDown : iceUp);
      invokeCallback<void>('onSwipe', () => onSwipe?.call(direction));
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) => _pointer = null;

  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) => stopTrackingPointer(pointer);

  @override
  String get debugDescription => 'ice swipe';
}

// 棋盘下方的方向键：上下在中间一列、左右在两边，排成紧凑的十字；内容区的色调圆钮，每个都有读屏标签与长按提示。
class _Pad extends StatelessWidget {
  const _Pad({required this.onPush});
  final void Function(int direction)? onPush;

  static const _size = 52.0, _gap = 6.0;

  @override
  Widget build(BuildContext context) {
    Widget key(int direction, String label, IconData icon, double left, double top) => Positioned(
      left: left,
      top: top,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: FilledButton(
          onPressed: onPush == null ? null : () => onPush!(direction),
          style: FilledButton.styleFrom(shape: const CircleBorder(), fixedSize: const Size.square(_size), minimumSize: const Size.square(_size), padding: EdgeInsets.zero),
          child: Semantics(label: label, excludeSemantics: true, child: CampusIcon(icon, size: 26)),
        ),
      ),
    );
    const middle = (_size + _gap) / 2;
    return SizedBox(width: _size * 3 + _gap * 2, height: _size * 2 + _gap, child: Stack(children: [
      key(iceUp, '向上滑', CampusIcons.collapse, _size + _gap, 0),
      key(iceLeft, '向左滑', CampusIcons.previous, 0, middle),
      key(iceRight, '向右滑', CampusIcons.next, (_size + _gap) * 2, middle),
      key(iceDown, '向下滑', CampusIcons.expand, _size + _gap, _size + _gap),
    ]));
  }
}

class _Pose {
  const _Pose({required this.at, required this.facing, required this.squash, required this.squashDirection, required this.hop, required this.trailFrom, required this.trail, required this.ring});
  final Offset at;
  final int facing;
  final double squash;
  final int squashDirection;
  final double hop;
  final Offset trailFrom;
  final double trail;
  final double ring;
}

// 冰面的配色：全从当前配色推出。冰取三种雾色里最冷的那一个（色相离冰蓝 200° 最近），向卡片底色淡化；
// 岩石从轮廓色推出（上亮下暗）、顶上一层雪，终点用控件激活色；小企鹅浅色时身子取文字主色压深，深色时是偏亮的灰（像企鹅幼崽，
// 压在深色冰面上也看得清），肚皮近白，嘴和脚用提醒色（琥珀）。
class _IceColors {
  factory _IceColors(CampusPalette palette) {
    double coldness(Color color) {
      final away = (HSLColor.fromColor(color).hue - 200).abs();
      return away > 180 ? 360 - away : away;
    }

    final fog = [palette.fogSage, palette.fogChampagne, palette.fogPearl].reduce((best, color) => coldness(color) < coldness(best) ? color : best);
    final dark = palette.isDark, surface = palette.surface;
    return _IceColors._(
      dark: dark,
      iceLight: dark ? Color.lerp(surface, fog, .62)! : Color.lerp(surface, fog, .26)!,
      iceDeep: dark ? Color.lerp(palette.backgroundBottom, fog, .48)! : Color.lerp(surface, fog, .66)!,
      rim: dark ? Color.lerp(surface, palette.onSurfaceVariant, .2)! : Color.lerp(surface, Colors.white, .65)!,
      rimEdge: dark ? palette.outlineSubtle : Color.lerp(palette.outlineSubtle, fog, .5)!,
      shine: Colors.white.withValues(alpha: dark ? .2 : .75),
      seam: Colors.white.withValues(alpha: dark ? .07 : .38),
      rock: dark ? Color.lerp(palette.outlineSubtle, palette.outline, .62)! : Color.lerp(palette.outline, palette.onSurface, .18)!,
      rockShade: dark ? Color.lerp(palette.outlineSubtle, palette.backgroundTop, .15)! : Color.lerp(palette.outline, palette.onSurface, .55)!,
      snow: dark ? Color.lerp(palette.onSurfaceVariant, palette.onSurface, .55)! : Color.lerp(surface, Colors.white, .75)!,
      shadow: Colors.black.withValues(alpha: dark ? .38 : .2),
      goal: dark ? palette.accentText : palette.accent,
      pole: palette.onSurfaceVariant,
      penguin: dark ? Color.lerp(palette.backgroundTop, palette.onSurfaceVariant, .3)! : Color.lerp(palette.primary, palette.onSurface, .4)!,
      belly: dark ? Color.lerp(palette.onSurface, Colors.white, .35)! : Color.lerp(surface, Colors.white, .85)!,
      eye: dark ? palette.backgroundTop : palette.onSurface,
      beak: palette.attention,
      blush: Color.lerp(palette.attention, palette.dangerFill, .55)!.withValues(alpha: .42),
    );
  }

  const _IceColors._({
    required this.dark,
    required this.iceLight,
    required this.iceDeep,
    required this.rim,
    required this.rimEdge,
    required this.shine,
    required this.seam,
    required this.rock,
    required this.rockShade,
    required this.snow,
    required this.shadow,
    required this.goal,
    required this.pole,
    required this.penguin,
    required this.belly,
    required this.eye,
    required this.beak,
    required this.blush,
  });
  final bool dark;
  final Color iceLight, iceDeep, rim, rimEdge, shine, seam, rock, rockShade, snow, shadow, goal, pole, penguin, belly, eye, beak, blush;
}

// 棋盘几何与静态图形：雪檐、冰面、接缝、高光、霜点与岩石都在这里拼成几条路径，题、尺寸或配色变了才重建；
// 绘制时每种图形一次画完，不逐格画小图形。
class _IceScene {
  _IceScene(this.puzzle, Size size, CampusPalette palette) : colors = _IceColors(palette) {
    final width = puzzle.width, height = puzzle.height;
    rim = math.max(6.0, size.shortestSide * .03);
    cell = math.min((size.width - rim * 2) / width, (size.height - rim * 2) / height);
    origin = Offset((size.width - cell * width) / 2, (size.height - cell * height) / 2);
    final iceRect = origin & Size(cell * width, cell * height);
    frame = RRect.fromRectAndRadius(iceRect.inflate(rim), Radius.circular(rim + 10));
    ice = RRect.fromRectAndRadius(iceRect, const Radius.circular(10));
    final points = <double>[];
    for (var row = 0; row < height; row++) {
      for (var column = 0; column < width; column++) {
        final index = row * width + column;
        final rect = Rect.fromLTWH(origin.dx + column * cell, origin.dy + row * cell, cell, cell);
        final noise = _hash(index * 7919 + puzzle.start * 31 + puzzle.goal);
        if (puzzle.rocks[index]) {
          _rock(rect, noise);
          continue;
        }
        // 高光：约三分之一的冰格有一道斜的短亮痕（长短、位置按格号散开），一半再配一道更短的。
        if (noise % 3 == 0) {
          final length = cell * (.18 + (noise >> 4) % 4 * .045);
          final start = rect.topLeft + Offset(cell * (.12 + (noise >> 7) % 5 * .09), cell * (.4 + (noise >> 10) % 4 * .08));
          glints
            ..moveTo(start.dx, start.dy)
            ..lineTo(start.dx + length, start.dy - length);
          if ((noise >> 13) % 2 == 0) {
            final second = start + Offset(cell * .12, cell * .05);
            glints
              ..moveTo(second.dx, second.dy)
              ..lineTo(second.dx + length * .45, second.dy - length * .45);
          }
        }
        // 霜点：每格两三粒，位置按格号散开。
        for (var speck = 0; speck < 2 + noise % 2; speck++) {
          final seed = _hash(noise + speck * 131);
          points
            ..add(rect.left + (seed % 97) / 97 * cell)
            ..add(rect.top + ((seed >> 8) % 89) / 89 * cell);
        }
      }
    }
    frost = Float32List.fromList(points);
    for (var column = 1; column < width; column++) {
      final x = origin.dx + column * cell;
      seams
        ..moveTo(x, iceRect.top)
        ..lineTo(x, iceRect.bottom);
    }
    for (var row = 1; row < height; row++) {
      final y = origin.dy + row * cell;
      seams
        ..moveTo(iceRect.left, y)
        ..lineTo(iceRect.right, y);
    }
  }

  final IcePuzzle puzzle;
  final _IceColors colors;
  late final double rim, cell;
  late final Offset origin;
  late final RRect frame, ice;
  late final Float32List frost;
  final seams = Path(), glints = Path(), rocks = Path(), rockShadow = Path(), caps = Path();

  Offset centerOf(int cell) => origin + Offset((cell % puzzle.width + .5) * this.cell, (cell ~/ puzzle.width + .5) * this.cell);

  // 终点光圈的中心：在格子中线略靠下，正好垫在企鹅脚下。
  Offset get goalBase => centerOf(puzzle.goal) + Offset(0, cell * .22);

  // 一块岩石：圆润的卵石，轮廓是绕中心的 7 个点（角度与远近按格号略有出入）连成的平滑闭合曲线，底边压平、坐在冰上；
  // 顶上一层雪（波浪下沿，与石块求交，不会漏到别的石块上），底下一团扁的接地影。
  void _rock(Rect rect, int noise) {
    double vary(int salt, double range) => (_hash(noise + salt * 977) % 11 - 5) / 5 * range;
    final width = cell * (.84 + vary(1, .04)), height = cell * (.86 + vary(2, .04));
    final center = rect.center + Offset(vary(3, .025) * cell, cell * .02);
    const count = 7;
    final points = [
      for (var index = 0; index < count; index++)
        () {
          final angle = (index + vary(10 + index, .16)) / count * 2 * math.pi - math.pi / 2;
          final reach = 1 + vary(20 + index, .06);
          return center + Offset(math.cos(angle) * reach * width / 2, math.min(math.sin(angle) * reach, .7) * height / 2);
        }(),
    ];
    // Catmull-Rom 换成三次贝塞尔：曲线穿过每个点、处处圆滑。
    final stone = Path()..moveTo(points[0].dx, points[0].dy);
    for (var index = 0; index < count; index++) {
      final before = points[(index + count - 1) % count], from = points[index], to = points[(index + 1) % count], after = points[(index + 2) % count];
      final first = from + (to - before) / 6, second = to - (after - from) / 6;
      stone.cubicTo(first.dx, first.dy, second.dx, second.dy, to.dx, to.dy);
    }
    stone.close();
    rocks.addPath(stone, Offset.zero);
    final body = stone.getBounds();
    final line = body.top + body.height * (.38 + vary(4, .04)), wave = body.height * .07;
    final cap = Path()
      ..moveTo(body.left - 1, body.top - 1)
      ..lineTo(body.right + 1, body.top - 1)
      ..lineTo(body.right + 1, line - wave * .6)
      ..cubicTo(body.right - body.width * .22, line + wave * 1.3, body.left + body.width * .64, line - wave * 1.2, body.left + body.width * .44, line + wave * .4)
      ..cubicTo(body.left + body.width * .28, line + wave * 1.6, body.left + body.width * .12, line - wave * .3, body.left - 1, line + wave * .5)
      ..close();
    caps.addPath(Path.combine(PathOperation.intersect, cap, stone), Offset.zero);
    rockShadow.addOval(Rect.fromCenter(center: Offset(body.center.dx + cell * .03, body.bottom - cell * .02), width: body.width * .96, height: cell * .2));
  }

  static int _hash(int value) {
    var hash = (value * 0x9E3779B1) & 0xFFFFFFFF;
    hash = ((hash ^ (hash >> 15)) * 0x85EBCA6B) & 0xFFFFFFFF;
    return (hash ^ (hash >> 13)) & 0x7FFFFFFF;
  }
}

// 冰面场景的缓存：题、尺寸、配色都没变时给同一份，静态层不重画。
class _IceArt {
  Object? _key;
  _IceScene? _scene;

  _IceScene prepare(IcePuzzle puzzle, Size size, CampusPalette palette) {
    final key = (puzzle, size, palette);
    if (key != _key || _scene == null) {
      _key = key;
      _scene = _IceScene(puzzle, size, palette);
    }
    return _scene!;
  }
}

// 静态层：雪檐、冰面（斜向渐变加两道斜光带）、接缝、高光、霜点、终点与岩石。
class _IcePainter extends CustomPainter {
  _IcePainter(this.scene);
  final _IceScene scene;

  @override
  void paint(Canvas canvas, Size size) {
    final colors = scene.colors, cell = scene.cell, ice = scene.ice.outerRect;
    canvas.drawRRect(scene.frame, Paint()..color = colors.rim);
    canvas.drawRRect(scene.frame.deflate(.5), Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = colors.rimEdge);
    canvas.drawRRect(scene.ice, Paint()..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [colors.iceLight, colors.iceDeep]).createShader(ice));
    canvas.save();
    canvas.clipRRect(scene.ice);
    // 两道斜光带（同冰面反光），一宽一窄。
    final band = colors.shine.withValues(alpha: colors.shine.a * .45);
    canvas.drawRect(ice, Paint()..shader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [band.withValues(alpha: 0), band, band.withValues(alpha: 0), band.withValues(alpha: 0), band.withValues(alpha: band.a * .7), band.withValues(alpha: 0)],
      stops: const [.18, .3, .42, .5, .55, .6],
    ).createShader(ice));
    canvas.drawPath(scene.seams, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = colors.seam);
    canvas.drawPath(scene.glints, Paint()..style = PaintingStyle.stroke..strokeWidth = math.max(1.2, cell * .045)..strokeCap = StrokeCap.round..color = colors.shine);
    canvas.drawRawPoints(ui.PointMode.points, scene.frost, Paint()..strokeWidth = math.max(1.4, cell * .045)..strokeCap = StrokeCap.round..color = colors.shine.withValues(alpha: colors.shine.a * .7));
    _goal(canvas);
    canvas.drawPath(scene.rockShadow, Paint()..color = colors.shadow..maskFilter = MaskFilter.blur(BlurStyle.normal, cell * .05));
    // 石块上亮下暗：竖向渐变按格高重复铺开，每块石头都落在自己那一格的同一段渐变里，一条路径一次画完。
    final top = scene.origin.dy;
    canvas.drawPath(scene.rocks, Paint()..shader = ui.Gradient.linear(Offset(0, top), Offset(0, top + cell), [colors.rock, colors.rockShade], const [.3, .92], TileMode.repeated));
    canvas.drawPath(scene.caps, Paint()..color = colors.snow);
    canvas.restore();
    // 冰面嵌在雪檐里：内沿一圈细暗边。
    canvas.drawRRect(scene.ice, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.2..color = colors.iceDeep.withValues(alpha: .6));
  }

  // 终点：冰面上一圈扁的激活色光圈（同石块与企鹅的影子一样是斜看的地面），中间插一面小旗；企鹅停上去时旗面从头顶后面露出来。
  void _goal(Canvas canvas) {
    final colors = scene.colors, cell = scene.cell, base = scene.goalBase;
    final glow = Rect.fromCenter(center: base, width: cell * .96, height: cell * .5);
    canvas.drawOval(glow, Paint()..shader = RadialGradient(colors: [colors.goal.withValues(alpha: .4), colors.goal.withValues(alpha: 0)]).createShader(glow));
    canvas.drawOval(Rect.fromCenter(center: base, width: cell * .66, height: cell * .3), Paint()..style = PaintingStyle.stroke..strokeWidth = math.max(1.6, cell * .06)..color = colors.goal);
    final top = base - Offset(0, cell * .66);
    canvas.drawLine(base, top, Paint()..strokeWidth = math.max(1.6, cell * .055)..strokeCap = StrokeCap.round..color = colors.pole);
    final flag = Path()
      ..moveTo(top.dx, top.dy)
      ..cubicTo(top.dx + cell * .1, top.dy - cell * .04, top.dx + cell * .2, top.dy + cell * .05, top.dx + cell * .32, top.dy + cell * .02)
      ..lineTo(top.dx + cell * .32, top.dy + cell * .2)
      ..cubicTo(top.dx + cell * .2, top.dy + cell * .23, top.dx + cell * .1, top.dy + cell * .14, top.dx, top.dy + cell * .18)
      ..close();
    canvas.drawPath(flag, Paint()..color = colors.goal);
  }

  @override
  bool shouldRepaint(_IcePainter oldDelegate) => !identical(oldDelegate.scene, scene);
}

// 动的那一层：滑行划痕、终点漾开的光圈与小企鹅。按动画逐帧重画，只有这一个小东西。
class _PiecePainter extends CustomPainter {
  _PiecePainter({required this.scene, required this.pose, required Listenable repaint}) : super(repaint: repaint);
  final _IceScene scene;
  final _Pose Function() pose;

  @override
  void paint(Canvas canvas, Size size) {
    final colors = scene.colors, cell = scene.cell, pose = this.pose();
    final at = scene.origin + pose.at * cell;
    if (pose.trail > 0) {
      final from = scene.origin + pose.trailFrom * cell;
      if ((at - from).distance > 1) {
        canvas.drawLine(from, at, Paint()
          ..strokeWidth = cell * .34
          ..strokeCap = StrokeCap.round
          ..shader = ui.Gradient.linear(from, at, [colors.shine.withValues(alpha: 0), colors.shine.withValues(alpha: colors.shine.a * .55 * pose.trail)]));
      }
    }
    if (pose.ring > 0) {
      final spread = 1 + 1.6 * Curves.easeOutCubic.transform(pose.ring);
      canvas.drawOval(Rect.fromCenter(center: scene.goalBase, width: cell * .66 * spread, height: cell * .3 * spread), Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.6, cell * .07) * (1 - pose.ring * .6)
        ..color = colors.goal.withValues(alpha: .8 * (1 - pose.ring)));
    }
    _penguin(canvas, at, pose);
  }

  // 圆滚滚的小企鹅（正面）：影子留在冰面上，跳起时变小变淡；身子按压扁的方向缩短、另一边略胀，贴着撞上的那一侧压。
  void _penguin(Canvas canvas, Offset at, _Pose pose) {
    final colors = scene.colors, radius = scene.cell * .37;
    canvas.drawOval(Rect.fromCenter(center: at + Offset(0, radius * .86), width: radius * 1.7 * (1 - pose.hop * .7), height: radius * .5 * (1 - pose.hop * .7)), Paint()..color = colors.shadow.withValues(alpha: colors.shadow.a * (1 - pose.hop)));
    final horizontal = pose.squashDirection == iceLeft || pose.squashDirection == iceRight;
    final along = 1 - pose.squash, across = 1 + pose.squash * .55;
    canvas.save();
    canvas.translate(at.dx, at.dy - pose.hop * scene.cell);
    // 压扁时贴着前进那一侧：中心往那边挪半个缩短量，前沿不动。
    canvas.translate(_unit(pose.squashDirection).dx * radius * pose.squash, _unit(pose.squashDirection).dy * radius * pose.squash);
    canvas.scale(horizontal ? along : across, horizontal ? across : along);
    // 朝哪边看：脸往那边偏一点。
    final look = _unit(pose.facing);
    final face = Offset(look.dx * radius * .14, look.dy * radius * .06);
    final body = Rect.fromCenter(center: Offset.zero, width: radius * 1.86, height: radius * 2);
    final feet = Path()
      ..addOval(Rect.fromCenter(center: Offset(-radius * .34 + face.dx * .4, radius * .92), width: radius * .44, height: radius * .24))
      ..addOval(Rect.fromCenter(center: Offset(radius * .34 + face.dx * .4, radius * .92), width: radius * .44, height: radius * .24));
    canvas.drawPath(feet, Paint()..color = colors.beak);
    final flippers = Path()
      ..addOval(Rect.fromCenter(center: Offset(-radius * .9, radius * .2), width: radius * .42, height: radius * .9))
      ..addOval(Rect.fromCenter(center: Offset(radius * .9, radius * .2), width: radius * .42, height: radius * .9));
    canvas.drawPath(flippers, Paint()..color = colors.penguin);
    canvas.drawOval(body, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color.lerp(colors.penguin, Colors.white, .14)!, colors.penguin]).createShader(body));
    canvas.drawOval(Rect.fromCenter(center: Offset(face.dx, radius * .2 + face.dy), width: radius * 1.36, height: radius * 1.5), Paint()..color = colors.belly);
    canvas.drawOval(Rect.fromCenter(center: Offset(-radius * .36, -radius * .68), width: radius * .4, height: radius * .2), Paint()..color = Colors.white.withValues(alpha: colors.dark ? .12 : .22));
    final cheeks = Path()
      ..addOval(Rect.fromCenter(center: Offset(face.dx - radius * .44, radius * .12 + face.dy), width: radius * .26, height: radius * .16))
      ..addOval(Rect.fromCenter(center: Offset(face.dx + radius * .44, radius * .12 + face.dy), width: radius * .26, height: radius * .16));
    canvas.drawPath(cheeks, Paint()..color = colors.blush);
    final eyes = Path()
      ..addOval(Rect.fromCircle(center: Offset(face.dx - radius * .27, -radius * .12 + face.dy), radius: radius * .12))
      ..addOval(Rect.fromCircle(center: Offset(face.dx + radius * .27, -radius * .12 + face.dy), radius: radius * .12));
    canvas.drawPath(eyes, Paint()..color = colors.eye);
    final sparkles = Path()
      ..addOval(Rect.fromCircle(center: Offset(face.dx - radius * .23, -radius * .16 + face.dy), radius: radius * .045))
      ..addOval(Rect.fromCircle(center: Offset(face.dx + radius * .31, -radius * .16 + face.dy), radius: radius * .045));
    canvas.drawPath(sparkles, Paint()..color = Colors.white);
    final beak = Path()
      ..moveTo(face.dx - radius * .14, radius * .02 + face.dy)
      ..quadraticBezierTo(face.dx, -radius * .04 + face.dy, face.dx + radius * .14, radius * .02 + face.dy)
      ..quadraticBezierTo(face.dx + radius * .02, radius * .2 + face.dy, face.dx, radius * .2 + face.dy)
      ..quadraticBezierTo(face.dx - radius * .02, radius * .2 + face.dy, face.dx - radius * .14, radius * .02 + face.dy)
      ..close();
    canvas.drawPath(beak, Paint()..color = colors.beak);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PiecePainter oldDelegate) => true;
}
