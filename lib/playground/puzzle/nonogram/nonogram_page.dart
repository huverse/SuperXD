import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/nonogram/nonogram_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';

enum _Mark { none, filled, crossed }

// 数织对局页：单指在格子上点或拖，按下方选的「涂色 / 标叉」改一串格子（拖动锁定在起点那一行或那一列，同常见的数织游戏）；
// 起点已经是这种标记时这一笔改成擦掉。双指缩放与平移（格子太小点不准时放大），提示数字始终是 14 号字、跟着格子对齐。
// 这一行（列）涂的段和提示一致时提示变淡；全部对上即解开，叉号淡出、涂色格过渡成激活色的图案。
class NonogramPage extends StatefulWidget {
  const NonogramPage({super.key, required this.game, required this.store, this.seeds});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;

  @override
  State<NonogramPage> createState() => _NonogramPageState();
}

class _NonogramPageState extends State<NonogramPage> with SingleTickerProviderStateMixin {
  late final _session = PlaySession<NonogramPuzzle, List<bool>>(game: widget.game, rules: const NonogramRules(), store: widget.store, seeds: widget.seeds);
  late var _marks = _blank();
  var _mode = _Mark.filled;
  // 每一笔改了哪些格、改之前是什么，撤销按笔退回。
  final _history = <List<(int, _Mark)>>[];
  List<(int, _Mark)>? _stroke;
  int? _strokeStart;
  _Mark? _strokeTarget;
  bool? _strokeHorizontal;
  // 缩放与平移：_pan 是格子区相对未平移位置的偏移（≤ 0）。
  double _zoom = 1;
  Offset _pan = Offset.zero;
  final _pointers = <int, Offset>{};
  bool _pinching = false;
  double _pinchDistance = 1, _pinchZoom = 1;
  Offset _pinchFocal = Offset.zero, _pinchPan = Offset.zero;
  // 手指按着的那一格：所在行列加浅色底，方便对提示。
  int? _focus;
  late final _reveal = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  _NonogramLayout? _layout;
  final _clues = _CluePainters();

  @override
  void dispose() {
    _reveal.dispose();
    _clues.dispose();
    _session.dispose();
    super.dispose();
  }

  NonogramPuzzle get _puzzle => _session.puzzle;
  List<_Mark> _blank() => List.filled(_session.puzzle.width * _session.puzzle.height, _Mark.none);

  void _reset() {
    _marks = _blank();
    _history.clear();
    _stroke = null;
    _zoom = 1;
    _pan = Offset.zero;
    _focus = null;
    _reveal.value = 0;
  }

  void _newGame(PuzzleTier? tier) => setState(() {
    _session.next(tier: tier);
    _reset();
  });

  void _restart() => setState(() {
    _session.restart();
    _reset();
  });

  // ---------- 涂格 ----------

  void _begin(int cell) {
    final target = _marks[cell] == _mode ? _Mark.none : _mode;
    _stroke = [];
    _strokeStart = cell;
    _strokeTarget = target;
    _strokeHorizontal = null;
    _apply(cell, first: true);
  }

  // 起点之后只改「还空着的格」（擦掉时只擦同种标记），免得拖过去把别的标记一起改掉。
  void _apply(int cell, {bool first = false}) {
    final stroke = _stroke, target = _strokeTarget;
    if (stroke == null || target == null || stroke.any((entry) => entry.$1 == cell)) return;
    final current = _marks[cell];
    final change = first ? current != target : target == _Mark.none ? current == _mode : current == _Mark.none;
    if (!change) return;
    stroke.add((cell, current));
    _marks[cell] = target;
    _session.moved();
    playTick();
  }

  void _extend(int cell) {
    final start = _strokeStart;
    if (start == null) return;
    final width = _puzzle.width;
    final (startRow, startColumn) = (start ~/ width, start % width);
    final (row, column) = (cell ~/ width, cell % width);
    if (row == startRow && column == startColumn) return;
    final horizontal = _strokeHorizontal ??= (column - startColumn).abs() >= (row - startRow).abs();
    final (from, to) = horizontal ? (startColumn, column) : (startRow, row);
    for (var step = math.min(from, to); step <= math.max(from, to); step++) {
      _apply(horizontal ? startRow * width + step : step * width + startColumn);
    }
  }

  void _end() {
    final stroke = _stroke;
    _stroke = _strokeStart = _strokeTarget = null;
    if (stroke == null || stroke.isEmpty) return;
    _history.add(stroke);
    if (const NonogramRules().solved(_puzzle, [for (final mark in _marks) mark == _Mark.filled])) unawaited(_finish());
  }

  // 第二根手指落下：这一笔作废（退回改过的格），改成缩放。
  void _cancelStroke() {
    final stroke = _stroke;
    if (stroke != null) {
      for (final (cell, previous) in stroke.reversed) {
        _marks[cell] = previous;
      }
    }
    _stroke = _strokeStart = _strokeTarget = null;
  }

  void _undo() {
    if (_history.isEmpty || _session.finished) return;
    playTick();
    setState(() {
      for (final (cell, previous) in _history.removeLast().reversed) {
        _marks[cell] = previous;
      }
    });
  }

  Future<void> _finish() async {
    _focus = null;
    final newBest = await _session.finish();
    if (!mounted) return;
    setState(() {
      _zoom = 1;
      _pan = Offset.zero;
    });
    await _reveal.animateTo(1, duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : null);
    if (!mounted) return;
    final choice = await showPlayResult(context, session: _session, newBest: newBest, detail: '${_puzzle.width}×${_puzzle.height}');
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

  // ---------- 手势：单指涂，双指缩放平移 ----------

  void _down(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    final layout = _layout;
    if (layout == null || _session.finished) return;
    if (_pointers.length == 2) {
      setState(_cancelStroke);
      if (layout.maxZoom <= 1) return;
      _pinching = true;
      final points = _pointers.values.toList();
      _pinchDistance = math.max(1, (points[0] - points[1]).distance);
      _pinchFocal = (points[0] + points[1]) / 2;
      _pinchZoom = _zoom;
      _pinchPan = _pan;
      return;
    }
    if (_pointers.length > 1 || _pinching) return;
    final cell = layout.cellAt(event.localPosition, clamp: false);
    if (cell == null) return;
    setState(() {
      _focus = cell;
      _begin(cell);
    });
  }

  void _move(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    final layout = _layout;
    if (layout == null) return;
    if (_pinching && _pointers.length >= 2) {
      final points = _pointers.values.take(2).toList();
      final zoom = (_pinchZoom * (points[0] - points[1]).distance / _pinchDistance).clamp(1.0, layout.maxZoom);
      final focal = (points[0] + points[1]) / 2;
      // 缩放前手指中点下的那一点，缩放后仍在手指中点下。
      final anchor = (_pinchFocal - layout.gridOrigin - _pinchPan) / _pinchZoom;
      setState(() {
        _zoom = zoom;
        _pan = layout.clampPan(focal - layout.gridOrigin - anchor * zoom, zoom);
      });
      return;
    }
    if (_stroke == null) return;
    final cell = layout.cellAt(event.localPosition, clamp: true)!;
    setState(() {
      _focus = cell;
      _extend(cell);
    });
  }

  void _up(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.isEmpty) _pinching = false;
    if (_stroke != null) setState(_end);
    if (_pointers.isEmpty && _focus != null) setState(() => _focus = null);
  }

  // ---------- 画面 ----------

  @override
  Widget build(BuildContext context) => PlayFrame(
    session: _session,
    onNewGame: _newGame,
    onRestart: _restart,
    status: '${_puzzle.width}×${_puzzle.height}',
    controls: [
      SizedBox(width: 200, child: CampusSegmented<_Mark>(
        values: const [_Mark.filled, _Mark.crossed],
        label: (mark) => mark == _Mark.filled ? '涂色' : '标叉',
        selected: _mode,
        onSelected: _session.finished ? null : (mark) => setState(() => _mode = mark),
      )),
      FilledButton.icon(onPressed: _history.isEmpty || _session.finished ? null : _undo, icon: const CampusIcon(CampusIcons.undo), label: const Text('撤销')),
    ],
    board: LayoutBuilder(builder: (context, constraints) {
      final palette = CampusPalette.of(context);
      final style = DefaultTextStyle.of(context).style.merge(TextStyle(fontSize: 14, height: 18 / 14, fontWeight: FontWeight.w500, color: palette.onSurface, fontFeatures: const [FontFeature.tabularFigures()]));
      _clues.prepare(_puzzle, style, MediaQuery.textScalerOf(context), palette);
      final layout = _layout = _NonogramLayout.fit(_puzzle, _clues, Size(constraints.maxWidth, constraints.maxHeight), zoom: _zoom, pan: _pan);
      final satisfied = _satisfiedLines();
      return Center(child: SizedBox.fromSize(size: layout.size, child: Listener(
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: Stack(children: [
          Positioned.fill(child: AnimatedBuilder(animation: _reveal, builder: (context, _) => CustomPaint(painter: _NonogramPainter(
            puzzle: _puzzle, marks: _marks, layout: layout, clues: _clues, palette: palette, focus: _focus, satisfied: satisfied, reveal: _reveal.value,
          )))),
          if (MediaQuery.of(context).accessibleNavigation) ..._cellSemantics(layout),
        ]),
      )));
    }),
  );

  ({List<bool> rows, List<bool> columns}) _satisfiedLines() {
    final puzzle = _puzzle;
    bool same(List<int> left, List<int> right) => left.length == right.length && Iterable<int>.generate(left.length).every((index) => left[index] == right[index]);
    final filled = [for (final mark in _marks) mark == _Mark.filled];
    final current = nonogramClues(filled, puzzle.width, puzzle.height);
    return (
      rows: [for (var row = 0; row < puzzle.height; row++) same(current.rows[row], puzzle.rows[row])],
      columns: [for (var column = 0; column < puzzle.width; column++) same(current.columns[column], puzzle.columns[column])],
    );
  }

  // 读屏：每格一个按钮（只在读屏导航时建），点按按当前模式改这一格。
  List<Widget> _cellSemantics(_NonogramLayout layout) => [
    for (var row = 0; row < _puzzle.height; row++)
      for (var column = 0; column < _puzzle.width; column++)
        if (layout.cellRect(row, column) case final rect when layout.gridViewport.overlaps(rect))
          Positioned.fromRect(rect: rect, child: Semantics(
            button: true,
            label: '第${row + 1}行第${column + 1}列，${switch (_marks[row * _puzzle.width + column]) { _Mark.filled => '已涂', _Mark.crossed => '已标叉', _Mark.none => '空' }}',
            hint: '提示：行 ${_puzzle.rows[row].join(' ')}，列 ${_puzzle.columns[column].join(' ')}',
            onTap: _session.finished ? null : () => setState(() {
              _begin(row * _puzzle.width + column);
              _end();
            }),
            child: const SizedBox.expand(),
          )),
  ];
}

// 提示数字的排版缓存：每行一串「3 1 2」、每列一竖排，各备正常与已满足（淡）两种颜色；题、字体、字号或配色变了才重排。
class _CluePainters {
  Object? _key;
  final rows = <(TextPainter, TextPainter)>[];
  final columns = <(TextPainter, TextPainter)>[];
  double rowWidth = 0, columnHeight = 0, lineHeight = 18;

  void dispose() {
    for (final (normal, faded) in [...rows, ...columns]) {
      normal.dispose();
      faded.dispose();
    }
    rows.clear();
    columns.clear();
  }

  void prepare(NonogramPuzzle puzzle, TextStyle style, TextScaler scaler, CampusPalette palette) {
    final key = (puzzle, style, scaler, palette.onSurface, palette.onSurfaceVariant);
    if (key == _key) return;
    _key = key;
    dispose();
    (TextPainter, TextPainter) pair(String text, TextAlign align) {
      TextPainter make(Color color) => TextPainter(text: TextSpan(text: text, style: style.copyWith(color: color)), textAlign: align, textDirection: TextDirection.ltr, textScaler: scaler)..layout();
      return (make(palette.onSurface), make(palette.onSurfaceVariant.withValues(alpha: .45)));
    }

    for (final runs in puzzle.rows) {
      rows.add(pair(runs.join(' '), TextAlign.right));
    }
    for (final runs in puzzle.columns) {
      columns.add(pair(runs.join('\n'), TextAlign.center));
    }
    lineHeight = rows.isEmpty ? 18 : rows.first.$1.height;
    rowWidth = rows.fold(0.0, (widest, pair) => math.max(widest, pair.$1.width)) + 10;
    columnHeight = columns.fold(0.0, (tallest, pair) => math.max(tallest, pair.$1.height)) + 8;
  }
}

// 棋盘几何：左边是行提示栏、上面是列提示栏，右下是格子区；缩放时格子区按 zoom 放大、按 pan 平移并裁在格子区里，提示栏跟着对齐。
class _NonogramLayout {
  _NonogramLayout._({required this.puzzle, required this.clueWidth, required this.clueHeight, required this.cell, required this.zoom, required this.pan});

  // 格子最大 48：小题不铺得过分大；放大最多到 44 一格（手指点得准的大小）。
  factory _NonogramLayout.fit(NonogramPuzzle puzzle, _CluePainters clues, Size area, {required double zoom, required Offset pan}) {
    final cell = math.max(8.0, math.min(48.0, math.min((area.width - clues.rowWidth) / puzzle.width, (area.height - clues.columnHeight) / puzzle.height)));
    return _NonogramLayout._(puzzle: puzzle, clueWidth: clues.rowWidth, clueHeight: clues.columnHeight, cell: cell, zoom: zoom, pan: pan);
  }

  final NonogramPuzzle puzzle;
  final double clueWidth, clueHeight, cell, zoom;
  final Offset pan;

  Size get size => Size(clueWidth + cell * puzzle.width, clueHeight + cell * puzzle.height);
  Offset get gridOrigin => Offset(clueWidth, clueHeight);
  Rect get gridViewport => gridOrigin & Size(cell * puzzle.width, cell * puzzle.height);
  double get maxZoom => math.max(1, 44 / cell);
  double get step => cell * zoom;

  Offset clampPan(Offset value, double zoom) {
    final spare = Offset(cell * puzzle.width * (1 - zoom), cell * puzzle.height * (1 - zoom));
    return Offset(value.dx.clamp(spare.dx, 0), value.dy.clamp(spare.dy, 0));
  }

  Rect cellRect(int row, int column) => Rect.fromLTWH(clueWidth + pan.dx + column * step, clueHeight + pan.dy + row * step, step, step);

  // 落点所在的格；clamp 为真时把格子区外的点归到最近的边格（拖出边界时这一笔仍跟着）。
  int? cellAt(Offset point, {required bool clamp}) {
    if (!clamp && !gridViewport.contains(point)) return null;
    final local = point - gridOrigin - pan;
    final column = (local.dx / step).floor().clamp(0, puzzle.width - 1), row = (local.dy / step).floor().clamp(0, puzzle.height - 1);
    return row * puzzle.width + column;
  }
}

class _NonogramPainter extends CustomPainter {
  _NonogramPainter({required this.puzzle, required this.marks, required this.layout, required this.clues, required this.palette, required this.focus, required this.satisfied, required this.reveal});
  final NonogramPuzzle puzzle;
  final List<_Mark> marks;
  final _NonogramLayout layout;
  final _CluePainters clues;
  final CampusPalette palette;
  final int? focus;
  final ({List<bool> rows, List<bool> columns}) satisfied;
  // 解开后的过渡进度 0–1：叉号与格线淡出，涂色格从墨色过渡到激活色。
  final double reveal;

  @override
  void paint(Canvas canvas, Size size) {
    final viewport = layout.gridViewport, step = layout.step, width = puzzle.width, height = puzzle.height;
    final origin = layout.gridOrigin + layout.pan;
    // 格子区底板：同卡片底色，圆角 12。
    canvas.drawRRect(RRect.fromRectAndRadius(viewport.inflate(1), const Radius.circular(12)), Paint()..color = palette.surface);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(viewport.inflate(1), const Radius.circular(12)));
    final focus = this.focus;
    if (focus != null && reveal == 0) {
      final band = Paint()..color = palette.surfaceSelected.withValues(alpha: .7);
      canvas.drawRect(Rect.fromLTWH(viewport.left, origin.dy + focus ~/ width * step, viewport.width, step), band);
      canvas.drawRect(Rect.fromLTWH(origin.dx + focus % width * step, viewport.top, step, viewport.height), band);
    }
    final ink = Color.lerp(palette.onSurface.withValues(alpha: .88), palette.accent, reveal)!;
    final fill = Paint()..color = ink;
    final cross = Paint()
      ..color = palette.onSurfaceVariant.withValues(alpha: .8 * (1 - reveal))
      ..strokeWidth = math.max(1.2, step * .07)
      ..strokeCap = StrokeCap.round;
    final inset = math.max(1.0, step * .06) * (1 - reveal);
    final crosses = Path();
    for (var row = 0; row < height; row++) {
      for (var column = 0; column < width; column++) {
        final rect = Rect.fromLTWH(origin.dx + column * step, origin.dy + row * step, step, step);
        if (!rect.overlaps(viewport)) continue;
        switch (marks[row * width + column]) {
          case _Mark.filled:
            canvas.drawRRect(RRect.fromRectAndRadius(rect.deflate(inset), Radius.circular(step * .12 * (1 - reveal))), fill);
          case _Mark.crossed when reveal < 1:
            final mark = rect.deflate(step * .3);
            crosses
              ..moveTo(mark.left, mark.top)
              ..lineTo(mark.right, mark.bottom)
              ..moveTo(mark.right, mark.top)
              ..lineTo(mark.left, mark.bottom);
          default:
        }
      }
    }
    canvas.drawPath(crosses, cross..style = PaintingStyle.stroke);
    // 格线：每格细线、每五格粗线，一条路径一次画完。
    final thin = Path(), thick = Path();
    for (var column = 1; column < width; column++) {
      final x = origin.dx + column * step;
      (column % 5 == 0 ? thick : thin)
        ..moveTo(x, origin.dy)
        ..lineTo(x, origin.dy + height * step);
    }
    for (var row = 1; row < height; row++) {
      final y = origin.dy + row * step;
      (row % 5 == 0 ? thick : thin)
        ..moveTo(origin.dx, y)
        ..lineTo(origin.dx + width * step, y);
    }
    final lineFade = 1 - reveal;
    canvas.drawPath(thin, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = palette.outlineSubtle.withValues(alpha: lineFade));
    canvas.drawPath(thick, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.6..color = palette.outline.withValues(alpha: .7 * lineFade));
    canvas.restore();
    canvas.drawRRect(RRect.fromRectAndRadius(viewport.inflate(1), const Radius.circular(12)), Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = palette.outlineSubtle);

    // 行提示：右对齐贴着格子区，垂直对齐每行中线；列提示：竖排贴着格子区上沿，水平对齐每列中线。
    // 提示栏隔一行（列）铺一层很淡的底色（同常见数织 App 的斑马纹）：大题与大字号下相邻两列的两位数不会读成一串。
    final band = Paint()..color = palette.surfaceSelected.withValues(alpha: palette.isDark ? .8 : .95);
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, viewport.top, viewport.left, viewport.height));
    for (var row = 1; row < height; row += 2) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(2, origin.dy + row * step, viewport.left - 4, step), const Radius.circular(6)), band);
    }
    for (var row = 0; row < height; row++) {
      final (normal, faded) = clues.rows[row];
      final painter = satisfied.rows[row] ? faded : normal;
      final center = origin.dy + (row + .5) * step;
      if (center < viewport.top - step || center > viewport.bottom + step) continue;
      painter.paint(canvas, Offset(viewport.left - 6 - painter.width, center - painter.height / 2));
    }
    canvas.restore();
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(viewport.left, 0, viewport.width, viewport.top));
    for (var column = 1; column < width; column += 2) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(origin.dx + column * step, 2, step, viewport.top - 4), const Radius.circular(6)), band);
    }
    for (var column = 0; column < width; column++) {
      final (normal, faded) = clues.columns[column];
      final painter = satisfied.columns[column] ? faded : normal;
      final center = origin.dx + (column + .5) * step;
      if (center < viewport.left - step || center > viewport.right + step) continue;
      // 两位数比一格宽时只横向压窄到格宽（字高不变），不压到隔壁那一列。
      final room = step - 3;
      canvas.save();
      canvas.translate(center, viewport.top - 4 - painter.height);
      if (painter.width > room) canvas.scale(room / painter.width, 1);
      painter.paint(canvas, Offset(-painter.width / 2, 0));
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_NonogramPainter old) => true;
}
