import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:superxd/playground/challenge/play_challenge.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/queens/queens_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';

// 解开后的收尾：每个皇后亮一下 360ms，按行依次错开 60ms（12×12 一共约 1 秒）。
const _glowEach = 360, _glowGap = 60;

// 八皇后对局页：点空格放皇后、再点一次拿掉；锁定的皇后点了不动、轻震一下。互相攻击的皇后不拦着放（同大多数 N 皇后应用），
// 只把它们标成警示色、彼此之间连一条淡淡的线，让玩家自己看出哪里错了。最后碰过的那个皇后（按住的、刚放下的）用很淡的底色显示它管到的格。
// 棋盘大、格子不到 48 时双指放大，放大后单指拖动平移。
class QueensPage extends StatefulWidget {
  const QueensPage({super.key, required this.game, required this.store, this.seeds, this.challenge});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;
  // 挑战里的一关（题面是服务器给的）；自由模式为空。
  final PlayChallenge? challenge;

  @override
  State<QueensPage> createState() => _QueensPageState();
}

class _QueensPageState extends State<QueensPage> with TickerProviderStateMixin {
  static const _rules = QueensRules();
  late final _session = PlaySession<QueensPuzzle, List<int>>(game: widget.game, rules: _rules, store: widget.store, seeds: widget.seeds, challenge: widget.challenge);
  // 玩家自己放的皇后（格号 = 行 × N + 列）；锁定的在题面里。同一行可以放两个，冲突只标出来。
  final _placed = <int>{};
  // 每一步放上（true）或拿掉（false）了哪一格，撤销按步退回。
  final _history = <(int, bool)>[];
  // 显示攻击范围的那个皇后：最后按住、点过或刚放下的。
  int? _focus;
  // 手指按着的空格：浅浅压一层底，松手才放。
  int? _pressed;
  // 手势：一根手指点按（移动超过触摸容差就不算点），两根手指缩放；放大后单指拖动平移。
  final _pointers = <int, Offset>{};
  int? _tapCell;
  Offset _tapAt = Offset.zero, _dragPan = Offset.zero;
  Duration _tapTime = Duration.zero;
  bool _pinching = false;
  double _pinchDistance = 1, _pinchZoom = 1;
  Offset _pinchFocal = Offset.zero, _pinchPan = Offset.zero;
  double _zoom = 1;
  Offset _pan = Offset.zero;
  _QueensLayout? _layout;
  // 放上与拿掉的那一个皇后：缩放加淡入淡出；攻击范围换人时淡入；点锁定的皇后左右晃一下；解开后皇后按行依次轻轻亮一下。
  late final _pop = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  int? _popCell;
  bool _popIn = true;
  late final _range = AnimationController(vsync: this, duration: const Duration(milliseconds: 160), value: 1);
  late final _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 360));
  int? _shakeCell;
  late final _glow = AnimationController(vsync: this);

  @override
  void dispose() {
    _pop.dispose();
    _range.dispose();
    _shake.dispose();
    _glow.dispose();
    _session.dispose();
    super.dispose();
  }

  QueensPuzzle get _puzzle => _session.puzzle;
  int get _size => _puzzle.size;
  bool get _still => MediaQuery.disableAnimationsOf(context);

  Set<int> get _locked => {for (var row = 0; row < _size; row++) if (_puzzle.given[row] >= 0) row * _size + _puzzle.given[row]};
  List<int> get _queens => [..._locked, ..._placed]..sort();
  // 答案：每行皇后所在的列（没放是 -1）。
  List<int> get _rows {
    final rows = List.filled(_size, -1);
    for (final cell in _queens) {
      rows[cell ~/ _size] = cell % _size;
    }
    return rows;
  }

  // 每行恰好一个时编成答案交规则判定，否则还没解开。
  bool get _solved {
    final queens = _queens;
    if (queens.length != _size) return false;
    final answer = List.filled(_size, -1);
    for (final cell in queens) {
      if (answer[cell ~/ _size] >= 0) return false;
      answer[cell ~/ _size] = cell % _size;
    }
    return _rules.solved(_puzzle, answer);
  }

  void _reset() {
    _placed.clear();
    _history.clear();
    _focus = _pressed = _tapCell = _popCell = _shakeCell = null;
    _zoom = 1;
    _pan = Offset.zero;
    _pop.value = 1;
    _range.value = 1;
    _glow.value = 0;
  }

  void _newGame(PuzzleTier? tier) => setState(() {
    _session.next(tier: tier);
    _reset();
  });

  void _restart() => setState(() {
    _session.restart();
    _reset();
  });

  // ---------- 落子 ----------

  void _focusOn(int? cell) {
    if (cell == _focus) return;
    _focus = cell;
    if (cell != null) _animate(_range);
  }

  // 从头播一遍；减少动画时直接到位。
  void _animate(AnimationController controller) {
    if (_still) {
      controller.value = 1;
    } else {
      unawaited(controller.forward(from: 0));
    }
  }

  void _popAt(int cell, {required bool placing}) {
    _popCell = cell;
    _popIn = placing;
    _animate(_pop);
  }

  void _toggle(int cell) {
    if (_session.finished) return;
    if (_locked.contains(cell)) {
      playRejected();
      setState(() {
        _focusOn(cell);
        _shakeCell = cell;
      });
      if (!_still) unawaited(_shake.forward(from: 0));
      return;
    }
    final placing = !_placed.contains(cell);
    playTick();
    _session.moved();
    setState(() {
      if (placing) {
        _placed.add(cell);
      } else {
        _placed.remove(cell);
      }
      _history.add((cell, placing));
      _focusOn(placing ? cell : null);
      _popAt(cell, placing: placing);
    });
    if (_solved) unawaited(_finish());
  }

  void _undo() {
    if (_history.isEmpty || _session.finished) return;
    playTick();
    setState(() {
      final (cell, placed) = _history.removeLast();
      if (placed) {
        _placed.remove(cell);
      } else {
        _placed.add(cell);
      }
      _focusOn(placed ? null : cell);
      _popAt(cell, placing: !placed);
    });
    // 撤销「拿掉」也可能正好补齐。
    if (_solved) unawaited(_finish());
  }

  Future<void> _finish() async {
    final newBest = await _session.finish(answer: _rows);
    if (!mounted) return;
    setState(() {
      _focus = _pressed = _tapCell = null;
      _pointers.clear();
      _pinching = false;
      _zoom = 1;
      _pan = Offset.zero;
    });
    // 等刚放下的那个落定，再按行依次亮一下。
    final still = _still;
    if (!still) await _pop.forward();
    if (!mounted) return;
    await _glow.animateTo(1, duration: still ? Duration.zero : Duration(milliseconds: _glowEach + (_size - 1) * _glowGap));
    if (!mounted) return;
    final choice = await showPlayResult(context, session: _session, newBest: newBest, detail: '$_size×$_size');
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

  // ---------- 手势 ----------

  void _down(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    final layout = _layout;
    if (layout == null || _session.finished) return;
    if (_pointers.length == 2) {
      // 第二根手指落下：这一下不算点按，改成缩放。
      _tapCell = null;
      if (_pressed != null) setState(() => _pressed = null);
      if (layout.maxZoom <= 1) return;
      _pinching = true;
      final points = _pointers.values.toList();
      _pinchDistance = math.max(1, (points[0] - points[1]).distance);
      _pinchFocal = (points[0] + points[1]) / 2;
      _pinchZoom = _zoom;
      _pinchPan = _pan;
      return;
    }
    if (_pointers.length > 1) return;
    final cell = layout.cellAt(event.localPosition);
    _tapCell = cell;
    _tapAt = event.localPosition;
    _tapTime = event.timeStamp;
    _dragPan = _pan;
    if (cell == null) return;
    setState(() {
      if (_queens.contains(cell)) {
        _focusOn(cell);
      } else {
        _pressed = cell;
      }
    });
  }

  void _move(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    final layout = _layout;
    if (layout == null || _session.finished) return;
    if (_pinching && _pointers.length >= 2) {
      final points = _pointers.values.take(2).toList();
      final zoom = (_pinchZoom * (points[0] - points[1]).distance / _pinchDistance).clamp(1.0, layout.maxZoom);
      final focal = (points[0] + points[1]) / 2;
      // 缩放前手指中点下的那一点，缩放后仍在手指中点下。
      final anchor = (_pinchFocal - _pinchPan) / _pinchZoom;
      setState(() {
        _zoom = zoom;
        _pan = layout.clampPan(focal - anchor * zoom, zoom);
      });
      return;
    }
    if (_pointers.length != 1) return;
    final moved = event.localPosition - _tapAt;
    if (_tapCell != null && moved.distance > kTouchSlop) {
      _tapCell = null;
      if (_pressed != null) setState(() => _pressed = null);
    }
    if (_tapCell == null && _zoom > 1) setState(() => _pan = layout.clampPan(_dragPan + moved, _zoom));
  }

  void _up(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length == 1) {
      // 缩放的两根手指抬起一根：剩下那根接着平移，不再当点按。
      _pinching = false;
      _tapCell = null;
      _tapAt = _pointers.values.single;
      _dragPan = _pan;
      return;
    }
    if (_pointers.isNotEmpty) return;
    final cell = _tapCell;
    _pinching = false;
    _tapCell = null;
    if (_pressed != null) setState(() => _pressed = null);
    if (cell == null || event is PointerCancelEvent || _session.finished) return;
    // 按住一个皇后超过长按时长是在看它的攻击范围：松手不拿掉（空格照常放）。
    if (event.timeStamp - _tapTime >= kLongPressTimeout && _queens.contains(cell)) return;
    _toggle(cell);
  }

  // ---------- 画面 ----------

  @override
  Widget build(BuildContext context) => PlayFrame(
    session: _session,
    onNewGame: _newGame,
    onRestart: _restart,
    status: '已放 ${_queens.length}/$_size',
    controls: [
      FilledButton.icon(onPressed: _history.isEmpty || _session.finished ? null : _undo, icon: const CampusIcon(CampusIcons.undo), label: const Text('撤销')),
    ],
    board: PlayBoardBox(aspectRatio: 1, builder: (context, size) {
      final palette = CampusPalette.of(context);
      final layout = _layout = _QueensLayout(size: _size, side: size.width, zoom: _zoom, pan: _pan);
      final queens = _queens;
      final conflicts = _conflicts(queens);
      return RawGestureDetector(
        // 放大后单指拖动要平移：先把这次触摸认领下来，免得 iOS 页面任意位置右滑返回抢走横向拖动（不放大时照常能右滑返回）。
        gestures: {
          if (_zoom > 1) EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(EagerGestureRecognizer.new, (_) {}),
        },
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: _up,
          child: Stack(children: [
            Positioned.fill(child: AnimatedBuilder(
              animation: Listenable.merge([_pop, _range, _shake, _glow]),
              builder: (context, _) => CustomPaint(painter: _QueensPainter(
                layout: layout,
                locked: _locked,
                placed: _placed,
                conflicts: conflicts.cells,
                pairs: conflicts.pairs,
                palette: palette,
                focus: _focus,
                range: Curves.easeOut.transform(_range.value),
                pressed: _pressed,
                popCell: _pop.isAnimating ? _popCell : null,
                popIn: _popIn,
                pop: Curves.easeOutCubic.transform(_pop.value),
                shakeCell: _shake.isAnimating ? _shakeCell : null,
                shake: _shake.value,
                glow: _glow.value * (_glowEach + (_size - 1) * _glowGap),
              )),
            )),
            ..._cellSemantics(layout, conflicts.cells),
          ]),
        ),
      );
    }),
  );

  // 互相攻击的皇后两两成对：连线画在每一对之间，参与冲突的格标警示色。
  ({Set<int> cells, List<(int, int)> pairs}) _conflicts(List<int> queens) {
    final cells = <int>{}, pairs = <(int, int)>[];
    for (var index = 0; index < queens.length; index++) {
      for (var other = index + 1; other < queens.length; other++) {
        final (first, second) = (queens[index], queens[other]);
        if (!queensAttack(first ~/ _size, first % _size, second ~/ _size, second % _size)) continue;
        pairs.add((first, second));
        cells.addAll([first, second]);
      }
    }
    return (cells: cells, pairs: pairs);
  }

  // 读屏：每格一个按钮，读出第几行第几列、有没有皇后、是否锁定与冲突，点按同手指点这一格。
  List<Widget> _cellSemantics(_QueensLayout layout, Set<int> conflicts) {
    final locked = _locked;
    return [
      for (var row = 0; row < _size; row++)
        for (var column = 0; column < _size; column++)
          if (layout.cellRect(row, column) case final rect when layout.viewport.overlaps(rect))
            Positioned.fromRect(rect: rect, child: Semantics(
              button: true,
              label: '第${row + 1}行第${column + 1}列，${_cellState(row * _size + column, locked, conflicts)}',
              onTap: _session.finished ? null : () => _toggle(row * _size + column),
              child: const SizedBox.expand(),
            )),
    ];
  }

  String _cellState(int cell, Set<int> locked, Set<int> conflicts) {
    final queen = locked.contains(cell) ? '锁定的皇后' : _placed.contains(cell) ? '皇后' : null;
    if (queen == null) return '空';
    return conflicts.contains(cell) ? '$queen，冲突' : queen;
  }
}

// 棋盘几何：正方形棋盘 side 见方，放大时格子按 zoom 放大、按 pan 平移（pan ≤ 0），裁在棋盘里。
class _QueensLayout {
  const _QueensLayout({required this.size, required this.side, required this.zoom, required this.pan});
  final int size;
  final double side, zoom;
  final Offset pan;

  double get cell => side / size;
  double get step => cell * zoom;
  // 一格不到 48 时可以放大到 48 一格（触区不小于 48）；本来就够大的不给放大。
  double get maxZoom => math.max(1, 48 / cell);
  Rect get viewport => Offset.zero & Size.square(side);

  Rect cellRect(int row, int column) => Rect.fromLTWH(pan.dx + column * step, pan.dy + row * step, step, step);
  Offset center(int cell) => cellRect(cell ~/ size, cell % size).center;

  int? cellAt(Offset point) {
    if (!viewport.contains(point)) return null;
    final local = point - pan;
    final row = (local.dy / step).floor().clamp(0, size - 1), column = (local.dx / step).floor().clamp(0, size - 1);
    return row * size + column;
  }

  Offset clampPan(Offset value, double zoom) {
    final spare = side * (1 - zoom);
    return Offset(value.dx.clamp(spare, 0), value.dy.clamp(spare, 0));
  }
}

class _QueensPainter extends CustomPainter {
  _QueensPainter({
    required this.layout,
    required this.locked,
    required this.placed,
    required this.conflicts,
    required this.pairs,
    required this.palette,
    required this.focus,
    required this.range,
    required this.pressed,
    required this.popCell,
    required this.popIn,
    required this.pop,
    required this.shakeCell,
    required this.shake,
    required this.glow,
  });
  final _QueensLayout layout;
  final Set<int> locked, placed, conflicts;
  final List<(int, int)> pairs;
  final CampusPalette palette;
  final int? focus, pressed, popCell, shakeCell;
  // range：攻击范围淡入进度；pop：放上（拿掉）那一个的进度；shake：晃动进度；glow：收尾动画走过的毫秒数。
  final double range, pop, shake, glow;
  final bool popIn;

  int get size => layout.size;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final viewport = layout.viewport, step = layout.step;
    final board = RRect.fromRectAndRadius(viewport, const Radius.circular(16));
    final dark = palette.isDark;
    canvas.save();
    canvas.clipRRect(board);
    // 棋盘：浅格同卡片底，深格向选中色压一点点，两种底色都很克制，皇后才是画面的主角。
    canvas.drawRect(viewport, Paint()..color = palette.surface);
    final squares = Path();
    for (var row = 0; row < size; row++) {
      for (var column = (row + 1) % 2; column < size; column += 2) {
        squares.addRect(layout.cellRect(row, column));
      }
    }
    canvas.drawPath(squares, Paint()..color = Color.lerp(palette.surface, palette.surfaceSelected, dark ? .5 : .45)!);

    // 攻击范围：同行、同列与两条斜线上的格（连同皇后自己那格，免得中间露出一个洞）铺一层很淡的激活色。用不透明的同一种颜色
    // 盖住深浅格（半透明叠上去，浅格染过之后和没染的深格分不清，范围就读不出来了），淡入时按透明度从棋盘过渡过去。
    final focus = this.focus;
    if (focus != null && glow == 0 && (locked.contains(focus) || placed.contains(focus))) {
      final (focusRow, focusColumn) = (focus ~/ size, focus % size);
      final reach = Path();
      for (var row = 0; row < size; row++) {
        for (var column = 0; column < size; column++) {
          if (queensAttack(row, column, focusRow, focusColumn)) reach.addRect(layout.cellRect(row, column));
        }
      }
      canvas.drawPath(reach, Paint()..color = Color.lerp(palette.surface, palette.accent, dark ? .28 : .16)!.withValues(alpha: range));
    }
    // 按着的空格。
    final pressed = this.pressed;
    if (pressed != null) {
      canvas.drawRRect(_plate(pressed), Paint()..color = palette.onSurface.withValues(alpha: dark ? .1 : .07));
    }
    // 锁定皇后的格垫一块圆角底板（同印在棋盘上的题面），和自己放的一眼分开。
    final plates = Path(), conflictPlates = Path();
    for (final cell in locked) {
      (conflicts.contains(cell) ? conflictPlates : plates).addRRect(_plate(cell));
    }
    canvas.drawPath(plates, Paint()..color = Color.lerp(palette.surfaceSelected, palette.outline, dark ? .18 : .22)!.withValues(alpha: dark ? .9 : .75));
    // 冲突：参与冲突的格染一层淡警示色，每一对之间连一条线（一条路径画完，重叠的线段不叠深）。
    final tinted = Path();
    for (final cell in conflicts) {
      if (!locked.contains(cell)) tinted.addRRect(_plate(cell));
    }
    final warning = palette.danger;
    canvas.drawPath(tinted, Paint()..color = warning.withValues(alpha: dark ? .16 : .1));
    canvas.drawPath(conflictPlates, Paint()..color = warning.withValues(alpha: dark ? .3 : .2));
    if (pairs.isNotEmpty) {
      final lines = Path();
      for (final (first, second) in pairs) {
        final (from, to) = (layout.center(first), layout.center(second));
        lines
          ..moveTo(from.dx, from.dy)
          ..lineTo(to.dx, to.dy);
      }
      canvas.drawPath(lines, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2, step * .06)
        ..strokeCap = StrokeCap.round
        ..color = warning.withValues(alpha: dark ? .55 : .45));
    }

    // 皇后：自己放的是激活色圆棋子、白色王冠，冲突时换成警示红；锁定的是墨色王冠直接印在底板上（不是棋子），冲突时王冠变警示色。
    final piece = _pieceColor(palette), rejectFill = palette.dangerFill;
    final pieces = Path(), rejected = Path(), crowns = Path(), inked = Path(), inkedRejected = Path();
    final halos = <(Offset, double, double)>[];
    final order = [...locked, ...placed]..sort();
    for (final (index, cell) in order.indexed) {
      if (cell == popCell) continue;
      var center = layout.center(cell);
      if (cell == shakeCell) center = center.translate(math.sin(shake * math.pi * 5) * step * .1 * (1 - shake), 0);
      // 收尾：按行依次放大一点再回来，外圈漾开一道淡光。
      final progress = ((glow - index * _glowGap) / _glowEach).clamp(0.0, 1.0);
      final scale = 1 + .12 * math.sin(progress * math.pi);
      if (progress > 0 && progress < 1) halos.add((center, step * .38 * (1 + .55 * progress), 1 - progress));
      if (locked.contains(cell)) {
        _crown(conflicts.contains(cell) ? inkedRejected : inked, center, step * .64 * scale);
      } else {
        (conflicts.contains(cell) ? rejected : pieces).addOval(Rect.fromCircle(center: center, radius: step * .36 * scale));
        _crown(crowns, center, step * .47 * scale);
      }
    }
    // 棋子浮在棋盘上一层很浅的投影：浅色取正文墨色、深色取最深的背景色，都是往暗处落。
    final shadow = (dark ? palette.backgroundTop : palette.onSurface).withValues(alpha: dark ? .6 : .3);
    final rim = palette.onSurface.withValues(alpha: dark ? .14 : .16);
    final discs = Path()
      ..addPath(pieces, Offset.zero)
      ..addPath(rejected, Offset.zero);
    canvas.drawShadow(discs, shadow, 1.5, true);
    canvas.drawPath(pieces, Paint()..color = piece);
    canvas.drawPath(rejected, Paint()..color = rejectFill);
    // 棋子描一圈细边：浅色棋盘上压深一点、深色棋盘上提亮一点，轮廓都清楚。
    canvas.drawPath(discs, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = rim);
    canvas.drawPath(crowns, Paint()..color = Colors.white);
    canvas.drawPath(inked, Paint()..color = _inkColor(palette));
    canvas.drawPath(inkedRejected, Paint()..color = palette.danger);
    for (final (center, radius, fade) in halos) {
      canvas.drawCircle(center, radius, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, step * .05)
        ..color = palette.accent.withValues(alpha: .5 * fade));
    }

    // 正在放上（或拿掉）的那一个：从小放大淡入（拿掉时反过来）。
    final moving = popCell;
    if (moving != null) {
      final progress = popIn ? pop : 1 - pop;
      final center = layout.center(moving);
      final scale = .6 + .4 * progress;
      final conflicted = popIn && conflicts.contains(moving);
      final disc = Path()..addOval(Rect.fromCircle(center: center, radius: step * .36 * scale));
      if (progress > .5) canvas.drawShadow(disc, shadow.withValues(alpha: shadow.a * (progress - .5) * 2), 1.5, true);
      canvas.drawPath(disc, Paint()..color = (conflicted ? rejectFill : piece).withValues(alpha: progress));
      canvas.drawPath(disc, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = rim.withValues(alpha: rim.a * progress));
      canvas.drawPath(_crown(Path(), center, step * .47 * scale), Paint()..color = Colors.white.withValues(alpha: progress));
    }
    canvas.restore();
    canvas.drawRRect(board, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = palette.outlineSubtle);
  }

  RRect _plate(int cell) {
    final rect = layout.cellRect(cell ~/ size, cell % size).deflate(layout.step * .06);
    return RRect.fromRectAndRadius(rect, Radius.circular(layout.step * .2));
  }

  // 王冠剪影：三个尖（中间最高，尖上各一颗小圆珠），下接一条冠带；按中心与宽度画进 path，一个颜色的王冠拼成一条路径一次画完。
  static Path _crown(Path path, Offset center, double width) {
    final height = width * .86;
    final left = center.dx - width / 2, top = center.dy - height / 2;
    Offset at(double x, double y) => Offset(left + x * width, top + y * height);
    path.addPolygon([at(.18, .78), at(.06, .3), at(.33, .52), at(.5, .2), at(.67, .52), at(.94, .3), at(.82, .78)], true);
    path.addRRect(RRect.fromRectAndRadius(Rect.fromPoints(at(.18, .84), at(.82, .96)), Radius.circular(width * .04)));
    for (final (x, y, radius) in [(.06, .25, .075), (.5, .13, .085), (.94, .25, .075)]) {
      path.addOval(Rect.fromCircle(center: at(x, y), radius: width * radius));
    }
    return path;
  }

  // 棋子底色：浅色就是激活色；深色的激活色压在深棋盘上发闷，向正文色提亮一点（白色王冠仍看得清）。
  static Color _pieceColor(CampusPalette palette) => palette.isDark ? Color.lerp(palette.accent, palette.onSurface, .14)! : palette.accent;

  // 锁定皇后的墨色：取文字主色（浅色深、深色亮），和激活色棋子分得开。
  static Color _inkColor(CampusPalette palette) => palette.primary;

  @override
  bool shouldRepaint(_QueensPainter old) => true;
}
