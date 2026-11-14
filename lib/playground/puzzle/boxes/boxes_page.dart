import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/playground/play_controls.dart';
import 'package:superxd/playground/challenge/play_challenge.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/boxes/boxes_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';

// 推箱子对局页：在棋盘上朝上下左右滑一下（或点棋盘下方的方向键）走一格，走进箱子就把它朝前推一格；
// 推不动（前面是墙或另一个箱子）、撞墙时轻震、小人朝那边顶一下，不算一步。全部箱子推到目标点上即解开。
// 状态只计推了几次（同最少推数比），撤销按步退回（推了箱子的那步连箱子一起退）。
class BoxesPage extends StatefulWidget {
  const BoxesPage({super.key, required this.game, required this.store, this.seeds, this.challenge});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;
  // 挑战里的一关（题面是服务器给的）；自由模式为空。
  final PlayChallenge? challenge;

  @override
  State<BoxesPage> createState() => _BoxesPageState();
}

// 走过的一步：朝哪走、走之前小人在哪、推了哪个箱子（boxes 里的下标，没推是 -1）。
typedef _Move = ({int direction, int from, int box});

class _BoxesPageState extends State<BoxesPage> with TickerProviderStateMixin {
  late final _session = PlaySession<BoxesPuzzle, List<int>>(game: widget.game, rules: const BoxesRules(), store: widget.store, seeds: widget.seeds, challenge: widget.challenge);
  late List<int> _boxes = [..._session.puzzle.boxes];
  late int _player = _session.puzzle.player;
  final _moves = <_Move>[];
  late int? _least = _leastPushes();
  // 正在画的这一步：小人从哪格来、哪个箱子从哪格来（没动的箱子是 -1）。
  late int _fromPlayer = _player;
  int _movedBox = -1, _fromBox = -1;
  int _facing = playDown, _nudgeDirection = playDown;
  late final _step = AnimationController(vsync: this, duration: const Duration(milliseconds: 110), value: 1);
  late final _nudge = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  late final _cheer = AnimationController(vsync: this, duration: const Duration(milliseconds: 720));
  late final _motion = Listenable.merge([_step, _nudge, _cheer]);
  final _art = _BoxesArt();

  @override
  void dispose() {
    _step.dispose();
    _nudge.dispose();
    _cheer.dispose();
    _session.dispose();
    super.dispose();
  }

  // 最少推数：挑战模式没有参考解（服务器不给），就不写。
  int? _leastPushes() => switch (_session.reference) {
    final solution? => boxesReplay(_session.puzzle, solution).pushes,
    null => null,
  };
  int get _pushes => _moves.where((move) => move.box >= 0).length;
  bool get _reduced => MediaQuery.disableAnimationsOf(context);

  void _reset() {
    _boxes = [..._session.puzzle.boxes];
    _player = _fromPlayer = _session.puzzle.player;
    _moves.clear();
    _least = _leastPushes();
    _movedBox = _fromBox = -1;
    _facing = playDown;
    _step.value = 1;
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

  // 走一步：走得动就记一步并播动画（推了箱子轻触一下），全部到位即解开；撞墙或推不动轻震、朝那边顶一下，不算一步。
  // 上一步没播完又走：上一步直接到位、从它的终点接着走（快手连按时不排队等动画）。
  void _go(int direction) {
    if (_session.finished) return;
    final puzzle = _session.puzzle;
    final step = boxesStep(puzzle, _boxes, _player, direction);
    if (step == null) {
      playRejected();
      _step.value = 1;
      _nudgeDirection = direction;
      setState(() => _facing = direction);
      if (!_reduced) unawaited(_nudge.forward(from: 0));
      return;
    }
    if (step.box >= 0) playTick();
    _session.moved();
    final moved = step.box;
    final boxFrom = moved >= 0 ? _boxes[moved] : -1;
    setState(() {
      _moves.add((direction: direction, from: _player, box: moved));
      if (moved >= 0) _boxes[moved] = boxesNeighbor(puzzle, step.to, direction)!;
      _facing = direction;
      _animate(fromPlayer: _player, box: moved, fromBox: boxFrom);
      _player = step.to;
    });
    if (moved >= 0 && boxesAllHome(puzzle, _boxes)) unawaited(_finish());
  }

  void _animate({required int fromPlayer, required int box, required int fromBox}) {
    _fromPlayer = fromPlayer;
    _movedBox = box;
    _fromBox = fromBox;
    _nudge.value = 0;
    if (_reduced) {
      _step.value = 1;
    } else {
      unawaited(_step.forward(from: 0));
    }
  }

  void _undo() {
    if (_moves.isEmpty || _session.finished) return;
    playTick();
    setState(() {
      final move = _moves.removeLast();
      final boxFrom = move.box >= 0 ? _boxes[move.box] : -1;
      // 推的那一步：箱子从前面一格退回小人现在站的这一格。
      if (move.box >= 0) _boxes[move.box] = _player;
      _animate(fromPlayer: _player, box: move.box, fromBox: boxFrom);
      _player = move.from;
      _facing = move.direction;
    });
  }

  // 解开：停表记成绩，等最后一推走完、箱子依次轻轻一跳（亮一下）再弹结果；减少动画时直接弹。
  Future<void> _finish() async {
    final newBest = await _session.finish(moves: _pushes, answer: [for (final move in _moves) move.direction]);
    if (!mounted) return;
    if (!_reduced) {
      await _step.forward();
      if (!mounted) return;
      await _cheer.forward(from: 0);
    }
    if (!mounted) return;
    final pushes = _pushes;
    final choice = await showPlayResult(context, session: _session, newBest: newBest, detail: _least == null ? '推 $pushes 次' : pushes == _least ? '推 $pushes 次，正好最少' : '推 $pushes 次，最少 $_least 次');
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

  @override
  Widget build(BuildContext context) {
    final finished = _session.finished;
    final puzzle = _session.puzzle;
    final left = _boxes.where((box) => !puzzle.goals.contains(box)).length;
    return PlayFrame(
      session: _session,
      onNewGame: _newGame,
      onRestart: _restart,
      status: ['推 $_pushes 次', if (_least case final least?) '最少 $least 次'].join(' · '),
      controls: [
        FilledButton.icon(onPressed: _moves.isEmpty || finished ? null : _undo, icon: const CampusIcon(CampusIcons.undo), label: const Text('撤销')),
      ],
      board: Column(children: [
        Expanded(child: PlayBoardBox(aspectRatio: puzzle.width / puzzle.height, builder: (context, size) {
          final scene = _art.prepare(puzzle, size, CampusPalette.of(context));
          return Semantics(
            container: true,
            label: '房间 ${puzzle.width - 2}×${puzzle.height - 2}，你在第${_player ~/ puzzle.width}行第${_player % puzzle.width}列，${left == 0 ? '箱子都到位了' : '还差 $left 个箱子到位'}',
            hint: '上下左右滑动走一格，也可以用下方的方向按钮',
            child: playSwipeArea(
              onSwipe: finished ? null : _go,
              child: Stack(fit: StackFit.expand, children: [
                RepaintBoundary(child: CustomPaint(painter: _RoomPainter(scene))),
                RepaintBoundary(child: CustomPaint(painter: _PiecePainter(state: this, scene: scene, repaint: _motion))),
              ]),
            ),
          );
        })),
        const SizedBox(height: 16),
        PlayDirectionPad(verb: '走', onPush: finished ? null : _go),
      ]),
    );
  }
}

Offset _unit(int direction) => switch (direction) {
  playUp => const Offset(0, -1),
  playRight => const Offset(1, 0),
  playDown => const Offset(0, 1),
  _ => const Offset(-1, 0),
};

// 配色全从色板推出：地面是卡片底，墙是比地面深一档的灰，目标点与到位的箱子是激活色，没到位的箱子是淡激活色的软方块，小人是正文色系。
class _BoxesColors {
  _BoxesColors(CampusPalette palette)
    : floor = palette.surface,
      tile = Color.lerp(palette.surface, palette.surfaceSelected, .45)!,
      wall = Color.lerp(palette.surfaceSelected, palette.onSurfaceVariant, palette.isDark ? .35 : .42)!,
      wallTop = Color.lerp(palette.surfaceSelected, palette.onSurfaceVariant, palette.isDark ? .2 : .26)!,
      goal = palette.accent.withValues(alpha: palette.isDark ? .75 : .6),
      box = Color.lerp(palette.accent, palette.surface, palette.isDark ? .3 : .62)!,
      boxEdge = Color.lerp(palette.accent, palette.onSurface, .25)!,
      boxHome = palette.accent,
      body = Color.lerp(palette.onSurface, palette.accent, .25)!,
      eye = palette.surface,
      shadow = Colors.black.withValues(alpha: palette.isDark ? .35 : .14);
  final Color floor, tile, wall, wallTop, goal, box, boxEdge, boxHome, body, eye, shadow;
}

// 一道题、一个尺寸、一套配色下的静态画面：地面（隔格淡底，像铺砖）、贴着地面的墙块（看得到的墙才画，房间轮廓随墙走）、目标点圆环。
// 都拼成几条路径，按题缓存，只在换题、尺寸或配色变了才重算。
class _BoxesScene {
  _BoxesScene(this.puzzle, this.size, this.palette) : colors = _BoxesColors(palette), cell = size.width / puzzle.width {
    final width = puzzle.width, height = puzzle.height;
    bool floorAt(int row, int column) => row >= 0 && row < height && column >= 0 && column < width && !puzzle.walls[row * width + column];
    // 看得见的墙：贴着地面（八个方向）的墙格；外面那圈空的不画，房间轮廓就是墙拼出来的样子。
    bool touchesFloor(int row, int column) {
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (floorAt(row + dy, column + dx)) return true;
        }
      }
      return false;
    }

    final visible = [for (var index = 0; index < width * height; index++) puzzle.walls[index] && touchesFloor(index ~/ width, index % width)];
    bool wallAt(int row, int column) => row >= 0 && row < height && column >= 0 && column < width && visible[row * width + column];
    final round = Radius.circular(cell * .22);
    for (var index = 0; index < width * height; index++) {
      final row = index ~/ width, column = index % width;
      final rect = Rect.fromLTWH(column * cell, row * cell, cell, cell);
      if (!puzzle.walls[index]) {
        floor.addRect(rect.inflate(.5));
        if ((row + column).isEven) tiles.addRect(rect);
        continue;
      }
      if (!visible[index]) continue;
      // 墙连成一片：只有两边都不是墙的外凸角才圆，相邻的墙格之间不留缝（各多铺半个像素防接缝）。
      final up = wallAt(row - 1, column), down = wallAt(row + 1, column), left = wallAt(row, column - 1), right = wallAt(row, column + 1);
      Radius corner(bool a, bool b) => a || b ? Radius.zero : round;
      final block = Rect.fromLTRB(rect.left - (left ? .5 : 0), rect.top - (up ? .5 : 0), rect.right + (right ? .5 : 0), rect.bottom + (down ? .5 : 0));
      walls.addRRect(RRect.fromRectAndCorners(block, topLeft: corner(up, left), topRight: corner(up, right), bottomLeft: corner(down, left), bottomRight: corner(down, right)));
      // 顶面：下面不是墙的格把顶面抬高一截，露出的那一截是深一点的立面，墙看起来有厚度。
      final top = down ? block : Rect.fromLTRB(block.left, block.top, block.right, block.bottom - cell * .24);
      wallTops.addRRect(RRect.fromRectAndCorners(top, topLeft: corner(up, left), topRight: corner(up, right), bottomLeft: corner(down, left), bottomRight: corner(down, right)));
    }
    for (final goal in puzzle.goals) {
      final center = Offset((goal % width + .5) * cell, (goal ~/ width + .5) * cell);
      rings.addOval(Rect.fromCircle(center: center, radius: cell * .3));
      dots.addOval(Rect.fromCircle(center: center, radius: cell * .08));
    }
  }

  final BoxesPuzzle puzzle;
  final Size size;
  final CampusPalette palette;
  final _BoxesColors colors;
  final double cell;
  final floor = Path(), tiles = Path(), walls = Path(), wallTops = Path(), rings = Path(), dots = Path();

  Offset center(int cell) => Offset((cell % puzzle.width + .5) * this.cell, (cell ~/ puzzle.width + .5) * this.cell);
}

class _BoxesArt {
  _BoxesScene? _scene;

  _BoxesScene prepare(BoxesPuzzle puzzle, Size size, CampusPalette palette) {
    final scene = _scene;
    if (scene != null && identical(scene.puzzle, puzzle) && scene.size == size && scene.palette == palette) return scene;
    return _scene = _BoxesScene(puzzle, size, palette);
  }
}

class _RoomPainter extends CustomPainter {
  _RoomPainter(this.scene);
  final _BoxesScene scene;

  @override
  void paint(Canvas canvas, Size size) {
    final colors = scene.colors;
    canvas.drawPath(scene.floor, Paint()..color = colors.floor);
    canvas.drawPath(scene.tiles, Paint()..color = colors.tile);
    canvas.drawPath(scene.walls, Paint()..color = colors.wall);
    canvas.drawPath(scene.wallTops, Paint()..color = colors.wallTop);
    canvas.drawPath(scene.rings, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, scene.cell * .07)
      ..color = colors.goal);
    canvas.drawPath(scene.dots, Paint()..color = colors.goal);
  }

  @override
  bool shouldRepaint(_RoomPainter old) => !identical(old.scene, scene);
}

// 箱子与小人：按动画进度插值位置；推不动时小人朝那边顶一下；解开时箱子依次轻轻一跳、亮一下。
class _PiecePainter extends CustomPainter {
  _PiecePainter({required this.state, required this.scene, required Listenable repaint}) : super(repaint: repaint);
  final _BoxesPageState state;
  final _BoxesScene scene;

  @override
  void paint(Canvas canvas, Size size) {
    final colors = scene.colors, cell = scene.cell, puzzle = scene.puzzle;
    final travel = Curves.easeOutCubic.transform(state._step.value);
    final cheer = state._cheer.value;
    final boxes = state._boxes;
    final home = Paint()..color = colors.boxHome;
    final away = Paint()..color = colors.box;
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, cell * .045);
    final shadow = Paint()..color = colors.shadow;
    for (final (index, box) in boxes.indexed) {
      var center = scene.center(box);
      if (index == state._movedBox && state._fromBox >= 0) center = Offset.lerp(scene.center(state._fromBox), center, travel)!;
      final onGoal = puzzle.goals.contains(box) && (index != state._movedBox || travel >= 1);
      // 解开：箱子按下标错开，各自在一小段里跳起落下。
      final local = ((cheer - index * .12) / .5).clamp(0.0, 1.0);
      final lift = math.sin(local * math.pi) * cell * .14;
      final rect = Rect.fromCenter(center: center - Offset(0, lift), width: cell * .78, height: cell * .78);
      final radius = Radius.circular(cell * .16);
      canvas.drawRRect(RRect.fromRectAndRadius(rect.shift(Offset(0, cell * .05 + lift * .6)), radius), shadow);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), onGoal ? home : away);
      // 箱面：内框与一道斜撑，像木箱；到位的换成浅色线。
      final inner = rect.deflate(cell * .14);
      edge.color = onGoal ? colors.floor.withValues(alpha: .7) : colors.boxEdge.withValues(alpha: .55);
      canvas.drawRRect(RRect.fromRectAndRadius(inner, Radius.circular(cell * .06)), edge);
      canvas.drawLine(inner.topLeft, inner.bottomRight, edge);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), edge..color = onGoal ? colors.boxHome : colors.boxEdge.withValues(alpha: .8));
      if (onGoal && local > 0 && local < 1) {
        canvas.drawRRect(RRect.fromRectAndRadius(rect.inflate(cell * .08 * math.sin(local * math.pi)), radius), Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = cell * .05
          ..color = colors.boxHome.withValues(alpha: .4 * math.sin(local * math.pi)));
      }
    }
    // 小人：圆身子、两只眼睛朝前进方向偏一点；推不动时朝那边顶一下再回来。
    var at = Offset.lerp(scene.center(state._fromPlayer), scene.center(state._player), travel)!;
    final nudge = state._nudge.value;
    at += _unit(state._nudgeDirection) * (math.sin(nudge * math.pi * 2.5) * (1 - nudge) * cell * .14);
    final radius = cell * .33;
    canvas.drawOval(Rect.fromCenter(center: at + Offset(0, radius * .9), width: radius * 1.6, height: radius * .45), shadow);
    canvas.drawCircle(at, radius, Paint()..color = colors.body);
    final look = _unit(state._facing) * radius * .22;
    final eyeGap = radius * .38;
    final across = state._facing == playUp || state._facing == playDown ? const Offset(1, 0) : const Offset(0, 1);
    for (final side in [-1.0, 1.0]) {
      final eye = at + look + across * eyeGap * side - (state._facing == playUp ? Offset.zero : Offset(0, radius * .12));
      canvas.drawCircle(eye, radius * .24, Paint()..color = colors.eye);
      canvas.drawCircle(eye + look * .5, radius * .11, Paint()..color = colors.body);
    }
  }

  @override
  bool shouldRepaint(_PiecePainter old) => true;
}
