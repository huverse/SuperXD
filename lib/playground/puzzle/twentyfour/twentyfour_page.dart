import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/playground/challenge/play_challenge.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/twentyfour/twentyfour_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';

// 数写成文字：负号用数学的减号，分数写成「分子/分母」（算式行与提示条里用；卡片上的分数上下叠着画）。
String twentyFourText(TwentyFourValue value) => '${value.numerator < 0 ? '−' : ''}${value.numerator.abs()}${value.whole ? '' : '/${value.denominator}'}';

// 读屏的念法：分数念成「3分之8」，负数前面加「负」。
String twentyFourReading(TwentyFourValue value) {
  final sign = value.numerator < 0 ? '负' : '';
  return value.whole ? '$sign${value.numerator.abs()}' : '$sign${value.denominator}分之${value.numerator.abs()}';
}

// 运算键的读屏名字与图标；算式念出来时运算的说法（乘方念「几的几次方」、开方念「根号几」，在 _Card.merged 里拼）。
const _opNames = {
  TwentyFourOp.add: '加',
  TwentyFourOp.subtract: '减',
  TwentyFourOp.multiply: '乘',
  TwentyFourOp.divide: '除',
  TwentyFourOp.power: '乘方',
  TwentyFourOp.root: '开方',
};
const _opIcons = {
  TwentyFourOp.add: CampusIcons.operatorAdd,
  TwentyFourOp.subtract: CampusIcons.operatorSubtract,
  TwentyFourOp.multiply: CampusIcons.operatorMultiply,
  TwentyFourOp.divide: CampusIcons.operatorDivide,
  TwentyFourOp.power: CampusIcons.operatorPower,
  TwentyFourOp.root: CampusIcons.operatorRoot,
};
const _spokenOps = {TwentyFourOp.add: '加', TwentyFourOp.subtract: '减', TwentyFourOp.multiply: '乘', TwentyFourOp.divide: '除以'};

// 一张卡：值、算出它的算式（开局的卡就是那个数）、算式的念法（读屏用）与算式最外层的优先级
// （加减 1、乘除 2、乘方 3、开方 4、单个数 5，拼进更大的算式时决定加不加括号）。
class _Card {
  const _Card(this.value, this.expression, this.spoken, this.precedence);
  _Card.number(int number) : value = TwentyFourValue(number), expression = '$number', spoken = '$number', precedence = 5;
  final TwentyFourValue value;
  final String expression, spoken;
  final int precedence;

  // first op second 合成的新卡（开方时 second 就是 first）。乘方写成「底^指数」、开方写成「√里面」，底、指数与开方的里面不是单个数就加括号；
  // 其余的左边优先级低于这一步才加括号，右边同级时减、除也要加（a − (b − c) 不等于 a − b − c）。
  static _Card merged(_Card first, TwentyFourOp op, _Card second, TwentyFourValue value) {
    String shown(_Card card, bool wrap) => wrap ? '(${card.expression})' : card.expression;
    String said(_Card card, bool wrap) => wrap ? '（${card.spoken}）' : card.spoken;
    if (op.unary) return _Card(value, '√${shown(first, first.precedence < 5)}', '根号${said(first, first.precedence < 5)}', 4);
    if (op == TwentyFourOp.power) {
      final (wrapBase, wrapExponent) = (first.precedence < 5, second.precedence < 5);
      return _Card(value, '${shown(first, wrapBase)}^${shown(second, wrapExponent)}', '${said(first, wrapBase)}的${said(second, wrapExponent)}次方', 3);
    }
    final level = op == TwentyFourOp.add || op == TwentyFourOp.subtract ? 1 : 2;
    final tight = op == TwentyFourOp.subtract || op == TwentyFourOp.divide;
    final (wrapLeft, wrapRight) = (first.precedence < level, second.precedence < level || (tight && second.precedence == level));
    return _Card(value, '${shown(first, wrapLeft)} ${op.symbol} ${shown(second, wrapRight)}', '${said(first, wrapLeft)}${_spokenOps[op]}${said(second, wrapRight)}', level);
  }
}

// 24 点对局页：四张卡排成两行两列，下面是运算键（题面允许哪些就放哪些：入门到普通加减乘除四个，困难起多乘方、开方，放不下一行就排两行）。
// 二元运算：点一张卡（描激活色的边），再点运算和另一张卡，两张合成一张：第一张滑向第二张并淡去，第二张的位置上新卡放大淡入，
// 第一张的位置空出来（留一圈淡边框，卡片不挪位置）。先点运算再点卡也行，凑齐「第一张、运算、第二张」才合。
// 开方是一元的：有选着的卡时点「开方」直接作用在它上面，没选卡时先点「开方」再点卡也行；开完那张卡仍选着，接着就能和别的卡合。
// 不合规（除以 0、开不尽、指数不合规、结果太大）不让做，重震、那张卡晃一下，提示条写原因。
// 剩一张：是 24 就解开（那张卡铺满激活色、轻轻鼓一下，再弹结果）；不是 24 重震、晃一下、描警示色的边，可撤销（能开方的还可以接着开）。
// 卡片与运算键中间写最近算出来的那张卡的算式（如「3 − 8 ÷ 3 = 1/3」「2^3 × √9 = 24」，最多两行），读屏念成「2的3次方乘根号9，等于24」。
class TwentyFourPage extends StatefulWidget {
  const TwentyFourPage({super.key, required this.game, required this.store, this.seeds, this.challenge});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;
  // 挑战里的一关（题面是服务器给的）；自由模式为空。
  final PlayChallenge? challenge;

  @override
  State<TwentyFourPage> createState() => _TwentyFourPageState();
}

class _TwentyFourPageState extends State<TwentyFourPage> with TickerProviderStateMixin {
  static const _rules = TwentyFourRules();
  late final _session = PlaySession<TwentyFourPuzzle, List<TwentyFourStep>>(game: widget.game, rules: _rules, store: widget.store, seeds: widget.seeds, challenge: widget.challenge);
  // 四个位置上的卡（null 是合并后空出来的位置）与每一步合并前的样子（撤销按步退回）。
  late var _cards = _deal();
  final _history = <({List<_Card?> before, TwentyFourStep step})>[];
  // 点着的第一张卡与运算。
  int? _picked;
  TwentyFourOp? _op;
  // 手指按着的卡：按下时整块变暗。
  int? _pressed;
  // 合并的过渡：_merge 从 0 走到 1 是 before 变成 after（撤销时倒着走）；不在走的时候直接画 _cards。
  late final _merge = AnimationController(vsync: this, duration: const Duration(milliseconds: 260), value: 1);
  ({List<_Card?> before, List<_Card?> after, TwentyFourStep step})? _transition;
  // 不让合或剩一张不是 24：那张卡左右晃一下。
  late final _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 360));
  int? _shaking;
  // 解开：最后那张卡铺上激活色、轻轻鼓一下。
  late final _win = AnimationController(vsync: this, duration: const Duration(milliseconds: 560));
  late final _motion = Listenable.merge([_merge, _shake, _win]);

  // 运算键高 52（触区不小于 48）；一行放得下、每个键不窄于 _keyMin 才排一行。
  static const _gap = 12.0, _keyHeight = 52.0, _keyMin = 52.0;

  @override
  void dispose() {
    _merge.dispose();
    _shake.dispose();
    _win.dispose();
    _session.dispose();
    super.dispose();
  }

  bool get _reduced => MediaQuery.disableAnimationsOf(context);
  Iterable<_Card> get _left => _cards.nonNulls;

  List<_Card?> _deal() => [for (final number in _session.puzzle.numbers) _Card.number(number)];

  // 换题、从头来：先清自己的卡与动画，再交给 session。
  void _reset() {
    hideCampusToast();
    _cards = _deal();
    _history.clear();
    _picked = _op = _pressed = _shaking = null;
    _transition = null;
    _merge.value = 1;
    _shake.value = 0;
    _win.value = 0;
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

  // 点卡：选着「开方」就开这一张；没有第一张就选它，点选着的那张是取消；已有第一张时，选了运算就合，没选运算就改选这一张。
  void _tapCard(int slot) {
    if (_session.finished || _cards[slot] == null) return;
    final picked = _picked, op = _op;
    if (op != null && op.unary) return _apply(TwentyFourStep(slot, op, slot));
    if (picked != null && picked != slot && op != null) return _apply(TwentyFourStep(picked, op, slot));
    playTick();
    _session.moved();
    setState(() => _picked = picked == slot ? null : slot);
  }

  // 点运算：开方在有选着的卡时直接开它；其余的选上，再点一次取消。只剩一张卡时只有开方可点。
  void _tapOp(TwentyFourOp op) {
    if (_session.finished || (!op.unary && _left.length < 2)) return;
    final picked = _picked;
    if (op.unary && picked != null) return _apply(TwentyFourStep(picked, op, picked));
    playTick();
    _session.moved();
    setState(() => _op = _op == op ? null : op);
  }

  // 做一步（合并或开方）。不让做时选着的卡与运算都留着，换一张或换个运算再点。
  void _apply(TwentyFourStep step) {
    final value = twentyFourMerge([for (final card in _cards) card?.value], step);
    if (value == null) return _refuse(step.second, _refusal(step));
    playTick();
    hideCampusToast();
    _session.moved();
    final before = [..._cards];
    final card = _Card.merged(before[step.first]!, step.op, before[step.second]!, value);
    setState(() {
      _history.add((before: before, step: step));
      _cards = [...before]
        ..[step.first] = null
        ..[step.second] = card;
      _transition = (before: before, after: _cards, step: step);
      // 开完的卡仍选着，接着就能和别的卡合；合完两张都不选。
      _picked = step.op.unary ? step.second : null;
      _op = _shaking = null;
    });
    final merging = _animateMerge(forward: true);
    if (_left.length > 1) return;
    if (value == twentyFourTarget) {
      unawaited(_finish(card, merging));
    } else {
      unawaited(_miss(step.second, value, merging));
    }
  }

  // 不让做：重震、那张卡晃一下（合并时是第二张），提示条写原因。
  void _refuse(int slot, String message) {
    playRejected();
    showCampusToast(context, message);
    setState(() => _shaking = slot);
    if (!_reduced) unawaited(_shake.forward(from: 0));
  }

  // 不让做的原因：界面上只点得出有卡的位置，剩下的就是运算本身不合规（口径同规则里的乘方、开方与结果上限）。
  String _refusal(TwentyFourStep step) {
    final (first, second) = (_cards[step.first]!.value, _cards[step.second]!.value);
    return switch (step.op) {
      TwentyFourOp.root when first.numerator < 0 => '负数不能开方',
      TwentyFourOp.root when first.numerator == 0 || first == TwentyFourValue(1) => '开方后不变',
      TwentyFourOp.root => '开不尽',
      TwentyFourOp.divide when second.numerator == 0 => '不能除以 0',
      TwentyFourOp.power when !second.whole => '指数要是整数',
      TwentyFourOp.power when second.numerator.abs() > twentyFourMaxExponent => '指数要在 −$twentyFourMaxExponent 到 $twentyFourMaxExponent 之间',
      TwentyFourOp.power when first.numerator == 0 => '0 只能做正数次方',
      _ => '结果太大',
    };
  }

  // 剩一张不是 24：不算解开，等合并的过渡走完再晃（中途撤销了就不晃）。
  Future<void> _miss(int slot, TwentyFourValue value, TickerFuture merging) async {
    playRejected();
    showCampusToast(context, '得数是 ${twentyFourText(value)}，不是 24');
    await merging;
    if (!mounted || _left.length != 1) return;
    setState(() => _shaking = slot);
    if (!_reduced) unawaited(_shake.forward(from: 0));
  }

  void _undo() {
    if (_history.isEmpty || _session.finished) return;
    playTick();
    hideCampusToast();
    final (:before, :step) = _history.removeLast();
    setState(() {
      _transition = (before: before, after: _cards, step: step);
      _cards = before;
      _picked = _op = _shaking = null;
    });
    unawaited(_animateMerge(forward: false));
  }

  // 播合并的过渡（撤销时倒着播）；减少动画时直接到位。
  TickerFuture _animateMerge({required bool forward}) {
    if (_reduced) {
      _merge.value = forward ? 1 : 0;
      return TickerFuture.complete();
    }
    return forward ? _merge.forward(from: 0) : _merge.reverse(from: 1);
  }

  // 解开：停表记成绩；等合并走完，那张卡铺上激活色鼓一下，再弹结果（减少动画时直接弹）。中途换题或从头来会停掉动画，这一段就不再往下走。
  Future<void> _finish(_Card card, TickerFuture merging) async {
    final newBest = await _session.finish(answer: [for (final entry in _history) entry.step]);
    await merging;
    if (!mounted) return;
    if (_reduced) {
      _win.value = 1;
    } else {
      await _win.forward(from: 0);
    }
    if (!mounted) return;
    final choice = await showPlayResult(context, session: _session, newBest: newBest, detail: '${card.expression} = 24');
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

  // ---------- 画面 ----------

  @override
  Widget build(BuildContext context) => PlayFrame(
    session: _session,
    onNewGame: _newGame,
    onRestart: _restart,
    status: '剩 ${_left.length} 张',
    controls: [
      FilledButton.icon(onPressed: _history.isEmpty || _session.finished ? null : _undo, icon: const CampusIcon(CampusIcons.undo), label: const Text('撤销')),
    ],
    board: LayoutBuilder(builder: _board),
  );

  Widget _board(BuildContext context, BoxConstraints constraints) {
    final palette = CampusPalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final width = math.min(constraints.maxWidth, 440.0);
    // 运算键：一行放得下（每个键不窄于 _keyMin）就一行，放不下平分两行（六个键在 360dp 上是三个一行）。
    final ops = [for (final op in TwentyFourOp.values) if (_session.puzzle.ops.contains(op)) op];
    final perRow = (width - (ops.length - 1) * _gap) / ops.length >= _keyMin ? ops.length : (ops.length / 2).ceil();
    final rows = [for (var start = 0; start < ops.length; start += perRow) ops.sublist(start, math.min(start + perRow, ops.length))];
    final keyWidth = math.min(76.0, (width - (perRow - 1) * _gap) / perRow);
    final keys = rows.length * _keyHeight + (rows.length - 1) * _gap;
    // 算式行留两行高、不缩字：带乘方、开方的算式长，一行放不下就折到第二行。
    final line = scaler.scale(16) * 1.4 * 2;
    // 卡片按剩下的高度定：两行卡、算式行与运算键之间各空 16；卡片不比宽度的八成高（宽屏上不拉得过高）。
    final cardWidth = (width - _gap) / 2;
    final cardHeight = math.max(64.0, math.min((constraints.maxHeight - keys - line - 32 - _gap) / 2, cardWidth * .8));
    final grid = Size(width, cardHeight * 2 + _gap);
    Rect rect(int slot) => Rect.fromLTWH(slot % 2 * (cardWidth + _gap), slot ~/ 2 * (cardHeight + _gap), cardWidth, cardHeight);
    final latest = _history.isEmpty ? null : _cards[_history.last.step.second];
    // 比 360dp 加 1.3 倍字号还挤（更大的字号、更矮的屏幕）时整块等比缩小，不溢出；360dp 加 1.3 倍字号时不缩（测试守住）。
    return Center(child: FittedBox(fit: BoxFit.scaleDown, child: SizedBox(width: width, child: Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox.fromSize(size: grid, child: Stack(clipBehavior: Clip.none, children: [
        // 四个位置的淡边框拼成一条路径画在最底下：卡合走以后空出来的位置露出它。
        Positioned.fill(child: CustomPaint(painter: _SlotsPainter(rects: [for (var slot = 0; slot < twentyFourCards; slot++) rect(slot)], color: palette.outlineSubtle))),
        Positioned.fill(child: AnimatedBuilder(animation: _motion, builder: (context, _) => Stack(clipBehavior: Clip.none, children: _cardLayer(rect)))),
      ])),
      const SizedBox(height: 16),
      SizedBox(
        height: line,
        child: Semantics(
          liveRegion: true,
          excludeSemantics: true,
          label: latest == null ? '' : '${latest.spoken}，等于${twentyFourReading(latest.value)}',
          child: Center(child: Text(
            latest == null ? '' : '${latest.expression} = ${twentyFourText(latest.value)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: palette.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]),
          )),
        ),
      ),
      const SizedBox(height: 16),
      _keys(palette, rows, keyWidth),
    ]))));
  }

  List<Widget> _cardLayer(Rect Function(int slot) rect) {
    final transition = _merge.isAnimating ? _transition : null;
    // 正在合（或撤销）的两个位置由 _blend 画中间帧。
    final blending = transition == null ? const <int>{} : {transition.step.first, transition.step.second};
    final finished = _session.finished;
    final wrong = !finished && _left.length == 1;
    final shake = _shake.isAnimating ? math.sin(_shake.value * math.pi * 5) * 8 * (1 - _shake.value) : 0.0;
    final winning = finished ? Curves.easeOutCubic.transform((_win.value * 2).clamp(0.0, 1.0)) : 0.0;
    final pulse = 1 + .06 * math.sin(_win.value * math.pi);
    return [
      for (var slot = 0; slot < twentyFourCards; slot++)
        if (_cards[slot] case final card? when !blending.contains(slot))
          Positioned.fromRect(
            rect: rect(slot),
            child: Transform.translate(
              offset: Offset(_shaking == slot ? shake : 0, 0),
              child: Transform.scale(
                scale: finished ? pulse : 1,
                child: Semantics(
                  key: ValueKey('twentyfour-card-$slot'),
                  container: true,
                  button: true,
                  selected: _picked == slot,
                  excludeSemantics: true,
                  label: '${twentyFourReading(card.value)}${wrong ? '，不是 24' : ''}',
                  onTap: finished ? null : () => _tapCard(slot),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    excludeFromSemantics: true,
                    onTapDown: (_) => setState(() => _pressed = slot),
                    onTapCancel: () => setState(() => _pressed = null),
                    onTap: () {
                      setState(() => _pressed = null);
                      _tapCard(slot);
                    },
                    child: _CardFace(value: card.value, picked: _picked == slot, pressed: _pressed == slot && !finished, wrong: wrong, glow: winning),
                  ),
                ),
              ),
            ),
          ),
      if (transition != null) ..._blend(transition, rect),
    ];
  }

  // 合并的中间帧（撤销时倒着放）：第二张的位置上旧卡淡出、新卡从九成大小放大淡入；第一张滑向第二张、边走边淡，压在最上面
  // （开方只有前两样：原地换成新值）。都不接点按。
  List<Widget> _blend(({List<_Card?> before, List<_Card?> after, TwentyFourStep step}) transition, Rect Function(int slot) rect) {
    final (:before, :after, :step) = transition;
    final progress = _merge.value;
    final arrive = Curves.easeOutCubic.transform(progress);
    Widget ghost(Rect at, _Card card, double opacity, [double scale = 1]) => Positioned.fromRect(
      rect: at,
      child: IgnorePointer(child: ExcludeSemantics(child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.scale(scale: scale, child: _CardFace(value: card.value)),
      ))),
    );
    return [
      ghost(rect(step.second), before[step.second]!, 1 - progress),
      ghost(rect(step.second), after[step.second]!, arrive, .9 + .1 * arrive),
      if (!step.op.unary)
        ghost(Rect.lerp(rect(step.first), rect(step.second), Curves.easeInOutCubic.transform(progress))!, before[step.first]!, 1 - Curves.easeIn.transform(progress)),
    ];
  }

  // 运算键：色调胶囊，选中的着选中色加细边（同选择标签），按 rows 排一行或两行。二元运算只剩一张时不能点，开方一直能点；解开后都不能点。
  // 运算键是常驻在底部的一排操作，包 CampusToastAnchor：不让做的提示条浮到它上方（盖在算式行那里），不挡住接着要点的键。
  Widget _keys(CampusPalette palette, List<List<TwentyFourOp>> rows, double keyWidth) {
    final finished = _session.finished;
    Widget key(TwentyFourOp op) => MergeSemantics(child: Semantics(
      label: _opNames[op],
      selected: _op == op,
      child: FilledButton(
        style: FilledButton.styleFrom(
          fixedSize: Size(keyWidth, _keyHeight),
          minimumSize: Size(keyWidth, _keyHeight),
          padding: EdgeInsets.zero,
          iconColor: palette.onSurface,
          backgroundBuilder: (context, states, child) => CampusGlassButtonSurface(states: {...states, if (_op == op) WidgetState.selected}, neutral: true, child: child!),
        ),
        onPressed: !finished && (op.unary || _left.length > 1) ? () => _tapOp(op) : null,
        child: CampusIcon(_opIcons[op]!, size: 26),
      ),
    ));
    return CampusToastAnchor(child: Column(mainAxisSize: MainAxisSize.min, children: [
      for (final (index, row) in rows.indexed) ...[
        if (index > 0) const SizedBox(height: _gap),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (final (column, op) in row.indexed) ...[if (column > 0) const SizedBox(width: _gap), key(op)],
        ]),
      ],
    ]));
  }
}

// 卡面：圆角块，中间是数（分数上下叠着写）。点着的描激活色的边、底色换选中色；按着时变暗；剩一张不是 24 时描警示色的边；
// 解开时 glow 从 0 到 1 铺上激活色、字换成激活色上的白字。
class _CardFace extends StatelessWidget {
  const _CardFace({required this.value, this.picked = false, this.pressed = false, this.wrong = false, this.glow = 0});
  final TwentyFourValue value;
  final bool picked, pressed, wrong;
  final double glow;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final base = campusSurfaceFill(context, selected: picked);
    final fill = Color.lerp(pressed ? Color.alphaBlend(palette.onSurface.withValues(alpha: .06), base) : base, palette.accent, glow)!;
    // 激活色底上是白字（配色约定白字对 accent 不低于 4.5:1）；onPrimary 是给文字主色底配的，深色下是深色。
    final ink = Color.lerp(palette.onSurface, Colors.white, glow)!;
    final side = picked
        ? BorderSide(color: palette.accent, width: 2)
        : wrong
        ? BorderSide(color: palette.danger, width: 1.5)
        : BorderSide(color: palette.surfaceBorder);
    final big = TextStyle(fontSize: 40, fontWeight: FontWeight.w600, height: 1.1, color: ink, fontFeatures: const [FontFeature.tabularFigures()]);
    final part = big.copyWith(fontSize: 28);
    final sign = value.numerator < 0 ? '−' : '';
    return AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 120),
      decoration: ShapeDecoration(color: fill, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: side)),
      padding: const EdgeInsets.all(8),
      child: Center(child: FittedBox(
        fit: BoxFit.scaleDown,
        child: value.whole
            ? Text('$sign${value.numerator.abs()}', style: big)
            : Row(mainAxisSize: MainAxisSize.min, children: [
                if (sign.isNotEmpty) Text(sign, style: part),
                IntrinsicWidth(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('${value.numerator.abs()}', style: part, textAlign: TextAlign.center),
                  Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: SizedBox(height: 2.5, child: ColoredBox(color: ink))),
                  Text('${value.denominator}', style: part, textAlign: TextAlign.center),
                ])),
              ]),
      )),
    );
  }
}

// 四个位置的淡边框（卡片底下）：拼成一条路径一次画完。
class _SlotsPainter extends CustomPainter {
  const _SlotsPainter({required this.rects, required this.color});
  final List<Rect> rects;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    for (final rect in rects) {
      path.addRRect(RRect.fromRectAndRadius(rect.deflate(.5), const Radius.circular(20)));
    }
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color);
  }

  @override
  bool shouldRepaint(_SlotsPainter old) => old.color != color || !old.rects.indexed.every((entry) => rects[entry.$1] == entry.$2);
}
