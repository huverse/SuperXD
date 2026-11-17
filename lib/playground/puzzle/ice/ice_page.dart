import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:superxd/playground/play_controls.dart';
import 'package:superxd/playground/challenge/play_challenge.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/ice/ice_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';

// 冰面滑行对局页：在棋盘上朝上下左右滑动（或点棋盘下方的方向按钮）推动小企鹅，它一直滑到撞上岩石或边界、滑进雪地才停；
// 收齐宝石后正好停在终点（插旗的光圈）上就解开。滑行时长按距离算、前快后慢，撞停时轻轻一压再弹回；滑不动时轻震、朝那边抖一下，不算步数。
// 掉进冰洞（含碎了的薄冰）或步数用完：这一局停住（状态行改写、读屏播报，同扫雷不弹提示条），方向键停用，可撤销或从头来。
class IcePage extends StatefulWidget {
  const IcePage({super.key, required this.game, required this.store, this.seeds, this.first, this.challenge});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;
  // 外壳在后台出好的第一道题（自由模式；没备好或测试注入种子时为空，当场出）。
  final PlayFirst? first;
  // 挑战里的一关（题面是服务器给的）；自由模式为空。
  final PlayChallenge? challenge;

  @override
  State<IcePage> createState() => _IcePageState();
}

class _IcePageState extends State<IcePage> with TickerProviderStateMixin {
  late final _session = PlaySession<IcePuzzle, List<int>>(game: widget.game, rules: const IceRules(), store: widget.store, seeds: widget.seeds, first: widget.first, challenge: widget.challenge);
  // 走过的每一步：方向与滑之前的局面，撤销按步退回。
  final _moves = <({int direction, IceState before})>[];
  late var _state = IceState(_session.puzzle.start);
  // 棋盘上宝石与碎冰按哪个局面画：滑行途中还是滑之前的（停下才收走宝石、薄冰碎成洞），撤销与从头来马上换。
  late final _shown = ValueNotifier(_state);
  // 正在画的这一段：从哪格滑到哪格、朝哪个方向；撤销是倒放（匀称地滑回去，不撞停）。
  late int _from = _state.cell, _to = _state.cell;
  int _direction = iceDown, _facing = iceDown, _nudgeDirection = iceDown;
  bool _rewind = false;
  // 滑行占这段动画的比例，余下的是撞停那一下（掉进冰洞没有撞停）。
  double _split = 1;
  late final _slide = AnimationController(vsync: this, value: 1)..addStatusListener(_settled);
  late final _nudge = AnimationController(vsync: this, duration: const Duration(milliseconds: 280));
  late final _cheer = AnimationController(vsync: this, duration: const Duration(milliseconds: 760));
  late final _sink = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  late final _motion = Listenable.merge([_slide, _nudge, _cheer, _sink]);
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
    _sink.dispose();
    _shown.dispose();
    _session.dispose();
    super.dispose();
  }

  // 最少几步：挑战模式没有参考解（服务器不给），就不写。
  int? get _least => _session.reference?.length;
  // 这一局停住了：掉进冰洞，或步数用完还没到。
  bool get _spent => !_state.fallen && _moves.length >= _session.puzzle.limit && !iceArrived(_session.puzzle, _state);
  bool get _stopped => _state.fallen || _spent;

  void _reset() {
    _moves.clear();
    _state = IceState(_session.puzzle.start);
    _shown.value = _state;
    _from = _to = _state.cell;
    _direction = _facing = iceDown;
    _rewind = false;
    _split = 1;
    _slide.value = 1;
    _nudge.value = 0;
    _cheer.value = 0;
    _sink.value = 0;
  }

  void _newGame(PuzzleTier? tier) => setState(() {
    _session.next(tier: tier);
    _reset();
  });

  void _restart() => setState(() {
    _session.restart();
    _reset();
  });

  // 一段滑行播完：宝石收走、薄冰碎成洞；掉进冰洞的接着往下沉。
  void _settled(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _shown.value = _state;
    if (_state.fallen && !_rewind && mounted && !MediaQuery.disableAnimationsOf(context)) unawaited(_sink.forward(from: 0));
  }

  // 推一下：滑得动就记一步并播滑行，收齐宝石停在终点即解开；滑不动轻震、朝那个方向抖一下，不算步数。掉进冰洞、走满步数重震、停住。
  void _push(int direction) {
    if (_session.finished || _stopped) return;
    final puzzle = _session.puzzle;
    final next = iceMove(puzzle, _state, direction);
    if (identical(next, _state)) {
      playRejected();
      _slide.value = 1;
      _nudgeDirection = direction;
      setState(() => _facing = direction);
      if (!MediaQuery.disableAnimationsOf(context)) unawaited(_nudge.forward(from: 0));
      return;
    }
    final before = _state;
    _session.moved();
    // 上一段没播完：那一段的宝石与碎冰先到位，再画这一段。
    _shown.value = before;
    _sink.value = 0;
    final slide = _animate(from: before.cell, to: next.cell, direction: direction, rewind: false, impact: !next.fallen);
    setState(() {
      _moves.add((direction: direction, before: before));
      _state = next;
      _facing = direction;
    });
    if (MediaQuery.disableAnimationsOf(context)) {
      _shown.value = next;
      if (next.fallen) _sink.value = 1;
    }
    if (iceArrived(puzzle, next)) {
      playTick();
      unawaited(_finish(slide));
    } else if (_stopped) {
      playRejected();
    } else {
      playTick();
    }
  }

  // 播一段滑行（撤销时倒放），返回播完的那一刻；减少动画时直接到位。
  // 上一段没播完又推了一下：上一段直接到位，从它的终点接着滑（快手连推时不排队等动画）。
  TickerFuture _animate({required int from, required int to, required int direction, required bool rewind, bool impact = true}) {
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
    final total = rewind || !impact ? glide : glide + _impact;
    _split = glide / total;
    _slide.duration = Duration(milliseconds: total);
    return _slide.forward(from: 0);
  }

  void _undo() {
    if (_moves.isEmpty || _session.finished) return;
    playTick();
    final move = _moves.removeLast();
    _sink.value = 0;
    _animate(from: _state.cell, to: move.before.cell, direction: (move.direction + 2) % iceDirections, rewind: true);
    setState(() => _state = move.before);
    _shown.value = move.before;
  }

  // 解开：停表记成绩，等滑到终点、在终点上轻轻一跳（光圈同时漾开）再弹结果；减少动画时直接弹。
  // 中途换题或从头来会停掉动画，等着的这一段就不再往下走。
  Future<void> _finish(TickerFuture slide) async {
    final newBest = await _session.finish(moves: _moves.length, answer: [for (final move in _moves) move.direction]);
    await slide;
    if (!mounted) return;
    if (!MediaQuery.disableAnimationsOf(context)) await _cheer.forward(from: 0);
    if (!mounted) return;
    final least = _least;
    final choice = await showPlayResult(context, session: _session, newBest: newBest, detail: least == null ? '${_moves.length} 步' : _moves.length == least ? '$least 步，正好最少' : '${_moves.length} 步，最少 $least 步');
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

  // 棋子此刻的样子：位置（格坐标，格中心是 .5）、压扁多少与沿哪个方向、跳多高、沉下去多少、划痕与终点光圈。
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
    // 掉进冰洞：滑到洞上才开始沉（减少动画时直接沉到底）。
    final sink = _state.fallen && !_rewind && t >= 1 ? _sink.value : 0.0;
    final trail = _rewind || t >= 1 ? 0.0 : gliding ? 1.0 : 1 - impactProgress;
    return _Pose(at: at, facing: _facing, squash: squash, squashDirection: squashDirection, hop: hop, sink: sink, trailFrom: from, trail: trail, ring: cheer > 0 && cheer < 1 ? cheer : 0);
  }

  String get _status {
    final puzzle = _session.puzzle;
    if (_state.fallen) return '掉进冰洞了';
    if (_spent) return '步数用完了';
    final left = puzzle.gems.length - _bits(_state.gems);
    return ['${_moves.length}/${puzzle.limit} 步', if (left > 0) '剩 $left 颗宝石'].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final finished = _session.finished, stopped = _stopped;
    return PlayFrame(
      session: _session,
      onNewGame: _newGame,
      onRestart: _restart,
      status: _status,
      controls: [
        FilledButton.icon(onPressed: _moves.isEmpty || finished ? null : _undo, icon: const CampusIcon(CampusIcons.undo), label: const Text('撤销')),
        // 停住了：原地多给一个从头来（同 ⋯ 里的同名项）。
        if (stopped) FilledButton.icon(onPressed: _restart, icon: const CampusIcon(CampusIcons.restore), label: const Text('这一题从头来')),
      ],
      board: Column(children: [
        Expanded(child: PlayBoardBox(aspectRatio: _session.puzzle.width / _session.puzzle.height, builder: _board)),
        const SizedBox(height: 16),
        PlayDirectionPad(verb: '滑', onPush: finished || stopped ? null : _push),
      ]),
    );
  }

  Widget _board(BuildContext context, Size size) {
    final palette = CampusPalette.of(context);
    final puzzle = _session.puzzle;
    final scene = _art.prepare(puzzle, size, palette);
    String place(int cell) => '第${cell ~/ puzzle.width + 1}行第${cell % puzzle.width + 1}列';
    final gems = [for (final (index, cell) in puzzle.gems.indexed) if (_state.gems & (1 << index) == 0) place(cell)];
    final stop = _state.fallen ? '掉进冰洞了' : _spent ? '步数用完了' : null;
    return Semantics(
      container: true,
      label: [
        '冰面 ${puzzle.width}×${puzzle.height}，棋子在${place(_state.cell)}',
        if (puzzle.exits.isEmpty) '终点在${place(puzzle.goal)}' else for (final (index, exit) in puzzle.exits.indexed) '${index + 1}号出口在${place(exit)}',
        if (gems.isNotEmpty) '宝石在${gems.join('、')}',
        if (puzzle.exits.isEmpty && iceArrived(puzzle, _state)) '已到达',
      ].join('，'),
      hint: '上下左右滑动推动棋子，也可以用下方的方向按钮',
      child: playSwipeArea(
        onSwipe: _push,
        child: Stack(fit: StackFit.expand, children: [
          RepaintBoundary(child: CustomPaint(painter: _IcePainter(scene))),
          RepaintBoundary(child: CustomPaint(painter: _TilePainter(scene: scene, state: _shown))),
          RepaintBoundary(child: CustomPaint(painter: _PiecePainter(scene: scene, pose: _pose, repaint: _motion))),
          // 停住时读屏播报（不弹提示条，状态行的变化读屏不会主动念）。
          if (stop != null) Positioned.fill(child: Semantics(container: true, liveRegion: true, label: stop, child: const SizedBox.expand())),
        ]),
      ),
    );
  }
}

int _bits(int value) {
  var count = 0;
  for (var rest = value; rest != 0; rest &= rest - 1) {
    count++;
  }
  return count;
}

Offset _unit(int direction) => switch (direction) {
  iceUp => const Offset(0, -1),
  iceRight => const Offset(1, 0),
  iceDown => const Offset(0, 1),
  _ => const Offset(-1, 0),
};

class _Pose {
  const _Pose({required this.at, required this.facing, required this.squash, required this.squashDirection, required this.hop, required this.sink, required this.trailFrom, required this.trail, required this.ring});
  final Offset at;
  final int facing;
  final double squash;
  final int squashDirection;
  final double hop;
  // 掉进冰洞后沉下去多少（0 到 1，到 1 就看不见了）。
  final double sink;
  final Offset trailFrom;
  final double trail;
  final double ring;
}

// 冰面的配色：全从当前配色推出。冰取三种雾色里最冷的那一个（色相离冰蓝 200° 最近），向卡片底色淡化；
// 岩石从轮廓色推出（上亮下暗）、顶上一层雪，雪地同岩石顶上的雪，冰洞是往冰色里压深的水，薄冰比冰面浅、带裂纹；
// 终点用控件激活色，宝石把激活色转到对面的色相（一眼和终点分开）；小企鹅浅色时身子取文字主色压深，深色时是偏亮的灰（像企鹅幼崽，
// 压在深色冰面上也看得清），肚皮近白，嘴和脚用提醒色（琥珀）。
class _IceColors {
  factory _IceColors(CampusPalette palette) {
    double coldness(Color color) {
      final away = (HSLColor.fromColor(color).hue - 200).abs();
      return away > 180 ? 360 - away : away;
    }

    final fog = [palette.fogSage, palette.fogChampagne, palette.fogPearl].reduce((best, color) => coldness(color) < coldness(best) ? color : best);
    final dark = palette.isDark, surface = palette.surface;
    final iceLight = dark ? Color.lerp(surface, fog, .62)! : Color.lerp(surface, fog, .26)!;
    final iceDeep = dark ? Color.lerp(palette.backgroundBottom, fog, .48)! : Color.lerp(surface, fog, .66)!;
    final accent = HSLColor.fromColor(dark ? palette.accentText : palette.accent);
    final gem = accent.withHue((accent.hue + 150) % 360).withSaturation(math.max(accent.saturation, .6)).toColor();
    return _IceColors._(
      dark: dark,
      iceLight: iceLight,
      iceDeep: iceDeep,
      rim: dark ? Color.lerp(surface, palette.onSurfaceVariant, .2)! : Color.lerp(surface, Colors.white, .65)!,
      rimEdge: dark ? palette.outlineSubtle : Color.lerp(palette.outlineSubtle, fog, .5)!,
      shine: Colors.white.withValues(alpha: dark ? .2 : .75),
      seam: Colors.white.withValues(alpha: dark ? .07 : .38),
      rock: dark ? Color.lerp(palette.outlineSubtle, palette.outline, .62)! : Color.lerp(palette.outline, palette.onSurface, .18)!,
      rockShade: dark ? Color.lerp(palette.outlineSubtle, palette.backgroundTop, .15)! : Color.lerp(palette.outline, palette.onSurface, .55)!,
      snow: dark ? Color.lerp(palette.onSurfaceVariant, palette.onSurface, .55)! : Color.lerp(surface, Colors.white, .75)!,
      snowShade: dark ? Color.lerp(palette.onSurfaceVariant, palette.backgroundTop, .35)! : Color.lerp(iceDeep, palette.outline, .35)!,
      water: dark ? Color.lerp(palette.backgroundTop, Colors.black, .45)! : Color.lerp(iceDeep, palette.onSurface, .62)!,
      waterDeep: dark ? Color.lerp(palette.backgroundTop, Colors.black, .75)! : Color.lerp(iceDeep, palette.onSurface, .82)!,
      thin: dark ? Color.lerp(iceLight, palette.onSurfaceVariant, .28)! : Color.lerp(iceLight, Colors.white, .6)!,
      crack: dark ? Color.lerp(iceDeep, palette.onSurface, .45)! : Color.lerp(iceDeep, palette.outline, .7)!,
      gem: gem,
      gemLight: Color.lerp(gem, Colors.white, .55)!,
      gemEdge: Color.lerp(gem, Colors.black, .35)!,
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
    required this.snowShade,
    required this.water,
    required this.waterDeep,
    required this.thin,
    required this.crack,
    required this.gem,
    required this.gemLight,
    required this.gemEdge,
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
  final Color iceLight, iceDeep, rim, rimEdge, shine, seam, rock, rockShade, snow, snowShade, water, waterDeep, thin, crack, gem, gemLight, gemEdge, shadow, goal, pole, penguin, belly, eye, beak, blush;
}

// 棋盘几何与静态图形：雪檐、冰面、接缝、高光、霜点、雪地、薄冰、冰洞与岩石都在这里拼成几条路径，题、尺寸或配色变了才重建；
// 绘制时每种图形一次画完，不逐格画小图形。碎了会变的（薄冰碎成的洞）与会被收走的（宝石）按格另存一份，由 _TilePainter 按局面拼着画。
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
        switch (puzzle.tiles[index]) {
          case IceTile.rock:
            _rock(rect, noise);
            continue;
          case IceTile.hole:
            holes.addPath(_hole(rect, noise), Offset.zero);
            continue;
          case IceTile.snow:
            _snow(rect, noise);
            continue;
          case IceTile.thin:
            _thin(index, rect, noise);
            broken[index] = _hole(rect, noise);
            continue;
          case IceTile.ice:
            break;
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
    for (final gem in puzzle.gems) {
      gems[gem] = _gem(centerOf(gem));
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
  final drifts = Path(), driftShadow = Path(), thinIce = Path(), cracks = Path(), holes = Path();
  // 薄冰碎了的样子（同冰洞）与踩上去时多出的裂纹、每颗宝石：按格存，局面变了由 _TilePainter 挑着画。
  final broken = <int, Path>{}, splits = <int, Path>{};
  final gems = <int, ({Path stone, Path facet})>{};

  Offset centerOf(int cell) => origin + Offset((cell % puzzle.width + .5) * this.cell, (cell ~/ puzzle.width + .5) * this.cell);

  // 终点光圈的中心：在格子中线略靠下，正好垫在企鹅脚下。
  Offset get goalBase => centerOf(puzzle.goal) + Offset(0, cell * .22);

  double _vary(int noise, int salt, double range) => (_hash(noise + salt * 977) % 11 - 5) / 5 * range;

  // 绕中心的一圈点连成的平滑闭合曲线（Catmull-Rom 换成三次贝塞尔：穿过每个点、处处圆滑）：卵石与冰洞的轮廓。
  Path _blob(List<Offset> points) {
    final count = points.length;
    final path = Path()..moveTo(points[0].dx, points[0].dy);
    for (var index = 0; index < count; index++) {
      final before = points[(index + count - 1) % count], from = points[index], to = points[(index + 1) % count], after = points[(index + 2) % count];
      final first = from + (to - before) / 6, second = to - (after - from) / 6;
      path.cubicTo(first.dx, first.dy, second.dx, second.dy, to.dx, to.dy);
    }
    return path..close();
  }

  // 一块岩石：圆润的卵石，轮廓是绕中心的 7 个点（角度与远近按格号略有出入），底边压平、坐在冰上；
  // 顶上一层雪（波浪下沿，与石块求交，不会漏到别的石块上），底下一团扁的接地影。
  void _rock(Rect rect, int noise) {
    final width = cell * (.84 + _vary(noise, 1, .04)), height = cell * (.86 + _vary(noise, 2, .04));
    final center = rect.center + Offset(_vary(noise, 3, .025) * cell, cell * .02);
    const count = 7;
    final stone = _blob([
      for (var index = 0; index < count; index++)
        () {
          final angle = (index + _vary(noise, 10 + index, .16)) / count * 2 * math.pi - math.pi / 2;
          final reach = 1 + _vary(noise, 20 + index, .06);
          return center + Offset(math.cos(angle) * reach * width / 2, math.min(math.sin(angle) * reach, .7) * height / 2);
        }(),
    ]);
    rocks.addPath(stone, Offset.zero);
    final body = stone.getBounds();
    final line = body.top + body.height * (.38 + _vary(noise, 4, .04)), wave = body.height * .07;
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

  // 冰洞：冰面上一个不规则的圆洞（8 个点，比卵石扁一点，像斜看的地面），里面是深水（上沿压暗、往下渐亮）。
  Path _hole(Rect rect, int noise) {
    const count = 8;
    final center = rect.center + Offset(_vary(noise, 5, .03) * cell, cell * .03);
    return _blob([
      for (var index = 0; index < count; index++)
        () {
          final angle = (index + _vary(noise, 30 + index, .2)) / count * 2 * math.pi;
          final reach = cell * (.4 + _vary(noise, 40 + index, .04));
          return center + Offset(math.cos(angle) * reach, math.sin(angle) * reach * .78);
        }(),
    ]);
  }

  // 雪地：一团铺满格子的软雪堆（圆角方块，上沿两个小鼓包），底下一道浅影坐在冰上。
  void _snow(Rect rect, int noise) {
    final body = rect.deflate(cell * .06);
    final drift = Path()..addRRect(RRect.fromRectAndRadius(body.translate(0, cell * .04).deflate(cell * .04), Radius.circular(cell * .3)));
    final bump = body.width * (.18 + _vary(noise, 6, .03));
    drift
      ..addOval(Rect.fromCircle(center: Offset(body.left + body.width * .32, body.top + bump * .9), radius: bump))
      ..addOval(Rect.fromCircle(center: Offset(body.left + body.width * .66, body.top + bump * 1.1), radius: bump * .85));
    drifts.addPath(drift, Offset.zero);
    driftShadow.addRRect(RRect.fromRectAndRadius(Rect.fromLTRB(body.left + cell * .04, body.bottom - cell * .2, body.right - cell * .04, body.bottom + cell * .03), Radius.circular(cell * .12)));
  }

  // 薄冰：比冰面浅的一块，上面两三道细裂纹（从格内一点散开）；踩上去时再多几道（splits），碎了就是冰洞（broken）。
  void _thin(int index, Rect rect, int noise) {
    thinIce.addRRect(RRect.fromRectAndRadius(rect.deflate(cell * .05), Radius.circular(cell * .12)));
    final hub = rect.center + Offset(_vary(noise, 7, .12) * cell, _vary(noise, 8, .12) * cell);
    Path rays(int from, int count, double reach) {
      final path = Path();
      for (var ray = from; ray < from + count; ray++) {
        final angle = (ray + _vary(noise, 50 + ray, .3)) / 5 * 2 * math.pi;
        final bend = hub + Offset(math.cos(angle + .3), math.sin(angle + .3)) * cell * reach * .5;
        final end = hub + Offset(math.cos(angle), math.sin(angle)) * cell * reach;
        path
          ..moveTo(hub.dx, hub.dy)
          ..lineTo(bend.dx, bend.dy)
          ..lineTo(end.dx, end.dy);
      }
      return path;
    }

    cracks.addPath(rays(0, 3, .3), Offset.zero);
    splits[index] = rays(3, 3, .4)..addPath(rays(0, 3, .4), Offset.zero);
  }

  // 一颗宝石：正面看的切割钻（上面一条平的台面、两肩、尖朝下），台面下一块亮的刻面。
  ({Path stone, Path facet}) _gem(Offset center) {
    final size = cell * .5;
    final stone = Path()
      ..moveTo(center.dx - size * .28, center.dy - size * .42)
      ..lineTo(center.dx + size * .28, center.dy - size * .42)
      ..lineTo(center.dx + size * .5, center.dy - size * .14)
      ..lineTo(center.dx, center.dy + size * .5)
      ..lineTo(center.dx - size * .5, center.dy - size * .14)
      ..close();
    final facet = Path()
      ..moveTo(center.dx - size * .28, center.dy - size * .42)
      ..lineTo(center.dx + size * .1, center.dy - size * .42)
      ..lineTo(center.dx - size * .06, center.dy + size * .2)
      ..lineTo(center.dx - size * .5, center.dy - size * .14)
      ..close();
    return (stone: stone, facet: facet);
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

// 冰洞的填色：竖向渐变按格高重复铺开（上沿压暗、往下渐亮，像往洞里看），每个洞都落在自己那一格的同一段渐变里，一条路径一次画完。
void _paintHoles(Canvas canvas, _IceScene scene, Path holes) {
  final colors = scene.colors, cell = scene.cell, top = scene.origin.dy;
  canvas.drawPath(holes, Paint()..shader = ui.Gradient.linear(Offset(0, top), Offset(0, top + cell), [colors.waterDeep, colors.water], const [.2, .8], TileMode.repeated));
  canvas.drawPath(holes, Paint()..style = PaintingStyle.stroke..strokeWidth = math.max(1.2, cell * .05)..color = colors.shine);
}

// 静态层：雪檐、冰面（斜向渐变加两道斜光带）、接缝、高光、霜点、薄冰、雪地、冰洞、终点与岩石。
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
    canvas.drawPath(scene.thinIce, Paint()..color = colors.thin);
    canvas.drawPath(scene.cracks, Paint()..style = PaintingStyle.stroke..strokeWidth = math.max(1, cell * .035)..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round..color = colors.crack);
    canvas.drawPath(scene.driftShadow, Paint()..color = colors.snowShade);
    canvas.drawPath(scene.drifts, Paint()..color = colors.snow);
    _paintHoles(canvas, scene, scene.holes);
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
  // 挑战里碎片改目标时（题面带 exits，人工决策见 challenge_rules.dart）：几个出口各画一圈光圈、写上 ①②③，不插旗、不标哪个是终点。
  void _goal(Canvas canvas) {
    final colors = scene.colors, cell = scene.cell, base = scene.goalBase;
    if (scene.puzzle.exits.isNotEmpty) {
      for (final (index, exit) in scene.puzzle.exits.indexed) {
        final center = scene.centerOf(exit);
        canvas.drawOval(Rect.fromCenter(center: center + Offset(0, cell * .22), width: cell * .66, height: cell * .3), Paint()..style = PaintingStyle.stroke..strokeWidth = math.max(1.6, cell * .06)..color = colors.goal);
        final label = TextPainter(text: TextSpan(text: '①②③④'[index], style: TextStyle(fontSize: math.max(14, cell * .5), color: colors.goal, fontWeight: FontWeight.w600)), textDirection: TextDirection.ltr)..layout();
        label.paint(canvas, center - Offset(label.width / 2, label.height * .62));
        label.dispose();
      }
      return;
    }
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

// 随局面变的那一层：碎了的薄冰画成冰洞（棋子还站在上面的那块画成裂开的薄冰），没收走的宝石。局面变了才重画（不逐帧）。
class _TilePainter extends CustomPainter {
  _TilePainter({required this.scene, required this.state}) : super(repaint: state);
  final _IceScene scene;
  final ValueNotifier<IceState> state;

  @override
  void paint(Canvas canvas, Size size) {
    final colors = scene.colors, puzzle = scene.puzzle, cell = scene.cell, now = state.value;
    final holes = Path(), splits = Path(), stones = Path(), facets = Path();
    for (final (index, thin) in puzzle.thin.indexed) {
      if (now.broken & (1 << index) == 0) continue;
      if (thin == now.cell && !now.fallen) {
        splits.addPath(scene.splits[thin]!, Offset.zero);
      } else {
        holes.addPath(scene.broken[thin]!, Offset.zero);
      }
    }
    for (final (index, gem) in puzzle.gems.indexed) {
      if (now.gems & (1 << index) != 0) continue;
      stones.addPath(scene.gems[gem]!.stone, Offset.zero);
      facets.addPath(scene.gems[gem]!.facet, Offset.zero);
    }
    canvas.save();
    canvas.clipRRect(scene.ice);
    _paintHoles(canvas, scene, holes);
    canvas.drawPath(splits, Paint()..style = PaintingStyle.stroke..strokeWidth = math.max(1, cell * .04)..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round..color = colors.crack);
    canvas.drawPath(stones.shift(Offset(0, cell * .06)), Paint()..color = colors.shadow);
    canvas.drawPath(stones, Paint()..color = colors.gem);
    canvas.drawPath(facets, Paint()..color = colors.gemLight);
    canvas.drawPath(stones, Paint()..style = PaintingStyle.stroke..strokeWidth = math.max(1, cell * .035)..strokeJoin = StrokeJoin.round..color = colors.gemEdge);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TilePainter oldDelegate) => !identical(oldDelegate.scene, scene) || oldDelegate.state != state;
}

// 动的那一层：滑行划痕、终点漾开的光圈、掉进冰洞的水纹与小企鹅。按动画逐帧重画，只有这一个小东西。
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
    // 沉下去：水面漾开一圈，企鹅缩小着往洞里落，到底就不画了。
    if (pose.sink > 0 && pose.sink < 1) {
      final spread = .5 + .5 * Curves.easeOutCubic.transform(pose.sink);
      canvas.drawOval(Rect.fromCenter(center: at, width: cell * .8 * spread, height: cell * .62 * spread), Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.4, cell * .05)
        ..color = colors.shine.withValues(alpha: colors.shine.a * (1 - pose.sink)));
    }
    if (pose.sink < 1) _penguin(canvas, at, pose);
  }

  // 圆滚滚的小企鹅（正面）：影子留在冰面上，跳起时变小变淡；身子按压扁的方向缩短、另一边略胀，贴着撞上的那一侧压；沉下去时整只缩小、往下落一点。
  void _penguin(Canvas canvas, Offset at, _Pose pose) {
    final colors = scene.colors, sunk = Curves.easeInCubic.transform(pose.sink), radius = scene.cell * .37 * (1 - sunk);
    if (pose.sink == 0) {
      canvas.drawOval(Rect.fromCenter(center: at + Offset(0, radius * .86), width: radius * 1.7 * (1 - pose.hop * .7), height: radius * .5 * (1 - pose.hop * .7)), Paint()..color = colors.shadow.withValues(alpha: colors.shadow.a * (1 - pose.hop)));
    }
    final horizontal = pose.squashDirection == iceLeft || pose.squashDirection == iceRight;
    final along = 1 - pose.squash, across = 1 + pose.squash * .55;
    canvas.save();
    canvas.translate(at.dx, at.dy - pose.hop * scene.cell + sunk * scene.cell * .18);
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
