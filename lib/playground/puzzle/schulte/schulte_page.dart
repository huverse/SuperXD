import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/schulte/schulte_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_typesetting.dart';

// 舒尔特方格对局页：开局数字盖着，棋盘中间是「开始」，点了才揭开并开始计时；数字格排在一张卡片上，整张卡按格均分作热区（缝与卡边归最近一格），落点按按下的那一格算、抬手才算点了一下；
// 每根手指各算各的（两只手轮流点不丢），按下后滑出触摸容差就作废，留给页面的右滑返回。按下的格微微缩小、往字色偏一点。
// 点对的格 200ms 变淡缩小，点错轻震、那一格左右晃一下并描一圈警示色，记一次错、不往下走；点过的格再点不算错。
// 全部点完从中心向外依次亮一下（点过的格短暂恢复原色、微微放大），再弹结果。减少动画时直接到位、不晃不亮。
class SchultePage extends StatefulWidget {
  const SchultePage({super.key, required this.game, required this.store, this.seeds});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;

  @override
  State<SchultePage> createState() => _SchultePageState();
}

class _SchultePageState extends State<SchultePage> with TickerProviderStateMixin {
  late final _session = PlaySession<SchultePuzzle, List<int>>(game: widget.game, rules: const SchulteRules(), store: widget.store, seeds: widget.seeds);
  // [人工决策-2026-11-13 17:14:54] 用户选定（三项都选推荐）：开局先盖住数字、点「开始」才揭开并计时（不能先记位置）；用时写到 0.1 秒（只有舒尔特，框架加标记）；点错不罚时、只记次数。
  // 点了「开始」没有：之前格子全是空白的浅底格（红黑表也不露颜色），点格不算，读屏只有「开始」；换题、从头来回到盖着。
  var _started = false;
  // 点对了几下（下一下该点第 _step 个数）与一共点错几下。
  var _step = 0;
  var _misses = 0;
  // 每格是第几下该点的：小于 _step 的格已经点过。
  late var _stepOf = _steps();
  // 按着的手指各落在哪一格、从哪里按下。
  final _downs = <int, ({int cell, Offset at})>{};
  int? _pressed;
  late final _press = AnimationController(vsync: this, duration: const Duration(milliseconds: 150));
  // 点错的那一格：晃一下、警示色描边随之淡出（减少动画时描边留到下一次点对）。
  int? _shaken;
  late final _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 320), value: 1);
  // 收尾：先等最后一格淡完，再按到中心的距离依次亮一下，最外一圈晚 _waveSpread 开始，每格亮 _pulse。
  late final _wave = AnimationController(vsync: this, duration: _fade + _waveSpread + _pulse);
  late final _motion = Listenable.merge([_press, _shake, _wave]);

  static const _fade = Duration(milliseconds: 200);
  static const _waveSpread = Duration(milliseconds: 360);
  static const _pulse = Duration(milliseconds: 320);
  // 一格最大的边长：3×3 在宽屏上不铺得过分大。
  static const _maxPitch = 92.0;

  @override
  void dispose() {
    _press.dispose();
    _shake.dispose();
    _wave.dispose();
    _session.dispose();
    super.dispose();
  }

  SchultePuzzle get _puzzle => _session.puzzle;
  bool get _reduced => MediaQuery.disableAnimationsOf(context);

  List<int> _steps() {
    final steps = List.filled(_puzzle.count, 0);
    for (final (step, cell) in schulteSolution(_puzzle).indexed) {
      steps[cell] = step;
    }
    return steps;
  }

  // 一个数怎么叫：红黑表带颜色。
  String _name(SchulteMark mark) => _puzzle.variant == SchulteVariant.redBlack ? '${mark.red ? '红' : '黑'} ${mark.number}' : '${mark.number}';

  void _reset() {
    _started = false;
    _step = 0;
    _misses = 0;
    _stepOf = _steps();
    _downs.clear();
    _pressed = null;
    _press.value = 0;
    _shaken = null;
    _wave.value = 0;
  }

  void _newGame(PuzzleTier? tier) => setState(() {
    _session.next(tier: tier);
    _reset();
  });

  void _restart() => setState(() {
    _session.restart();
    _reset();
  });

  // 揭开数字、开始计时（PlaySession 从第一步起计时，这一下就是第一步）。
  void _start() {
    if (_started || _session.finished) return;
    playTick();
    _session.moved();
    setState(() => _started = true);
  }

  void _pointerDown(PointerDownEvent event, _SchulteLayout layout) {
    if (!_started || _session.finished) return;
    final cell = layout.cellAt(event.localPosition);
    _downs[event.pointer] = (cell: cell, at: event.localPosition);
    _pressed = cell;
    _press.value = 1;
  }

  void _pointerMove(PointerMoveEvent event) {
    final down = _downs[event.pointer];
    if (down != null && (event.localPosition - down.at).distance > kTouchSlop) _lift(event.pointer);
  }

  // 抬起或作废一根手指；还有别的手指按着时，按下的样子留给它那一格。
  int? _lift(int pointer) {
    final cell = _downs.remove(pointer)?.cell;
    if (_downs.isNotEmpty) {
      _pressed = _downs.values.last.cell;
    } else if (_reduced) {
      _press.value = 0;
    } else {
      unawaited(_press.reverse());
    }
    return cell;
  }

  void _tap(int cell) {
    if (_session.finished || _stepOf[cell] < _step) return;
    if (_stepOf[cell] != _step) {
      playRejected();
      setState(() {
        _misses++;
        _shaken = cell;
      });
      if (!_reduced) unawaited(_shake.forward(from: 0));
      return;
    }
    playTick();
    setState(() {
      _step++;
      _shaken = null;
    });
    if (_step == _puzzle.count) unawaited(_finish());
  }

  Future<void> _finish() async {
    final newBest = await _session.finish(moves: _step + _misses);
    if (!mounted) return;
    if (!_reduced) await _wave.forward(from: 0);
    if (!mounted) return;
    // 用时已是大字（写到 0.1 秒），这里只写点错次数。
    final choice = await showPlayResult(context, session: _session, newBest: newBest, detail: _misses == 0 ? '没有点错' : '点错 $_misses 次');
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

  // 收尾时每格这一刻亮起的幅度 0–1：按到中心的距离错开，每格是一段正弦起落。
  List<double> _pulses(int side) {
    final count = side * side;
    if (_wave.value == 0 || _wave.value == 1) return List.filled(count, 0);
    final elapsed = _wave.value * _wave.duration!.inMicroseconds - _fade.inMicroseconds;
    final middle = (side - 1) / 2, farthest = math.max(1e-6, middle * math.sqrt2);
    return [
      for (var cell = 0; cell < count; cell++)
        () {
          final distance = math.sqrt(math.pow(cell ~/ side - middle, 2) + math.pow(cell % side - middle, 2));
          final local = (elapsed - distance / farthest * _waveSpread.inMicroseconds) / _pulse.inMicroseconds;
          return local <= 0 || local >= 1 ? 0.0 : math.sin(local * math.pi);
        }(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final count = _puzzle.count;
    final next = _step < count ? '下一个：${_name(schulteTarget(_puzzle.variant, count, _step))}' : '已点完';
    return PlayFrame(
      session: _session,
      onNewGame: _newGame,
      onRestart: _restart,
      status: '$next · 点错 $_misses 次',
      board: PlayBoardBox(aspectRatio: 1, maxWidth: _maxPitch * (_puzzle.side + 2 * _SchulteLayout.inset), builder: _board),
    );
  }

  Widget _board(BuildContext context, Size size) {
    final palette = CampusPalette.of(context);
    final puzzle = _puzzle;
    final layout = _SchulteLayout(puzzle.side, size.width);
    final tile = layout.pitch * (1 - 2 * _SchulteLayout.gap);
    // 数字 14 号起、跟着字号缩放；最宽的那个数按实际字体量过，占不下格宽的七成时才往下收，收到 14 为止（不用 FittedBox 往小缩）。
    var fontSize = math.min(MediaQuery.textScalerOf(context).scale(math.max(14, layout.pitch * .36)), tile * .6);
    final widest = campusTextWidth(context, '${puzzle.numbers.reduce(math.max)}', style: _SchulteTile.numberStyle(fontSize), textScaler: TextScaler.noScaling);
    if (widest > tile * .7) fontSize *= tile * .7 / widest;
    fontSize = math.max(14, fontSize);
    final colors = _SchulteColors(palette);
    final duration = _reduced ? Duration.zero : _fade;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => _pointerDown(event, layout),
      onPointerMove: _pointerMove,
      onPointerUp: (event) {
        final cell = _lift(event.pointer);
        if (cell != null) _tap(cell);
      },
      onPointerCancel: (event) => _lift(event.pointer),
      child: CampusSurface(padding: EdgeInsets.zero, child: Stack(children: [
        Positioned.fill(child: AnimatedBuilder(
          animation: _motion,
          builder: (context, _) {
            final pulses = _pulses(puzzle.side);
            final shake = _shake.value;
            return Stack(children: [
              for (var cell = 0; cell < puzzle.count; cell++)
                Positioned.fromRect(
                  key: ValueKey((_session.puzzle, cell)),
                  rect: layout.cellRect(cell),
                  child: () {
                    final view = ExcludeSemantics(child: TweenAnimationBuilder<double>(
                      tween: Tween(end: _stepOf[cell] < _step ? 1 : 0),
                      duration: duration,
                      curve: Curves.easeOutCubic,
                      builder: (context, dim, _) => _SchulteTile(
                        // 开始前盖着：空白的浅底格，不露数也不露颜色。
                        text: _started ? '${puzzle.numbers[cell]}' : '',
                        style: !_started || puzzle.variant == SchulteVariant.single ? _TileStyle.plain : puzzle.red[cell] ? _TileStyle.red : _TileStyle.black,
                        colors: colors,
                        size: tile,
                        fontSize: fontSize,
                        dim: dim * (1 - pulses[cell]),
                        scale: (1 - .07 * (_pressed == cell ? _press.value : 0)) * (1 - .08 * dim) * (1 + .08 * pulses[cell]),
                        shift: _shaken == cell ? math.sin(shake * math.pi * 4) * (1 - shake) * layout.pitch * .08 : 0,
                        press: _pressed == cell ? _press.value : 0,
                        alert: _shaken != cell ? 0 : _reduced ? 1 : 1 - shake,
                      ),
                    ));
                    // 读屏：开始以后每格一个按钮，读出数（红黑表带颜色）与是否已点，点按同手指点这一格；开始前不放，读屏直接走到「开始」。
                    return !_started ? view : Semantics(
                      container: true,
                      button: true,
                      label: '${_name(puzzle.mark(cell))}，${_stepOf[cell] < _step ? '已点' : '未点'}',
                      onTap: _session.finished || _stepOf[cell] < _step ? null : () => _tap(cell),
                      child: view,
                    );
                  }(),
                ),
            ]);
          },
        )),
        if (!_started)
          Center(child: FilledButton.icon(style: campusProminent, onPressed: _start, icon: const CampusIcon(CampusIcons.resume), label: const Text('开始'))),
      ])),
    );
  }
}

// 棋盘几何：卡片四周留 inset 个格距的边，里面按格均分；格子比格距四边各窄 gap 个格距，留出缝。
class _SchulteLayout {
  _SchulteLayout(this.side, double extent) : pitch = extent / (side + 2 * inset);

  static const inset = .16;
  static const gap = .06;
  final int side;
  final double pitch;

  double get padding => pitch * inset;
  Rect cellRect(int cell) => Rect.fromLTWH(padding + cell % side * pitch, padding + cell ~/ side * pitch, pitch, pitch);
  int cellAt(Offset point) => ((point.dy - padding) / pitch).floor().clamp(0, side - 1) * side + ((point.dx - padding) / pitch).floor().clamp(0, side - 1);
}

// 格子的三种样子：单色题的浅底格；红黑表的黑色是实心深底配浅字，红色是红色描边配红字（色弱也能靠实心与描边分开）。
enum _TileStyle { plain, black, red }

// 格子配色全从配色推出：深浅两色下黑色都比卡片深（深色下另描一圈细边才看得出轮廓），红色用警示色（深浅两色各自对卡片底可读）。
class _SchulteColors {
  _SchulteColors(this.palette);
  final CampusPalette palette;

  Color fill(_TileStyle style) => switch (style) {
    _TileStyle.plain => palette.isDark ? Color.lerp(palette.surface, palette.surfaceSelected, .9)! : Color.lerp(palette.surface, palette.outlineSubtle, .55)!,
    _TileStyle.black => palette.isDark ? palette.backgroundTop : palette.onSurface,
    _TileStyle.red => palette.danger.withValues(alpha: .08),
  };

  Color ink(_TileStyle style) => switch (style) {
    _TileStyle.plain => palette.onSurface,
    _TileStyle.black => palette.isDark ? palette.onSurface : palette.surface,
    _TileStyle.red => palette.danger,
  };

  Color? edge(_TileStyle style) => switch (style) {
    _TileStyle.plain => null,
    _TileStyle.black => palette.isDark ? palette.outlineSubtle : null,
    _TileStyle.red => palette.danger,
  };
}

class _SchulteTile extends StatelessWidget {
  const _SchulteTile({
    required this.text,
    required this.style,
    required this.colors,
    required this.size,
    required this.fontSize,
    required this.dim,
    required this.scale,
    required this.shift,
    required this.press,
    required this.alert,
  });
  final String text;
  final _TileStyle style;
  final _SchulteColors colors;
  final double size;
  final double fontSize;
  // 点过变淡的程度 0–1（只留三成）、整体缩放、点错时的横向晃动、按下的程度与警示描边的浓度。
  final double dim;
  final double scale;
  final double shift;
  final double press;
  final double alert;

  // 格里数字的样式（量最宽的数时同一份）。
  static TextStyle numberStyle(double fontSize) => TextStyle(fontSize: fontSize, height: 1.2, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]);

  @override
  Widget build(BuildContext context) {
    final keep = 1 - .7 * dim;
    final ink = colors.ink(style);
    final base = Color.lerp(colors.fill(style), ink, .12 * press)!;
    final edge = colors.edge(style);
    final danger = colors.palette.danger;
    final resting = edge?.withValues(alpha: edge.a * keep);
    final border = alert > 0
        ? Border.all(color: Color.lerp(resting ?? danger.withValues(alpha: 0), danger, alert)!, width: 2.5)
        : resting == null
        ? null
        : Border.all(color: resting, width: style == _TileStyle.red ? 2 : 1);
    return Center(child: Transform.translate(offset: Offset(shift, 0), child: Transform.scale(scale: scale, child: SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(color: base.withValues(alpha: base.a * keep), borderRadius: BorderRadius.circular(size * .22), border: border),
        child: Center(child: Text(
          text,
          maxLines: 1,
          softWrap: false,
          textScaler: TextScaler.noScaling,
          style: numberStyle(fontSize).copyWith(color: ink.withValues(alpha: keep)),
        )),
      ),
    ))));
  }
}
