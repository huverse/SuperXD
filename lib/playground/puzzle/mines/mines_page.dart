import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/mines/mines_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';

enum _Mode { reveal, flag }

// 一步操作：翻开（点的格、这一步翻开的格、连开时顺手拔掉的插错的旗）或插旗、拔旗；撤销按步退回。
typedef _Step = ({int cell, bool flag, List<int> opened, List<int> unflagged});

// 翻开一片时逐圈淡出：每格淡出 _fadeMs，每往外一圈晚 _ringGap，超过 _maxRings 圈的一起淡（大片连开不拖太久）。
const _fadeMs = 160, _ringGap = 35, _maxRings = 8;
// 解开后的收尾：没插旗的雷先插上旗（_flagMs），雷位按行依次亮一下（每颗 _glowMs，最后一行晚 _glowSpread）。
const _flagMs = 260, _glowMs = 380, _glowSpread = 280;

// 扫雷对局页：下方分段选「翻开 / 插旗」，点格子按当前模式操作，任何模式下长按未翻的格都是插旗、长按旗子拔旗；点已翻开的数字，
// 周围插旗数等于数字时把其余未翻格一起翻开（经典的双击开，这里单击）。翻到雷这一局就结束（见 _lose）。
// 所有不是雷的格翻完即解开：旗子全部插好、雷位亮一下再弹结果。格子不到 48 时双指放大，放大后单指平移。
class MinesPage extends StatefulWidget {
  const MinesPage({super.key, required this.game, required this.store, this.seeds});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;

  @override
  State<MinesPage> createState() => _MinesPageState();
}

class _MinesPageState extends State<MinesPage> with TickerProviderStateMixin {
  static const _rules = MinesRules();
  late final _session = PlaySession<MinesPuzzle, List<int>>(game: widget.game, rules: _rules, store: widget.store, seeds: widget.seeds);
  late var _counts = minesCounts(_puzzle);
  late var _revealed = minesStartOpen(_puzzle, _counts);
  late var _mineCount = _puzzle.mines.where((mine) => mine).length;
  final _flags = <int>{};
  // 翻开的动作序列（即答案），与操作记录一起撤销。
  final _moves = <int>[];
  final _history = <_Step>[];
  var _mode = _Mode.reveal;
  // 踩到的雷（点数字连开可能一次踩到几颗）；不为空就是这一局结束了，只能从头来或换一道题。
  var _boom = <int>{};
  // 手势：一根手指点按（移动超过触摸容差就不算点）、按住到长按时长插旗或拔旗，两根手指缩放；放大后单指拖动平移。
  final _pointers = <int, Offset>{};
  Timer? _hold;
  int? _tapCell, _pressed;
  Offset _tapAt = Offset.zero, _dragPan = Offset.zero;
  bool _pinching = false;
  double _pinchDistance = 1, _pinchZoom = 1;
  Offset _pinchFocal = Offset.zero, _pinchPan = Offset.zero;
  double _zoom = 1;
  Offset _pan = Offset.zero;
  _MinesLayout? _layout;
  // 动效：这一步翻开的格按圈淡出；插上、拔掉的旗缩放一下；违规的格左右晃一下；解开后的收尾。
  final _rings = <int, int>{};
  late final _wave = AnimationController(vsync: this, duration: const Duration(milliseconds: _fadeMs), value: 1);
  late final _pop = AnimationController(vsync: this, duration: const Duration(milliseconds: 200), value: 1);
  int? _popCell;
  late final _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 360));
  int? _shakeCell;
  late final _finale = AnimationController(vsync: this, duration: const Duration(milliseconds: _flagMs + _glowMs + _glowSpread));
  var _finaleFlags = <int>{};
  final _digits = _DigitPainters();

  @override
  void dispose() {
    _hold?.cancel();
    _wave.dispose();
    _pop.dispose();
    _shake.dispose();
    _finale.dispose();
    _digits.dispose();
    _session.dispose();
    super.dispose();
  }

  MinesPuzzle get _puzzle => _session.puzzle;
  bool get _still => MediaQuery.disableAnimationsOf(context);
  bool get _lost => _boom.isNotEmpty;

  void _reset() {
    _hold?.cancel();
    _counts = minesCounts(_puzzle);
    _revealed = minesStartOpen(_puzzle, _counts);
    _mineCount = _puzzle.mines.where((mine) => mine).length;
    _flags.clear();
    _moves.clear();
    _history.clear();
    _boom = {};
    _rings.clear();
    _finaleFlags = {};
    _pressed = _tapCell = _popCell = _shakeCell = null;
    _zoom = 1;
    _pan = Offset.zero;
    _wave.value = 1;
    _pop.value = 1;
    _shake.value = 0;
    _finale.value = 0;
  }

  void _newGame(PuzzleTier? tier) => setState(() {
    _session.next(tier: tier);
    _reset();
  });

  void _restart() => setState(() {
    _session.restart();
    _reset();
  });

  // ---------- 操作 ----------

  void _tap(int cell) {
    if (_session.finished) return;
    if (_revealed[cell]) return _chord(cell);
    if (_mode == _Mode.flag) return _toggleFlag(cell);
    // 插着旗的格不让翻（防手滑），先切到插旗拔掉。
    if (_flags.contains(cell)) return _refuse(cell);
    _open(cell, [cell]);
  }

  // 点已翻开的数字：周围插旗数等于数字，就把其余没插旗的未翻格一起翻开；对不上算违规；0 格或周围没东西可翻的不理。
  void _chord(int cell) {
    final around = minesAround(_puzzle.width, _puzzle.height, cell);
    final hidden = [for (final other in around) if (!_revealed[other] && !_flags.contains(other)) other];
    if (_counts[cell] == 0 || hidden.isEmpty) return;
    if (around.where(_flags.contains).length != _counts[cell]) return _refuse(cell);
    _open(cell, hidden);
  }

  // 翻开一步：targets 是要翻的格（点格子是它自己，点数字连开是周围没插旗的未翻格），0 格连开一片，连开到的插错的旗顺手拔掉；翻到雷这一局结束。
  void _open(int cell, List<int> targets) {
    final opened = <(int, int)>[], boom = <int>{};
    for (final target in targets) {
      if (_revealed[target]) continue;
      final ring = target == cell ? 0 : 1;
      if (_puzzle.mines[target]) {
        _revealed[target] = true;
        boom.add(target);
        opened.add((target, ring));
      } else {
        opened.addAll(minesOpen(_puzzle, _counts, _revealed, target, ring: ring));
      }
    }
    final unflagged = [for (final (other, _) in opened) if (_flags.remove(other)) other];
    _session.moved();
    if (boom.isNotEmpty) return _lose(opened, boom);
    setState(() {
      _moves.add(cell);
      _history.add((cell: cell, flag: false, opened: [for (final (other, _) in opened) other], unflagged: unflagged));
      _startWave(opened);
    });
    playTick();
    if (_rules.solved(_puzzle, _moves)) unawaited(_finish());
  }

  // [人工决策-2026-11-13 16:05:37] 用户选定：踩雷即结束（揭开全部雷、锁住棋盘、不能撤销、不记成绩，只能从头来或换一道题）；加长按插旗（任何模式下长按未翻开的格插旗、长按旗子拔旗，长按只管旗）。
  // 踩雷：揭开全部雷、踩到的垫警示红、插错的旗打叉，重震；缩放复原看全盘，棋盘锁住，底部原地换成「这一题从头来」「换一道题」（build 里）。
  // 不弹提示条：结束是停住的状态，棋盘、状态行（改写「踩到雷了」）与换掉的按钮一直都在，提示条几秒就收、还压在新按钮上方；读屏靠棋盘上的播报。
  // 停表不记成绩用 PlaySession.end（切后台回来不再走表、换难度不再确认、对局页停走表），只有 finish 才记成绩，这里不调。
  void _lose(List<(int, int)> opened, Set<int> boom) {
    playRejected();
    _hold?.cancel();
    _session.end();
    setState(() {
      _boom = boom;
      _startWave(opened);
      _pointers.clear();
      _pressed = _tapCell = null;
      _pinching = false;
      _zoom = 1;
      _pan = Offset.zero;
    });
  }

  // 长按（见上面的人工决策）：手指按住未翻的格到系统的长按时长、期间没挪出拖动阈值也没落第二根手指，就插旗或拔旗，不看当前模式；
  // 抬手时不再当点按（_tapCell 清掉），之后再挪手指从这里起算平移。
  void _longPress(int cell) {
    _hold = null;
    if (_tapCell != cell || _pointers.length != 1 || _session.finished || _revealed[cell]) return;
    _tapCell = null;
    _tapAt = _pointers.values.single;
    _dragPan = _pan;
    _pressed = null;
    _toggleFlag(cell);
  }

  void _startWave(List<(int, int)> opened) {
    _rings
      ..clear()
      ..addEntries([for (final (cell, ring) in opened) MapEntry(cell, math.min(ring, _maxRings))]);
    if (_still) {
      _wave.value = 1;
      return;
    }
    final rings = _rings.values.fold(0, math.max);
    _wave.duration = Duration(milliseconds: _fadeMs + rings * _ringGap);
    unawaited(_wave.forward(from: 0));
  }

  void _toggleFlag(int cell) {
    playTick();
    _session.moved();
    setState(() {
      if (!_flags.remove(cell)) _flags.add(cell);
      _history.add((cell: cell, flag: true, opened: const [], unflagged: const []));
      _popAt(cell);
    });
  }

  void _popAt(int cell) {
    _popCell = cell;
    if (_still) {
      _pop.value = 1;
    } else {
      unawaited(_pop.forward(from: 0));
    }
  }

  void _refuse(int cell) {
    playRejected();
    setState(() => _shakeCell = cell);
    if (!_still) unawaited(_shake.forward(from: 0));
  }

  void _undo() {
    if (_history.isEmpty || _session.finished) return;
    playTick();
    setState(() {
      final last = _history.removeLast();
      if (last.flag) {
        if (!_flags.remove(last.cell)) _flags.add(last.cell);
        _popAt(last.cell);
      } else {
        for (final cell in last.opened) {
          _revealed[cell] = false;
        }
        _flags.addAll(last.unflagged);
        _moves.removeLast();
      }
      _rings.clear();
      _wave.value = 1;
    });
  }

  Future<void> _finish() async {
    final newBest = await _session.finish();
    if (!mounted) return;
    setState(() {
      _pointers.clear();
      _pressed = _tapCell = null;
      _pinching = false;
      _zoom = 1;
      _pan = Offset.zero;
      // 没插旗的雷都插上旗，收尾时缩放着出现。
      _finaleFlags = {for (var cell = 0; cell < _puzzle.mines.length; cell++) if (_puzzle.mines[cell] && !_flags.contains(cell)) cell};
      _flags.addAll(_finaleFlags);
    });
    // 等最后一片翻开的淡完，再插旗、雷位亮一下。
    final still = _still;
    if (!still) await _wave.forward();
    if (!mounted) return;
    await _finale.animateTo(1, duration: still ? Duration.zero : null);
    if (!mounted) return;
    final choice = await showPlayResult(context, session: _session, newBest: newBest, detail: '${_puzzle.width}×${_puzzle.height} · $_mineCount 颗雷');
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
      // 第二根手指落下：这一下不算点按也不算长按，改成缩放。
      _tapCell = null;
      _hold?.cancel();
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
    _dragPan = _pan;
    if (cell == null || _revealed[cell]) return;
    _hold?.cancel();
    _hold = Timer(kLongPressTimeout, () => _longPress(cell));
    setState(() => _pressed = cell);
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
      _hold?.cancel();
      if (_pressed != null) setState(() => _pressed = null);
    }
    if (_tapCell == null && _zoom > 1) setState(() => _pan = layout.clampPan(_dragPan + moved, _zoom));
  }

  void _up(PointerEvent event) {
    _pointers.remove(event.pointer);
    _hold?.cancel();
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
    if (cell == null || event is PointerCancelEvent) return;
    _tap(cell);
  }

  // ---------- 画面 ----------

  String get _status {
    if (_lost) return '踩到雷了';
    final left = _mineCount - _flags.length;
    return left >= 0 ? '剩 $left 颗雷' : '旗多插了 ${-left} 面';
  }

  @override
  Widget build(BuildContext context) => PlayFrame(
    session: _session,
    onNewGame: _newGame,
    onRestart: _restart,
    status: _status,
    // 踩雷后原地换成下一步能做的两件事（同 ⋯ 里的同名项）；主操作是换一道题：这一题的雷已经全看过了，从头来留作次要的。
    controls: _lost
        ? [
            FilledButton.icon(onPressed: _restart, icon: const CampusIcon(CampusIcons.restore), label: const Text('这一题从头来')),
            FilledButton.icon(style: campusProminent, onPressed: () => _newGame(null), icon: const CampusIcon(CampusIcons.shuffle), label: const Text('换一道题')),
          ]
        : [
            SizedBox(width: 200, child: CampusSegmented<_Mode>(
              values: const [_Mode.reveal, _Mode.flag],
              label: (mode) => mode == _Mode.reveal ? '翻开' : '插旗',
              selected: _mode,
              onSelected: _session.finished ? null : (mode) => setState(() => _mode = mode),
            )),
            FilledButton.icon(onPressed: _history.isEmpty || _session.finished ? null : _undo, icon: const CampusIcon(CampusIcons.undo), label: const Text('撤销')),
          ],
    board: PlayBoardBox(aspectRatio: _puzzle.width / _puzzle.height, maxWidth: 64.0 * _puzzle.width, builder: (context, size) {
      final palette = CampusPalette.of(context);
      final layout = _layout = _MinesLayout(columns: _puzzle.width, rows: _puzzle.height, size: size, zoom: _zoom, pan: _pan);
      // 数字 14 号起、跟着字号缩放，格子大时跟着格子放大（约格宽的 56%），按半号取整免得缩放时每帧重排。
      final fontSize = (math.max(MediaQuery.textScalerOf(context).scale(14), layout.step * .56) * 2).roundToDouble() / 2;
      _digits.prepare(DefaultTextStyle.of(context).style.merge(TextStyle(fontSize: fontSize, height: 1, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()])), palette);
      // 外面垫一个手指一落下就赢下手势竞争的识别器：iOS 的页面任意位置右滑返回约 18dp 就认横向拖动，不垫的话双指缩放的第一根手指、
      // 放大后的单指平移都可能被它抢走、整页滑走；点按、缩放与平移走原始指针（Listener），不参与手势竞争，不受影响。
      return RawGestureDetector(
        gestures: {EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(EagerGestureRecognizer.new, (_) {})},
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: _up,
          child: Stack(children: [
            Positioned.fill(child: AnimatedBuilder(
              animation: Listenable.merge([_wave, _pop, _shake, _finale]),
              builder: (context, _) => CustomPaint(painter: _MinesPainter(
                layout: layout,
                puzzle: _puzzle,
                counts: _counts,
                revealed: _revealed,
                flags: _flags,
                boom: _boom,
                palette: palette,
                digits: _digits,
                rings: _rings,
                wave: _wave.value * _wave.duration!.inMilliseconds,
                pressed: _pressed,
                popCell: _pop.isAnimating ? _popCell : null,
                pop: Curves.easeOutBack.transform(_pop.value),
                shakeCell: _shake.isAnimating ? _shakeCell : null,
                shake: _shake.value,
                finaleFlags: _finaleFlags,
                finale: _finale.value * (_flagMs + _glowMs + _glowSpread),
              )),
            )),
            // 踩雷时读屏播报（不弹提示条，状态行的变化读屏不会主动念）。
            if (_lost) Positioned.fill(child: Semantics(container: true, liveRegion: true, label: '踩到雷了', child: const SizedBox.expand())),
            ..._cellSemantics(layout),
          ]),
        ),
      );
    }),
  );

  // 读屏：每格一个按钮，读出第几行第几列与状态，点按同手指点这一格（按当前的翻开或插旗）；未翻的格另带自定义操作「插旗 / 拔旗」，
  // 同手指长按，不用切模式。结束后（解开或踩雷）都不能操作。
  List<Widget> _cellSemantics(_MinesLayout layout) => [
    for (var cell = 0; cell < _puzzle.mines.length; cell++)
      if (layout.cellRect(cell) case final rect when layout.viewport.overlaps(rect))
        Positioned.fromRect(rect: rect, child: Semantics(
          button: true,
          label: '第${cell ~/ _puzzle.width + 1}行第${cell % _puzzle.width + 1}列，${_cellState(cell)}',
          onTap: _session.finished ? null : () => _tap(cell),
          customSemanticsActions: _session.finished || _revealed[cell] ? null : {CustomSemanticsAction(label: _flags.contains(cell) ? '拔旗' : '插旗'): () => _toggleFlag(cell)},
          child: const SizedBox.expand(),
        )),
  ];

  String _cellState(int cell) {
    if (_boom.contains(cell)) return '踩到的雷';
    final flagged = _flags.contains(cell);
    if (_lost && _puzzle.mines[cell] && !flagged) return '雷';
    if (_lost && flagged && !_puzzle.mines[cell]) return '插错的旗';
    if (flagged) return '已插旗';
    if (!_revealed[cell]) return '未翻开';
    return _counts[cell] == 0 ? '空白' : '数字 ${_counts[cell]}';
  }
}

// 棋盘几何：每格 cell 见方，放大时格子按 zoom 放大、按 pan 平移（pan ≤ 0），裁在棋盘里。
class _MinesLayout {
  const _MinesLayout({required this.columns, required this.rows, required this.size, required this.zoom, required this.pan});
  final int columns, rows;
  final Size size;
  final double zoom;
  final Offset pan;

  double get cell => size.width / columns;
  double get step => cell * zoom;
  // 一格不到 48 时可以放大到 48 一格（触区不小于 48）；本来就够大的不给放大。
  double get maxZoom => math.max(1, 48 / cell);
  Rect get viewport => Offset.zero & size;

  Rect cellRect(int index) => Rect.fromLTWH(pan.dx + index % columns * step, pan.dy + index ~/ columns * step, step, step);

  int? cellAt(Offset point) {
    if (!viewport.contains(point)) return null;
    final local = point - pan;
    return (local.dy / step).floor().clamp(0, rows - 1) * columns + (local.dx / step).floor().clamp(0, columns - 1);
  }

  Offset clampPan(Offset value, double zoom) => Offset(value.dx.clamp(size.width * (1 - zoom), 0), value.dy.clamp(size.height * (1 - zoom), 0));
}

// 翻开格的底色（凹下去的淡底）、未翻格（卡片底色的小方块）与它下沿露出的一道侧边：深色下未翻格比底色亮，浅色下底色比卡片深。
Color _sunkColor(CampusPalette palette) => palette.isDark ? Color.lerp(palette.surface, palette.backgroundTop, .45)! : Color.lerp(palette.surface, palette.surfaceSelected, .7)!;
Color _tileColor(CampusPalette palette) => palette.isDark ? Color.lerp(palette.surface, palette.surfaceSelected, .7)! : palette.surface;
Color _lipColor(CampusPalette palette) => palette.isDark ? Color.lerp(palette.surface, palette.backgroundTop, .12)! : Color.lerp(palette.surfaceSelected, palette.outline, .3)!;

// 数字 1–8 的颜色（同经典扫雷每个数字一种颜色）：1–6 从激活色按色相转开（4 同 1 的色相、压深一档），7、8 是正文色与次要色；
// 每种颜色沿亮度往深（浅色）或往亮（深色）调，直到对翻开格的底色不低于 4.5:1。
List<Color> _digitColors(CampusPalette palette) {
  final accent = HSLColor.fromColor(palette.accent);
  final saturation = accent.saturation.clamp(.45, .75);
  final dark = palette.isDark;
  final ground = _sunkColor(palette).computeLuminance();
  double contrast(Color color) {
    final luminance = color.computeLuminance();
    return (math.max(luminance, ground) + .05) / (math.min(luminance, ground) + .05);
  }

  Color readable(double turn, double lightness) {
    var tone = HSLColor.fromAHSL(1, (accent.hue + turn) % 360, saturation, lightness);
    while (contrast(tone.toColor()) < 4.5 && tone.lightness > .02 && tone.lightness < .98) {
      tone = tone.withLightness((tone.lightness + (dark ? .02 : -.02)).clamp(0, 1));
    }
    return tone.toColor();
  }

  final (base, deeper) = dark ? (.7, .82) : (.46, .32);
  return [
    readable(0, base),
    readable(120, base),
    readable(240, base),
    readable(0, deeper),
    readable(180, base),
    readable(300, base),
    palette.onSurface,
    palette.onSurfaceVariant,
  ];
}

// 数字的排版缓存：1–8 各一个，字体、字号或配色变了才重排。
class _DigitPainters {
  Object? _key;
  final painters = <TextPainter>[];

  void dispose() {
    for (final painter in painters) {
      painter.dispose();
    }
    painters.clear();
  }

  void prepare(TextStyle style, CampusPalette palette) {
    final key = (style, palette);
    if (key == _key) return;
    _key = key;
    dispose();
    for (final (index, color) in _digitColors(palette).indexed) {
      painters.add(TextPainter(text: TextSpan(text: '${index + 1}', style: style.copyWith(color: color)), textDirection: TextDirection.ltr)..layout());
    }
  }
}

class _MinesPainter extends CustomPainter {
  _MinesPainter({
    required this.layout,
    required this.puzzle,
    required this.counts,
    required this.revealed,
    required this.flags,
    required this.boom,
    required this.palette,
    required this.digits,
    required this.rings,
    required this.wave,
    required this.pressed,
    required this.popCell,
    required this.pop,
    required this.shakeCell,
    required this.shake,
    required this.finaleFlags,
    required this.finale,
  });
  final _MinesLayout layout;
  final MinesPuzzle puzzle;
  final List<int> counts;
  final List<bool> revealed;
  final Set<int> flags, boom, finaleFlags;
  final CampusPalette palette;
  final _DigitPainters digits;
  // 这一步翻开的格在第几圈与淡出走过的毫秒数；收尾走过的毫秒数。
  final Map<int, int> rings;
  final double wave, finale;
  final int? pressed, popCell, shakeCell;
  // pop：插上（拔掉）那面旗的缩放进度；shake：晃动进度。
  final double pop, shake;

  bool get lost => boom.isNotEmpty;

  // 这一格的未翻方块还剩几分不透明：这一步翻开的按圈淡出，其余翻开的是 0、没翻的是 1。
  double _cover(int cell) {
    if (!revealed[cell]) return 1;
    final ring = rings[cell];
    if (ring == null) return 0;
    return 1 - ((wave - ring * _ringGap) / _fadeMs).clamp(0.0, 1.0);
  }

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final viewport = layout.viewport, step = layout.step;
    final board = RRect.fromRectAndRadius(viewport, const Radius.circular(14));
    final dark = palette.isDark;
    final cells = puzzle.mines.length;
    canvas.save();
    canvas.clipRRect(board);
    canvas.drawRect(viewport, Paint()..color = _sunkColor(palette));
    // 格线：翻开的区域里隔开每一格（未翻的方块盖在上面），一条路径一次画完。
    final grid = Path();
    for (var column = 1; column < layout.columns; column++) {
      final x = layout.pan.dx + column * step;
      grid
        ..moveTo(x, layout.pan.dy)
        ..lineTo(x, layout.pan.dy + layout.rows * step);
    }
    for (var row = 1; row < layout.rows; row++) {
      final y = layout.pan.dy + row * step;
      grid
        ..moveTo(layout.pan.dx, y)
        ..lineTo(layout.pan.dx + layout.columns * step, y);
    }
    canvas.drawPath(grid, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = palette.outlineSubtle.withValues(alpha: dark ? .7 : .9));

    // 踩到的雷垫警示红底。
    final boomPlates = Path();
    for (final cell in boom) {
      boomPlates.addRRect(_plate(cell));
    }
    canvas.drawPath(boomPlates, Paint()..color = palette.dangerFill);

    // 数字：画在翻开格的底上，这一步翻开的格上面还盖着正在淡出的方块。
    for (var cell = 0; cell < cells; cell++) {
      if (!revealed[cell] || puzzle.mines[cell] || counts[cell] == 0) continue;
      final rect = layout.cellRect(cell);
      if (!rect.overlaps(viewport)) continue;
      final painter = digits.painters[counts[cell] - 1];
      final center = rect.center.translate(cell == shakeCell ? _wobble(step) : 0, 0);
      painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
    }

    // 未翻的方块：输了以后没插旗的雷和插旗的格以外的雷都露出来。下沿先画一道深一点的侧边，看着是凸起的；淡出中的按圈分组画。
    final tiles = Path(), lips = Path();
    final fading = <double, (Path, Path)>{};
    final lip = math.max(1.0, step * .05);
    for (var cell = 0; cell < cells; cell++) {
      final cover = lost && puzzle.mines[cell] && !flags.contains(cell) ? 0.0 : _cover(cell);
      if (cover <= 0) continue;
      final rect = _plate(cell);
      if (!rect.outerRect.overlaps(viewport)) continue;
      final (tile, edge) = cover >= 1 ? (tiles, lips) : fading.putIfAbsent(cover, () => (Path(), Path()));
      tile.addRRect(rect);
      edge.addRRect(rect.shift(Offset(0, lip)));
    }
    final tileColor = _tileColor(palette), lipColor = _lipColor(palette);
    canvas.drawPath(lips, Paint()..color = lipColor);
    canvas.drawPath(tiles, Paint()..color = tileColor);
    for (final MapEntry(key: cover, value: (tile, edge)) in fading.entries) {
      canvas.drawPath(edge, Paint()..color = lipColor.withValues(alpha: cover));
      canvas.drawPath(tile, Paint()..color = tileColor.withValues(alpha: cover));
    }
    final pressed = this.pressed;
    if (pressed != null && !revealed[pressed]) {
      canvas.drawRRect(_plate(pressed), Paint()..color = palette.onSurface.withValues(alpha: dark ? .12 : .08));
    }

    // 收尾：雷位按行依次亮一下（方块上铺一层激活色，起落是一段正弦）。
    if (finale > _flagMs) {
      for (var cell = 0; cell < cells; cell++) {
        if (!puzzle.mines[cell]) continue;
        final delay = _flagMs + (layout.rows > 1 ? cell ~/ layout.columns / (layout.rows - 1) : 0) * _glowSpread;
        final progress = ((finale - delay) / _glowMs).clamp(0.0, 1.0);
        if (progress <= 0 || progress >= 1) continue;
        canvas.drawRRect(_plate(cell), Paint()..color = palette.accent.withValues(alpha: (dark ? .55 : .45) * math.sin(progress * math.pi)));
      }
    }

    // 旗子与雷：同一种颜色的图形拼成一条路径一次画完。
    final poles = Path(), pennants = Path(), mines = Path(), boomMines = Path(), crosses = Path();
    for (final cell in flags) {
      final rect = layout.cellRect(cell);
      if (!rect.overlaps(viewport)) continue;
      var scale = 1.0;
      if (cell == popCell) scale = flags.contains(cell) ? pop : 1 - pop;
      if (finaleFlags.contains(cell)) scale = Curves.easeOutBack.transform((finale / _flagMs).clamp(0.0, 1.0));
      if (scale <= 0) continue;
      _flag(poles, pennants, rect.center.translate(cell == shakeCell ? _wobble(step) : 0, 0), step * scale);
      if (lost && !puzzle.mines[cell]) {
        final mark = rect.deflate(step * .22);
        crosses
          ..moveTo(mark.left, mark.top)
          ..lineTo(mark.right, mark.bottom)
          ..moveTo(mark.right, mark.top)
          ..lineTo(mark.left, mark.bottom);
      }
    }
    // 刚拔掉的那面旗缩小着消失。
    final popped = popCell;
    if (popped != null && !flags.contains(popped) && pop < 1) _flag(poles, pennants, layout.cellRect(popped).center, step * (1 - pop));
    if (lost) {
      for (var cell = 0; cell < cells; cell++) {
        if (!puzzle.mines[cell] || flags.contains(cell)) continue;
        _mine(boom.contains(cell) ? boomMines : mines, layout.cellRect(cell).center, step);
      }
    }
    canvas.drawPath(poles, Paint()..color = palette.onSurface);
    canvas.drawPath(pennants, Paint()..color = palette.danger);
    canvas.drawPath(mines, Paint()..color = palette.onSurface);
    // 警示红底上用白色图形（同激活色底上的白字）。
    canvas.drawPath(boomMines, Paint()..color = Colors.white);
    canvas.drawPath(crosses, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, step * .07)
      ..strokeCap = StrokeCap.round
      ..color = palette.onSurface);
    canvas.restore();
    canvas.drawRRect(board, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = palette.outlineSubtle);
  }

  double _wobble(double step) => math.sin(shake * math.pi * 5) * step * .1 * (1 - shake);

  RRect _plate(int cell) => RRect.fromRectAndRadius(layout.cellRect(cell).deflate(layout.step * .07), Radius.circular(layout.step * .16));

  // 旗子：一根旗杆、底座与向右飘的三角旗面，按格子中心与边长画进两条路径（旗杆底座一色、旗面一色）。
  static void _flag(Path poles, Path pennants, Offset center, double size) {
    final top = center.dy - size * .27, bottom = center.dy + size * .2, pole = center.dx - size * .1;
    poles
      ..addRect(Rect.fromLTRB(pole - size * .03, top, pole + size * .03, bottom))
      ..addRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(center.dx - size * .02, bottom + size * .03), width: size * .36, height: size * .07), Radius.circular(size * .035)));
    pennants.addPolygon([Offset(pole + size * .03, top), Offset(pole + size * .33, top + size * .12), Offset(pole + size * .03, top + size * .25)], true);
  }

  // 雷：圆身加四道穿过中心的尖刺（横、竖与两条斜线），拼进一条路径。尖刺的顶点按顺时针排（同 addOval 的方向），
  // 非零环绕填充下叠在一起的部分才是实心的，绕向相反会在重叠处挖出洞。
  static void _mine(Path path, Offset center, double size) {
    path.addOval(Rect.fromCircle(center: center, radius: size * .19));
    final reach = size * .3, half = size * .035;
    for (var turn = 0; turn < 4; turn++) {
      final angle = turn * math.pi / 4;
      final along = Offset(math.cos(angle), math.sin(angle)), across = Offset(-math.sin(angle), math.cos(angle));
      path.addPolygon([
        center + along * reach - across * half,
        center + along * reach + across * half,
        center - along * reach + across * half,
        center - along * reach - across * half,
      ], true);
    }
  }

  @override
  bool shouldRepaint(_MinesPainter old) => true;
}
