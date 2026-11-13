import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/pour/pour_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_transitions.dart';

// 画线入杯对局页：在棋盘上用手指画线（每走 pourMinSegment 记一个点，墨水用完或碰到球的起点这一笔就停），松手后线固定不动；
// 点「放球」后按固定步长逐帧推进同一份物理模拟，全部球进杯停稳就解开，没进提示再试一次，可以撤销上一笔或整个重画。
class PourPage extends StatefulWidget {
  const PourPage({super.key, required this.game, required this.store, this.seeds});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;

  @override
  State<PourPage> createState() => _PourPageState();
}

class _PourPageState extends State<PourPage> with TickerProviderStateMixin, WidgetsBindingObserver {
  late final _session = PlaySession<PourPuzzle, List<List<int>>>(game: widget.game, rules: const PourRules(), store: widget.store, seeds: widget.seeds);
  // 画好的线（每笔一串点，单位坐标）与正在画的这一笔；这一笔被墨水或球挡住后不再加点，松手才算画完。
  final _strokes = <List<int>>[];
  List<int>? _drawing;
  int? _pointer;
  bool _blocked = false;
  // 画好的线用掉的墨水与正在画的这一笔的长度：加法顺序同 pourInkUsed，页面放行的画法判定时一分不差。
  double _committed = 0, _current = 0;
  // 放球：这一次的模拟（没进杯时留着，球停在原处，下一次操作才收回起点）、是否在走、攒下没走完的时间。
  PourSimulation? _simulation;
  bool _running = false;
  double _carry = 0;
  Duration? _last;
  late final _ticker = createTicker(_tick);
  final _frame = ValueNotifier(0);
  late final _cheer = AnimationController(vsync: this, duration: const Duration(milliseconds: 720));
  late final _motion = Listenable.merge([_frame, _cheer]);
  final _art = _PourArt();
  // 棋盘每单位多少逻辑像素（排版时按棋盘宽度算）。
  double _scale = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _simulation?.dispose();
    _cheer.dispose();
    _frame.dispose();
    _session.dispose();
    super.dispose();
  }

  // 离开前台时模拟停在原处（静音的计时器不回调），回到前台从这一帧重新算起，不追赶离开的那段时间。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _ticker.muted = state != AppLifecycleState.resumed;
    _last = null;
  }

  PourPuzzle get _puzzle => _session.puzzle;

  // 墨水还剩百分之几：剩下的不够再画一段就算 0。
  int get _inkLeft {
    final left = _puzzle.ink - (_committed + _current);
    return left < pourMinSegment ? 0 : (left / _puzzle.ink * 100).ceil();
  }

  void _reset() {
    _ticker.stop();
    _clearRun();
    _running = false;
    _strokes.clear();
    _drawing = _pointer = null;
    _blocked = false;
    _committed = _current = 0;
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

  // 收掉上一次放球（球回到起点）。
  void _clearRun() {
    _simulation?.dispose();
    _simulation = null;
  }

  (int, int) _point(Offset local) => ((local.dx / _scale).round().clamp(0, pourWidth), (local.dy / _scale).round().clamp(0, pourHeight));

  void _reject(String message) {
    _blocked = true;
    playRejected();
    showCampusToast(context, message);
  }

  void _down(PointerDownEvent event) {
    if (_pointer != null || _session.finished) return;
    if (_running) {
      playRejected();
      showCampusToast(context, '放球中不能画线');
      return;
    }
    if (_inkLeft == 0) {
      playRejected();
      showCampusToast(context, '墨水用完了，可以撤销或重画');
      return;
    }
    final (x, y) = _point(event.localPosition);
    if (!pourSegmentClear(_puzzle, x, y, x, y)) {
      playRejected();
      showCampusToast(context, '线不能碰到球');
      return;
    }
    hideCampusToast();
    _clearRun();
    _pointer = event.pointer;
    _blocked = false;
    _current = 0;
    setState(() => _drawing = [x, y]);
  }

  // 手指每走够 pourMinSegment 加一个点；墨水不够走完这一段就截在用完的地方、碰到球的起点就不画这一段，这一笔到此为止。
  void _move(PointerMoveEvent event) {
    final drawing = _drawing;
    if (event.pointer != _pointer || drawing == null || _blocked) return;
    final lastX = drawing[drawing.length - 2], lastY = drawing[drawing.length - 1];
    final (aimX, aimY) = _point(event.localPosition);
    final full = pourStrokeLength([lastX, lastY, aimX, aimY]);
    if (full < pourMinSegment) return;
    var (x, y, length) = (aimX, aimY, full);
    final empty = _committed + (_current + length) > _puzzle.ink;
    if (empty) {
      // 从刚好用完的位置往回退，直到取整后的这一段放得下。
      for (var reach = (_puzzle.ink - _committed - _current) / full; ; reach -= 1 / full) {
        if (reach <= 0) {
          length = 0;
          break;
        }
        x = (lastX + (aimX - lastX) * reach).round();
        y = (lastY + (aimY - lastY) * reach).round();
        length = pourStrokeLength([lastX, lastY, x, y]);
        if (_committed + (_current + length) <= _puzzle.ink) break;
      }
    }
    if (length > 0) {
      if (!pourSegmentClear(_puzzle, lastX, lastY, x, y)) {
        _reject('线不能碰到球');
        return;
      }
      _session.moved();
      setState(() {
        drawing.addAll([x, y]);
        _current += length;
      });
    }
    if (empty) _reject('墨水用完了，可以撤销或重画');
  }

  void _up(PointerEvent event) {
    final drawing = _drawing;
    if (event.pointer != _pointer || drawing == null) return;
    _pointer = null;
    if (drawing.length >= 4) playTick();
    setState(() {
      _drawing = null;
      if (drawing.length >= 4) _strokes.add(drawing);
      _committed = pourInkUsed(_strokes);
      _current = 0;
    });
  }

  void _undo() {
    if (_strokes.isEmpty || _running || _session.finished) return;
    hideCampusToast();
    playTick();
    _clearRun();
    setState(() {
      _strokes.removeLast();
      _committed = pourInkUsed(_strokes);
    });
  }

  void _clear() {
    if (_strokes.isEmpty || _running || _session.finished) return;
    hideCampusToast();
    playTick();
    _clearRun();
    setState(() {
      _strokes.clear();
      _committed = 0;
    });
  }

  // 放球：按画好的线建一份模拟逐帧推进；放球中再点是「停下」，球收回起点、回去接着画。
  void _drop() {
    if (_session.finished || _drawing != null) return;
    playTick();
    if (_running) {
      _ticker.stop();
      _clearRun();
      setState(() => _running = false);
      return;
    }
    hideCampusToast();
    _session.moved();
    _clearRun();
    _simulation = PourSimulation(_puzzle, List.of(_strokes));
    _carry = 0;
    _last = null;
    setState(() => _running = true);
    unawaited(_ticker.start());
  }

  // 每帧按真实流逝的时间推进固定步长；一帧最多追 4 步（卡顿时宁可慢一点，也不让球跳着走）。
  void _tick(Duration elapsed) {
    final simulation = _simulation;
    if (simulation == null) return;
    final last = _last;
    _last = elapsed;
    if (last == null) return;
    _carry = math.min(_carry + (elapsed - last).inMicroseconds / Duration.microsecondsPerSecond, pourStep * 4);
    while (_carry >= pourStep && simulation.outcome == PourOutcome.running) {
      simulation.step();
      _carry -= pourStep;
    }
    _frame.value++;
    if (simulation.outcome == PourOutcome.running) return;
    _ticker.stop();
    setState(() => _running = false);
    if (simulation.outcome == PourOutcome.won) {
      unawaited(_finish());
    } else {
      showCampusToast(context, '没进杯，再试一次');
    }
  }

  // 解开：停表记成绩，杯子亮一下、光圈漾开，再弹结果；减少动画时直接弹。中途换题或从头来会停掉动画，等着的这一段就不再往下走。
  Future<void> _finish() async {
    final strokes = _strokes.length, used = 100 - _inkLeft;
    final newBest = await _session.finish(moves: strokes);
    if (!mounted) return;
    if (!MediaQuery.disableAnimationsOf(context)) await _cheer.forward(from: 0);
    if (!mounted) return;
    final choice = await showPlayResult(context, session: _session, newBest: newBest, detail: '$strokes 笔，用掉 $used% 的墨水');
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

  // 球此刻的位置：放过球就取模拟里的，否则在起点。
  List<({double x, double y, double angle})> _balls() {
    final simulation = _simulation, balls = _puzzle.balls;
    return [
      for (var index = 0; index < _puzzle.ballCount; index++) simulation?.ball(index) ?? (x: balls[index * 2].toDouble(), y: balls[index * 2 + 1].toDouble(), angle: 0.0),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final finished = _session.finished, editable = _strokes.isNotEmpty && !_running && !finished;
    return PlayFrame(
      session: _session,
      onNewGame: _newGame,
      onRestart: _restart,
      status: ['墨水 $_inkLeft%', if (_strokes.isNotEmpty) '${_strokes.length} 笔'].join(' · '),
      controls: [
        FilledButton.icon(onPressed: editable ? _undo : null, icon: const CampusIcon(CampusIcons.undo), label: const Text('撤销')),
        FilledButton.icon(onPressed: editable ? _clear : null, icon: const CampusIcon(CampusIcons.erase), label: const Text('重画')),
        FilledButton.icon(style: campusProminent, onPressed: finished ? null : _drop, icon: CampusIcon(_running ? CampusIcons.stop : CampusIcons.resume), label: Text(_running ? '停下' : '放球')),
      ],
      board: PlayBoardBox(aspectRatio: pourWidth / pourHeight, builder: _board),
    );
  }

  // 读屏：画线对读屏不友好，至少讲清楚球、杯子与障碍在哪、墨水还剩多少、上一次放球的结果；放球、撤销、重画是下方的按钮。
  String _describe() {
    final puzzle = _puzzle;
    String side(num x) => x < pourWidth / 3 ? '左侧' : (x > pourWidth * 2 / 3 ? '右侧' : '正中');
    final state = _running ? '，球在滚' : (_simulation?.outcome == PourOutcome.lost ? '，上一次没进杯' : '');
    return '画线入杯：上方${side(puzzle.balls[0])}有 ${puzzle.ballCount} 个球，杯子在下方${side(puzzle.cup.x)}'
        '${puzzle.blocks.isEmpty ? '' : '，中间有 ${puzzle.blocks.length} 块障碍'}，墨水还剩 $_inkLeft%，已画 ${_strokes.length} 笔$state';
  }

  Widget _board(BuildContext context, Size size) {
    final palette = CampusPalette.of(context);
    _scale = size.width / pourWidth;
    final scene = _art.prepare(_puzzle, size, palette);
    return Semantics(
      container: true,
      label: _describe(),
      hint: '用手指在棋盘上画线，把球引进杯子，再点放球',
      // 外面垫一个手指一落下就赢下手势竞争的识别器：iOS 的页面任意位置右滑返回约 18dp 就认横向拖动，不垫的话横着画线整页会跟着滑走；
      // 画线走原始指针（Listener），不参与手势竞争。
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        gestures: {EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(EagerGestureRecognizer.new, (_) {})},
        child: Listener(
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: _up,
          child: Stack(fit: StackFit.expand, children: [
            RepaintBoundary(child: CustomPaint(painter: _StagePainter(scene, _art.lines(_strokes, scene)))),
            RepaintBoundary(child: CustomPaint(painter: _MotionPainter(
              scene: scene,
              drawing: _drawing,
              balls: _balls,
              ink: _inkLeft / 100,
              cheer: _cheer,
              repaint: _motion,
            ))),
          ]),
        ),
      ),
    );
  }
}

// 配色全从当前配色推出：棋盘是卡片底色上一层淡方格（像方格纸），线用正文色（像墨水），障碍从轮廓色推出，杯子用控件激活色，
// 球用提醒色（琥珀）。
class _PourColors {
  factory _PourColors(CampusPalette palette) {
    final dark = palette.isDark, cup = dark ? palette.accentText : palette.accent;
    return _PourColors._(
      paper: palette.surface,
      grid: palette.outlineSubtle.withValues(alpha: dark ? .5 : .7),
      edge: palette.outlineSubtle,
      block: dark ? Color.lerp(palette.outlineSubtle, palette.outline, .7)! : Color.lerp(palette.outline, palette.onSurface, .2)!,
      blockEdge: dark ? Color.lerp(palette.outline, palette.onSurfaceVariant, .4)! : Color.lerp(palette.outline, palette.onSurface, .55)!,
      cup: cup,
      glass: cup.withValues(alpha: dark ? .2 : .14),
      ink: palette.onSurface,
      guide: palette.onSurfaceVariant.withValues(alpha: .45),
      ball: palette.attention,
      ballShade: Color.lerp(palette.attention, palette.onSurface, dark ? .55 : .35)!,
      shine: Colors.white.withValues(alpha: dark ? .55 : .8),
      track: palette.outlineSubtle.withValues(alpha: .8),
      low: palette.attention,
    );
  }

  const _PourColors._({
    required this.paper,
    required this.grid,
    required this.edge,
    required this.block,
    required this.blockEdge,
    required this.cup,
    required this.glass,
    required this.ink,
    required this.guide,
    required this.ball,
    required this.ballShade,
    required this.shine,
    required this.track,
    required this.low,
  });
  final Color paper, grid, edge, block, blockEdge, cup, glass, ink, guide, ball, ballShade, shine, track, low;
}

// 棋盘的静态几何：方格、障碍与杯子都拼成路径，题、尺寸或配色变了才重建。
class _PourScene {
  _PourScene(this.puzzle, Size size, CampusPalette palette) : colors = _PourColors(palette), scale = size.width / pourWidth {
    board = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(16));
    // 方格每 50 单位一条。
    for (var x = 50; x < pourWidth; x += 50) {
      grid
        ..moveTo(x * scale, 0)
        ..lineTo(x * scale, size.height);
    }
    for (var y = 50; y < pourHeight; y += 50) {
      grid
        ..moveTo(0, y * scale)
        ..lineTo(size.width, y * scale);
    }
    for (final block in puzzle.blocks) {
      final shape = Path()..addRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: block.halfWidth * 2 * scale, height: block.halfHeight * 2 * scale), Radius.circular(3 * scale)));
      blocks.addPath(shape.transform((Matrix4.translationValues(block.x * scale, block.y * scale, 0)..rotateZ(block.angle * math.pi / 180)).storage), Offset.zero);
    }
    final cup = puzzle.cup;
    for (final (left, top, right, bottom) in cup.walls) {
      walls.addRRect(RRect.fromLTRBR(left * scale, top * scale, right * scale, bottom * scale, Radius.circular(3 * scale)));
    }
    glass = Rect.fromLTRB(cup.left * scale, cup.top * scale, cup.right * scale, cup.bottom * scale);
  }

  final PourPuzzle puzzle;
  final _PourColors colors;
  final double scale;
  late final RRect board;
  late final Rect glass;
  final grid = Path(), blocks = Path(), walls = Path();

  Offset at(num x, num y) => Offset(x * scale, y * scale);

  // 一串点连成的线（每笔一段折线）。
  Path strokes(Iterable<List<int>> strokes) {
    final path = Path();
    for (final stroke in strokes) {
      path.moveTo(stroke[0] * scale, stroke[1] * scale);
      for (var index = 2; index + 1 < stroke.length; index += 2) {
        path.lineTo(stroke[index] * scale, stroke[index + 1] * scale);
      }
    }
    return path;
  }

  Paint get inkPaint => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = pourLineRadius * 2 * scale
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = colors.ink;
}

// 场景与画好的线的缓存：题、尺寸、配色都没变时给同一份场景；线按笔数与最后一笔认，不变就给同一条路径。
class _PourArt {
  Object? _key, _linesKey;
  _PourScene? _scene;
  Path? _lines;

  _PourScene prepare(PourPuzzle puzzle, Size size, CampusPalette palette) {
    final key = (puzzle, size, palette);
    if (key != _key || _scene == null) {
      _key = key;
      _scene = _PourScene(puzzle, size, palette);
    }
    return _scene!;
  }

  Path lines(List<List<int>> strokes, _PourScene scene) {
    final key = (strokes.length, strokes.lastOrNull, scene);
    if (key != _linesKey || _lines == null) {
      _linesKey = key;
      _lines = scene.strokes(strokes);
    }
    return _lines!;
  }
}

// 静态层：方格纸、障碍、杯子与画好的线。
class _StagePainter extends CustomPainter {
  _StagePainter(this.scene, this.lines);
  final _PourScene scene;
  final Path lines;

  @override
  void paint(Canvas canvas, Size size) {
    final colors = scene.colors;
    canvas.drawRRect(scene.board, Paint()..color = colors.paper);
    canvas.save();
    canvas.clipRRect(scene.board);
    canvas.drawPath(scene.grid, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = colors.grid);
    canvas.drawRect(scene.glass, Paint()..color = colors.glass);
    canvas.drawPath(scene.walls, Paint()..color = colors.cup);
    canvas.drawPath(scene.blocks, Paint()..color = colors.block);
    canvas.drawPath(scene.blocks, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.2..color = colors.blockEdge);
    canvas.drawPath(lines, scene.inkPaint);
    canvas.restore();
    canvas.drawRRect(scene.board.deflate(.5), Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = colors.edge);
  }

  @override
  bool shouldRepaint(_StagePainter oldDelegate) => !identical(oldDelegate.scene, scene) || !identical(oldDelegate.lines, lines);
}

// 动的那一层：墨水条、正在画的这一笔、画线时球四周不能画的范围、球与解开时杯子的光圈。按模拟逐帧重画，球最多三个。
class _MotionPainter extends CustomPainter {
  _MotionPainter({required this.scene, required this.drawing, required this.balls, required this.ink, required this.cheer, required Listenable repaint}) : super(repaint: repaint);
  final _PourScene scene;
  final List<int>? drawing;
  final List<({double x, double y, double angle})> Function() balls;
  final double ink;
  final Animation<double> cheer;

  @override
  void paint(Canvas canvas, Size size) {
    final colors = scene.colors, scale = scene.scale;
    canvas.save();
    canvas.clipRRect(scene.board);
    // 墨水条：棋盘顶上一条细条，剩得少时换提醒色。
    final track = RRect.fromLTRBR(16, 10, size.width - 16, 14, const Radius.circular(2));
    canvas.drawRRect(track, Paint()..color = colors.track);
    if (ink > 0) canvas.drawRRect(RRect.fromLTRBR(track.left, track.top, track.left + track.width * ink, track.bottom, const Radius.circular(2)), Paint()..color = ink < .2 ? colors.low : colors.cup);
    final cheer = this.cheer.value;
    if (cheer > 0) {
      final glow = math.sin(math.pi * cheer);
      canvas.drawRect(scene.glass, Paint()..color = colors.cup.withValues(alpha: .35 * glow));
      final spread = Curves.easeOutCubic.transform(cheer) * 28 * scale;
      canvas.drawRRect(RRect.fromRectAndRadius(scene.glass.inflate(pourCupWall * scale + spread), Radius.circular(8 * scale + spread)), Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = colors.cup.withValues(alpha: .7 * (1 - cheer)));
    }
    final drawing = this.drawing;
    final poses = balls();
    if (drawing != null) {
      // 球的起点四周一圈细线：线画不进去。
      final guides = Path();
      for (var index = 0; index < scene.puzzle.balls.length; index += 2) {
        guides.addOval(Rect.fromCircle(center: scene.at(scene.puzzle.balls[index], scene.puzzle.balls[index + 1]), radius: pourBallClearance * scale));
      }
      canvas.drawPath(guides, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = colors.guide);
      if (drawing.length >= 4) {
        canvas.drawPath(scene.strokes([drawing]), scene.inkPaint);
      } else {
        canvas.drawCircle(scene.at(drawing[0], drawing[1]), pourLineRadius * scale, Paint()..color = colors.ink);
      }
    }
    // 球：琥珀色圆、细描边、跟着转的一个小斑点（看得出在滚）与左上角固定的高光，各拼成一条路径一次画完。
    final radius = pourBallRadius * scale;
    final bodies = Path(), marks = Path(), shines = Path();
    for (final pose in poses) {
      final center = scene.at(pose.x, pose.y);
      bodies.addOval(Rect.fromCircle(center: center, radius: radius));
      marks.addOval(Rect.fromCircle(center: center + Offset(math.cos(pose.angle), math.sin(pose.angle)) * radius * .52, radius: radius * .18));
      shines.addOval(Rect.fromCircle(center: center + Offset(-radius * .34, -radius * .36), radius: radius * .22));
    }
    canvas.drawPath(bodies, Paint()..color = colors.ball);
    canvas.drawPath(marks, Paint()..color = colors.ballShade);
    canvas.drawPath(shines, Paint()..color = colors.shine);
    canvas.drawPath(bodies, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.2..color = colors.ballShade);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MotionPainter oldDelegate) => true;
}
