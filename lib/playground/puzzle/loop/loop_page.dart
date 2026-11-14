import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'package:superxd/playground/challenge/play_challenge.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/loop/loop_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_transitions.dart';

enum _Mark { none, line, cross }

// 棋盘四周留的空白（按格算）：外圈的点、线与叉不贴着棋盘边。
const _margin = .35;
// 落指离点不到这么远（按格算）先不定是哪条边：拖到隔壁的点才画这一段，原地松手再按最近的边算（落在点上时四条边一样近，猜哪条都可能猜错）。
const _startRadius = .3;
// 拖动时离点不到这么远（按格算）才算走到这个点：点与点之间留一段空档，手指在两点中间晃动不会来回跳。
const _trackRadius = .38;
// 一格四条边的读法，按上、右、下、左排（同 LoopGrid.cellEdges）。
const _sideNames = ['上边', '右边', '下边', '左边'];

// 数回对局页：点一条边按下方选的「画线 / 标叉」改它（再点取消）；按住沿着点阵拖动连着画，拖过的边都画上，起点那条已是这种标记时这一笔是擦掉。
// 落点归最近的那条边：每格按两条对角线分成四块，各归一条边，格与格之间、棋盘四周的空白也归最近的边，没有按不到的缝。
// 画线会让一个点连出三条线（分叉或交叉）就不画，轻震并提示。格子周围线数超过数字时数字标警示色，正好时变淡。
// 回路连成一条且数字都对上即解开：线条过渡成激活色、围起来的格淡淡铺一层，再弹结果。格子小于 48 时双指放大。
class LoopPage extends StatefulWidget {
  const LoopPage({super.key, required this.game, required this.store, this.seeds, this.challenge});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;
  // 挑战里的一关（题面是服务器给的）；自由模式为空。
  final PlayChallenge? challenge;

  @override
  State<LoopPage> createState() => _LoopPageState();
}

class _LoopPageState extends State<LoopPage> with TickerProviderStateMixin {
  static const _rules = LoopRules();
  late final _session = PlaySession<LoopPuzzle, List<bool>>(game: widget.game, rules: _rules, store: widget.store, seeds: widget.seeds, challenge: widget.challenge);
  late var _marks = _blank();
  var _mode = _Mark.line;
  // 每一笔改了哪些边、改之前是什么，撤销按笔退回。
  final _history = <List<(int, _Mark)>>[];
  // 正在画的这一笔：改过的边、这一笔画成什么（起点那条决定）、落指时按到的边、手指走到的点、落在点上还没定边时的落点。
  List<(int, _Mark)>? _stroke;
  _Mark? _target;
  int? _firstEdge;
  int? _at;
  Offset? _tapAt;
  // 上一次处理到的手指位置：拖得快时沿途补点。
  Offset _last = Offset.zero;
  // 这一笔已经被拦过（只震一次、只提示一次）；之前的提示还没收起（这一笔第一次改成功时收起，免得过时的提示停在屏幕上）。
  bool _refused = false;
  bool _staleToast = false;
  // 缩放与平移：_pan 是棋盘内容相对未平移位置的偏移（≤ 0）。
  double _zoom = 1;
  Offset _pan = Offset.zero;
  final _pointers = <int, Offset>{};
  bool _pinching = false;
  double _pinchDistance = 1, _pinchZoom = 1;
  Offset _pinchFocal = Offset.zero, _pinchPan = Offset.zero;
  // 解开后的收尾过渡；被拦下时那个点闪一圈警示色。
  late final _reveal = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  late final _flash = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  int? _flashVertex;
  _LoopLayout? _layout;
  final _digits = _DigitPainters();

  @override
  void dispose() {
    _reveal.dispose();
    _flash.dispose();
    _digits.dispose();
    _session.dispose();
    super.dispose();
  }

  LoopPuzzle get _puzzle => _session.puzzle;
  LoopGrid get _grid => LoopGrid.of(_puzzle.width, _puzzle.height);
  bool get _still => MediaQuery.disableAnimationsOf(context);
  List<_Mark> _blank() => List.filled(LoopGrid.of(_session.puzzle.width, _session.puzzle.height).edgeCount, _Mark.none);
  List<bool> get _lines => [for (final mark in _marks) mark == _Mark.line];

  void _reset() {
    _marks = _blank();
    _history.clear();
    _stroke = _target = _firstEdge = _at = _tapAt = _flashVertex = null;
    _zoom = 1;
    _pan = Offset.zero;
    _reveal.value = 0;
    _flash.value = 0;
  }

  void _newGame(PuzzleTier? tier) {
    hideCampusToast();
    setState(() {
      _session.next(tier: tier);
      _reset();
    });
  }

  void _restart() {
    hideCampusToast();
    setState(() {
      _session.restart();
      _reset();
    });
  }

  // ---------- 画线 ----------

  void _begin() {
    _stroke = [];
    _target = _firstEdge = _at = _tapAt = null;
    _refused = false;
    _staleToast = true;
  }

  // 这一笔改一条边：起点那条决定这一笔是画成当前标记还是擦掉；之后画只改空着的边、擦只擦同种标记，免得拖过去把别的标记一起改掉。
  void _apply(int edge) {
    final stroke = _stroke;
    if (stroke == null || stroke.any((entry) => entry.$1 == edge)) return;
    final current = _marks[edge];
    final first = _target == null;
    final target = _target ??= current == _mode ? _Mark.none : _mode;
    final change = first ? current != target : target == _Mark.none ? current == _mode : current == _Mark.none;
    if (!change) return;
    if (target == _Mark.line) {
      final crowded = _crowded(edge);
      if (crowded != null) return _refuse(crowded);
    }
    stroke.add((edge, current));
    _marks[edge] = target;
    _session.moved();
    playTick();
    if (_staleToast) {
      _staleToast = false;
      hideCampusToast();
    }
  }

  // 这条边两头哪个点已经连了两条线（再画就分叉或交叉）；都没有是 null。
  int? _crowded(int edge) {
    final grid = _grid;
    for (final vertex in [grid.edgeEnds[edge * 2], grid.edgeEnds[edge * 2 + 1]]) {
      var lines = 0;
      for (var side = 0; side < 4; side++) {
        final other = grid.vertexEdges[vertex * 4 + side];
        if (other >= 0 && _marks[other] == _Mark.line) lines++;
      }
      if (lines >= 2) return vertex;
    }
    return null;
  }

  void _refuse(int vertex) {
    if (_refused) return;
    _refused = true;
    _staleToast = false;
    playRejected();
    showCampusToast(context, '线不能分叉，也不能交叉');
    _flashVertex = vertex;
    if (!_still) unawaited(_flash.forward(from: 0));
  }

  // 手指走到了一个点：从上一个点沿着点阵走过来（不相邻时朝它一格一格补，哪边差得多先走哪边），走过的边都改。
  void _reach(int vertex) {
    final grid = _grid, stride = _puzzle.width + 1;
    int distance(int from, int to) => (from ~/ stride - to ~/ stride).abs() + (from % stride - to % stride).abs();
    var from = _at;
    if (from == null) {
      // 落指在一条边上（那条已经改了）：从它离这个点近的那一头接着走。
      final edge = _firstEdge!;
      final (one, other) = (grid.edgeEnds[edge * 2], grid.edgeEnds[edge * 2 + 1]);
      from = distance(one, vertex) <= distance(other, vertex) ? one : other;
    }
    _tapAt = null;
    while (from != vertex) {
      final current = from!;
      final rowGap = vertex ~/ stride - current ~/ stride, columnGap = vertex % stride - current % stride;
      final next = columnGap.abs() >= rowGap.abs() ? current + columnGap.sign : current + rowGap.sign * stride;
      _apply(grid.edgeBetween(current, next));
      from = next;
    }
    _at = vertex;
  }

  // 收笔：落在点上没拖开的，这时才按落点最近的边改一条。这一笔改过东西就记进撤销，返回是否改过。
  bool _end() {
    final tap = _tapAt, layout = _layout;
    if (_stroke != null && _target == null && tap != null && layout != null) _apply(layout.edgeAt(_grid, tap));
    final stroke = _stroke;
    _stroke = _target = _firstEdge = _at = _tapAt = null;
    if (stroke == null || stroke.isEmpty) return false;
    _history.add(stroke);
    return true;
  }

  // 第二根手指落下：这一笔作废（退回改过的边），改成缩放。
  void _cancelStroke() {
    final stroke = _stroke;
    if (stroke != null) {
      for (final (edge, previous) in stroke.reversed) {
        _marks[edge] = previous;
      }
    }
    _stroke = _target = _firstEdge = _at = _tapAt = null;
  }

  // 一笔收完：解开就收尾；数字都对上了却还没解开，说一下差在哪（还有线头没接上，或分成了几个圈）。
  void _judge() {
    final lines = _lines;
    if (_rules.solved(_puzzle, lines)) {
      unawaited(_finish());
      return;
    }
    if (!lines.contains(true)) return;
    final counts = loopCounts(lines, _grid);
    for (var cell = 0; cell < counts.length; cell++) {
      if (_puzzle.clues[cell] >= 0 && _puzzle.clues[cell] != counts[cell]) return;
    }
    final grid = _grid;
    var open = false;
    for (var vertex = 0; vertex < grid.vertexCount && !open; vertex++) {
      var degree = 0;
      for (var side = 0; side < 4; side++) {
        final edge = grid.vertexEdges[vertex * 4 + side];
        if (edge >= 0 && lines[edge]) degree++;
      }
      open = degree == 1;
    }
    showCampusToast(context, open ? '数字都对上了，还有线头没接上' : '数字都对上了，但线分成了几个圈');
  }

  void _undo() {
    if (_history.isEmpty || _session.finished) return;
    playTick();
    hideCampusToast();
    setState(() {
      for (final (edge, previous) in _history.removeLast().reversed) {
        _marks[edge] = previous;
      }
    });
  }

  // 读屏：按格子上的操作改一条边（同手指点这条边）。
  void _toggleBySemantics(int edge) {
    if (_session.finished) return;
    var committed = false;
    setState(() {
      _begin();
      _apply(edge);
      committed = _end();
    });
    if (committed) _judge();
  }

  Future<void> _finish() async {
    hideCampusToast();
    final newBest = await _session.finish(answer: _lines);
    if (!mounted) return;
    setState(() {
      _pointers.clear();
      _pinching = false;
      _zoom = 1;
      _pan = Offset.zero;
    });
    await _reveal.animateTo(1, duration: _still ? Duration.zero : null);
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

  // ---------- 手势：单指画，双指缩放平移 ----------

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
    final point = event.localPosition;
    setState(() {
      _begin();
      _last = point;
      final vertex = layout.vertexNear(point, _startRadius);
      if (vertex != null) {
        _at = vertex;
        _tapAt = point;
      } else {
        final edge = layout.edgeAt(_grid, point);
        _firstEdge = edge;
        _apply(edge);
      }
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
      final anchor = (_pinchFocal - _pinchPan) / _pinchZoom;
      setState(() {
        _zoom = zoom;
        _pan = layout.clampPan(focal - anchor * zoom, zoom);
      });
      return;
    }
    if (_stroke == null) return;
    final from = _last, to = event.localPosition;
    _last = to;
    // 沿途每隔四分之一格看一次，手指划得快也不跳过中间的点。
    final samples = math.max(1, ((to - from).distance / (layout.step * .25)).ceil());
    setState(() {
      for (var index = 1; index <= samples; index++) {
        final vertex = layout.vertexNear(Offset.lerp(from, to, index / samples)!, _trackRadius);
        if (vertex != null && vertex != _at) _reach(vertex);
      }
    });
  }

  void _up(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.isEmpty) _pinching = false;
    if (_stroke == null) return;
    // 系统取消（来电、手势被抢）时，落在点上还没定的那一下不算点按。
    if (event is PointerCancelEvent) _tapAt = null;
    var committed = false;
    setState(() {
      committed = _end();
    });
    if (committed) _judge();
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
        values: const [_Mark.line, _Mark.cross],
        label: (mark) => mark == _Mark.line ? '画线' : '标叉',
        selected: _mode,
        onSelected: _session.finished ? null : (mark) => setState(() => _mode = mark),
      )),
      FilledButton.icon(onPressed: _history.isEmpty || _session.finished ? null : _undo, icon: const CampusIcon(CampusIcons.undo), label: const Text('撤销')),
    ],
    board: PlayBoardBox(aspectRatio: (_puzzle.width + _margin * 2) / (_puzzle.height + _margin * 2), builder: (context, size) {
      final palette = CampusPalette.of(context);
      final layout = _layout = _LoopLayout(width: _puzzle.width, height: _puzzle.height, size: size, zoom: _zoom, pan: _pan);
      // 数字 14 号起：格子大时放大一点（按没放大时的格算，放大时数字不跟着变），再跟系统字号缩放。
      final fontSize = (layout.cell * .42).clamp(14.0, 22.0);
      final style = DefaultTextStyle.of(context).style.merge(TextStyle(fontSize: fontSize, height: 1.2, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]));
      _digits.prepare(style, MediaQuery.textScalerOf(context), palette);
      final counts = loopCounts(_lines, _grid);
      // 外面垫一个手指一落下就赢下手势竞争的识别器：iOS 的页面任意位置右滑返回约 18dp 就认横向拖动，不垫的话横着画一段整页会跟着滑走；
      // 画线与缩放走原始指针（Listener），不参与手势竞争，不受影响。
      return RawGestureDetector(
        gestures: {EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(EagerGestureRecognizer.new, (_) {})},
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: _up,
          child: Stack(children: [
            Positioned.fill(child: AnimatedBuilder(animation: Listenable.merge([_reveal, _flash]), builder: (context, _) => CustomPaint(painter: _LoopPainter(
              puzzle: _puzzle,
              grid: _grid,
              marks: _marks,
              counts: counts,
              layout: layout,
              digits: _digits,
              palette: palette,
              reveal: Curves.easeInOut.transform(_reveal.value),
              flashVertex: _flash.isAnimating ? _flashVertex : null,
              flash: _flash.value,
            )))),
            if (MediaQuery.of(context).accessibleNavigation) ..._cellSemantics(layout, counts),
          ]),
        ),
      );
    }),
  );

  // 读屏：每格一个节点（只在读屏导航时建），读出位置、数字、已画的线与叉；四条边各一个操作（按当前模式画上或擦掉）。
  // 按格而不按边：格只有边的一半多，数字与线数本来就是按格看的，摸到哪一格就读哪一格，四条边在这一格的操作里挑。
  List<Widget> _cellSemantics(_LoopLayout layout, List<int> counts) {
    final grid = _grid, width = _puzzle.width;
    return [
      for (var row = 0; row < _puzzle.height; row++)
        for (var column = 0; column < width; column++)
          if (layout.cellRect(row, column) case final rect when layout.viewport.overlaps(rect))
            Positioned.fromRect(rect: rect, child: Semantics(
              label: _cellLabel(row * width + column, counts),
              customSemanticsActions: _session.finished ? null : {
                for (var side = 0; side < 4; side++)
                  CustomSemanticsAction(label: _actionLabel(side, _marks[grid.cellEdges[(row * width + column) * 4 + side]])): () => _toggleBySemantics(grid.cellEdges[(row * width + column) * 4 + side]),
              },
              child: const SizedBox.expand(),
            )),
    ];
  }

  String _cellLabel(int cell, List<int> counts) {
    final width = _puzzle.width, clue = _puzzle.clues[cell];
    String sides(_Mark mark) => [for (var side = 0; side < 4; side++) if (_marks[_grid.cellEdges[cell * 4 + side]] == mark) _sideNames[side]].join('、');
    final lines = sides(_Mark.line), crosses = sides(_Mark.cross);
    return [
      '第${cell ~/ width + 1}行第${cell % width + 1}列',
      if (clue < 0) '没有数字' else '数字$clue',
      if (lines.isEmpty) '没有线' else '${counts[cell]}条线：$lines',
      // 同画面上数字标警示色：线比数字多。
      if (clue >= 0 && counts[cell] > clue) '多了${counts[cell] - clue}条',
      if (crosses.isNotEmpty) '叉：$crosses',
    ].join('，');
  }

  String _actionLabel(int side, _Mark mark) => switch ((_mode, mark)) {
    (_Mark.line, _Mark.line) => '擦掉${_sideNames[side]}的线',
    (_Mark.line, _) => '${_sideNames[side]}画线',
    (_, _Mark.cross) => '擦掉${_sideNames[side]}的叉',
    _ => '${_sideNames[side]}标叉',
  };
}

// 数字的排版缓存：0 到 3 各备正常、正好（淡）、超出（警示色）三种；字号、系统字号或配色变了才重排。
class _DigitPainters {
  Object? _key;
  final normal = <TextPainter>[];
  final done = <TextPainter>[];
  final over = <TextPainter>[];

  void dispose() {
    for (final painter in [...normal, ...done, ...over]) {
      painter.dispose();
    }
    normal.clear();
    done.clear();
    over.clear();
  }

  void prepare(TextStyle style, TextScaler scaler, CampusPalette palette) {
    final key = (style, scaler, palette.onSurface, palette.onSurfaceVariant, palette.danger);
    if (key == _key) return;
    _key = key;
    dispose();
    TextPainter make(int digit, Color color) => TextPainter(text: TextSpan(text: '$digit', style: style.copyWith(color: color)), textDirection: TextDirection.ltr, textScaler: scaler)..layout();
    for (var digit = 0; digit <= 3; digit++) {
      normal.add(make(digit, palette.onSurface));
      done.add(make(digit, palette.onSurfaceVariant.withValues(alpha: .45)));
      over.add(make(digit, palette.danger));
    }
  }
}

// 棋盘几何：四周留 _margin 格的空白，点阵按 zoom 放大、按 pan 平移（pan ≤ 0），裁在棋盘里。
class _LoopLayout {
  const _LoopLayout({required this.width, required this.height, required this.size, required this.zoom, required this.pan});
  final int width, height;
  final Size size;
  final double zoom;
  final Offset pan;

  double get cell => size.width / (width + _margin * 2);
  double get step => cell * zoom;
  // 一格不到 48 时可以放大到 48 一格（触区不小于 48）；本来就够大的不给放大。
  double get maxZoom => math.max(1, 48 / cell);
  Rect get viewport => Offset.zero & size;

  // 点阵坐标（按格算，左上角的点是 0, 0）与棋盘上的位置互换。
  Offset toGrid(Offset point) => (point - pan) / step - const Offset(_margin, _margin);
  Offset at(double column, double row) => pan + Offset((column + _margin) * step, (row + _margin) * step);
  Offset vertex(int index) => at((index % (width + 1)).toDouble(), (index ~/ (width + 1)).toDouble());
  Rect cellRect(int row, int column) => Rect.fromPoints(at(column.toDouble(), row.toDouble()), at(column + 1.0, row + 1.0));

  // 落点最近的边：先把落点夹进点阵，再在所在那一格里比它到四条边的距离（格按对角线分成四块各归一条边，棋盘四周的空白归最近的外圈边）。
  int edgeAt(LoopGrid grid, Offset point) {
    final local = toGrid(point);
    final x = local.dx.clamp(0.0, width.toDouble()), y = local.dy.clamp(0.0, height.toDouble());
    final column = math.min(x.floor(), width - 1), row = math.min(y.floor(), height - 1);
    final across = x - column, down = y - row;
    final nearest = [down, 1 - across, 1 - down, across].indexed.reduce((best, item) => item.$2 < best.$2 ? item : best).$1;
    return grid.cellEdges[(row * width + column) * 4 + nearest];
  }

  // 离落点不到 radius 格的点；没有是 null。
  int? vertexNear(Offset point, double radius) {
    final local = toGrid(point);
    final column = local.dx.round().clamp(0, width), row = local.dy.round().clamp(0, height);
    return (local - Offset(column.toDouble(), row.toDouble())).distance < radius ? row * (width + 1) + column : null;
  }

  Offset clampPan(Offset value, double zoom) => Offset(value.dx.clamp(size.width * (1 - zoom), 0), value.dy.clamp(size.height * (1 - zoom), 0));
}

class _LoopPainter extends CustomPainter {
  _LoopPainter({
    required this.puzzle,
    required this.grid,
    required this.marks,
    required this.counts,
    required this.layout,
    required this.digits,
    required this.palette,
    required this.reveal,
    required this.flashVertex,
    required this.flash,
  });
  final LoopPuzzle puzzle;
  final LoopGrid grid;
  final List<_Mark> marks;
  final List<int> counts;
  final _LoopLayout layout;
  final _DigitPainters digits;
  final CampusPalette palette;
  // reveal：解开后的过渡 0–1（线条从墨色过渡到激活色、叉淡出、圈里的格铺上淡激活色）；flash：被拦下那个点的警示圈进度。
  final double reveal, flash;
  final int? flashVertex;

  @override
  void paint(Canvas canvas, Size size) {
    final step = layout.step, width = puzzle.width, height = puzzle.height;
    final board = RRect.fromRectAndRadius(layout.viewport, const Radius.circular(16));
    canvas.drawRRect(board, Paint()..color = palette.surface);
    canvas.save();
    canvas.clipRRect(board);

    // 圈里的格：每行从左往右数竖线，单数条之后的格在圈里，拼成一条路径铺淡激活色。
    if (reveal > 0) {
      final inside = Path();
      for (var row = 0; row < height; row++) {
        var within = false;
        for (var column = 0; column < width; column++) {
          if (marks[grid.vertical(row, column)] == _Mark.line) within = !within;
          if (within) inside.addRect(layout.cellRect(row, column));
        }
      }
      canvas.drawPath(inside, Paint()..color = palette.accent.withValues(alpha: (palette.isDark ? .24 : .14) * reveal));
    }

    // 点阵的点、叉与线各拼成一条路径一次画完；点垫在线下面，线的圆头正好盖住拐角。
    final dots = Path(), crosses = Path(), lines = Path();
    final radius = math.max(2.0, step * .05), half = math.max(3.0, step * .09);
    for (var vertex = 0; vertex < grid.vertexCount; vertex++) {
      dots.addOval(Rect.fromCircle(center: layout.vertex(vertex), radius: radius));
    }
    for (var edge = 0; edge < grid.edgeCount; edge++) {
      final mark = marks[edge];
      if (mark == _Mark.none) continue;
      final from = layout.vertex(grid.edgeEnds[edge * 2]), to = layout.vertex(grid.edgeEnds[edge * 2 + 1]);
      if (mark == _Mark.line) {
        lines
          ..moveTo(from.dx, from.dy)
          ..lineTo(to.dx, to.dy);
      } else {
        final center = (from + to) / 2;
        crosses
          ..moveTo(center.dx - half, center.dy - half)
          ..lineTo(center.dx + half, center.dy + half)
          ..moveTo(center.dx + half, center.dy - half)
          ..lineTo(center.dx - half, center.dy + half);
      }
    }
    canvas.drawPath(dots, Paint()..color = palette.onSurfaceVariant.withValues(alpha: .75));
    if (reveal < 1) {
      canvas.drawPath(crosses, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, step * .04)
        ..strokeCap = StrokeCap.round
        ..color = palette.onSurfaceVariant.withValues(alpha: .8 * (1 - reveal)));
    }
    canvas.drawPath(lines, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(3.0, step * .1)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = Color.lerp(palette.onSurface.withValues(alpha: .9), palette.accent, reveal)!);

    // 数字：周围线数超过数字标警示色，正好时变淡（0 一开局就「正好」，不淡，免得一眼看过去像没有）。
    for (var cell = 0; cell < grid.cellCount; cell++) {
      final clue = puzzle.clues[cell];
      if (clue < 0) continue;
      final painter = counts[cell] > clue ? digits.over[clue] : counts[cell] == clue && clue > 0 ? digits.done[clue] : digits.normal[clue];
      final center = layout.cellRect(cell ~/ width, cell % width).center;
      painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
    }

    final flashing = flashVertex;
    if (flashing != null) {
      canvas.drawCircle(layout.vertex(flashing), step * (.18 + .22 * flash), Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2.0, step * .06)
        ..color = palette.danger.withValues(alpha: 1 - flash));
    }
    canvas.restore();
    canvas.drawRRect(board, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = palette.outlineSubtle);
  }

  @override
  bool shouldRepaint(_LoopPainter old) => true;
}
