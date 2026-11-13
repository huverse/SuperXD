import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/balance/balance_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 天平称球对局页：上面一架天平，下面桌上排着编号的球（每个球在桌上有固定的位置，拿走后留一个空圈，不挪别人）。
// 底部分段选「放左盘 / 放右盘 / 做记号」：点桌上的球放进选中的盘，点盘里的球拿回桌上；做记号时点球轮换自己的记号（不自动替玩家排除）。
// 「称一下」：两边有一边空着或球数不一样就不称，轻震、天平晃一下、提示条写原因；称了天平倾斜（减少动画时直接到位），
// 下方记一行结果，停一会儿球回到桌上、天平回平。「指认」进入指认：点一个球（要说轻重的档再选偏重或偏轻）确认，
// 只有剩下的候选恰好就是它才解开；还确定不了或和称的结果对不上就轻震并提示。没有撤销：称的次数就是这道题的限制，放错的球点一下就拿回来了。
class BalancePage extends StatefulWidget {
  const BalancePage({super.key, required this.game, required this.store, this.seeds});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;

  @override
  State<BalancePage> createState() => _BalancePageState();
}

// 点球做什么：放左盘、放右盘、做记号。
enum _Tool { left, right, mark }

// 自己做的记号（只在本页，不进答案）：可能偏重、可能偏轻、好球。
enum _Mark { none, heavy, light, good }

// 天平最多斜多少（左边沉为正）。
const _maxAngle = 7 * math.pi / 180;

class _BalancePageState extends State<BalancePage> with TickerProviderStateMixin {
  static const _rules = BalanceRules();
  late final _session = PlaySession<BalancePuzzle, BalanceAnswer>(game: widget.game, rules: _rules, store: widget.store, seeds: widget.seeds);
  // 两盘里的球，按放进去的先后。
  final _pans = [<int>[], <int>[]];
  var _tool = _Tool.left;
  final _records = <({BalanceWeighing weighing, BalanceTilt tilt})>[];
  late BalanceSuspects _suspects = balanceStart(_puzzle);
  late var _marks = List.filled(_puzzle.balls, _Mark.none);
  // 指认：选中的球与偏重 true、偏轻 false（还没选是 null）；解开后的那个球。
  var _guessing = false;
  int? _guess, _found;
  bool? _guessHeavy;
  var _wrongs = 0;
  // 称的过程中（倾斜、停住、球回桌上之前）不接受操作。
  var _weighing = false;
  // 换题、从头来时加一，称到一半的过程据此不再往下走。
  var _epoch = 0;

  // 天平从 _angleFrom 转到 _angleTo；球在桌上与盘之间走动（起点是改之前显示的位置）；不让称或指认错了晃一下（_shaking 是晃的球，-1 是天平）；
  // 解开后那个球轻轻鼓一下、别的球淡下去。
  late final _beam = AnimationController(vsync: this, duration: const Duration(milliseconds: 480), value: 1);
  double _angleFrom = 0, _angleTo = 0;
  late final _move = AnimationController(vsync: this, duration: const Duration(milliseconds: 220), value: 1);
  final _from = <int, Offset>{};
  late final _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 360));
  int? _shaking;
  late final _cheer = AnimationController(vsync: this, duration: const Duration(milliseconds: 620));
  late final _motion = Listenable.merge([_beam, _move, _shake, _cheer]);
  final _scroll = ScrollController();
  int? _pressed;
  _BalanceLayout? _layout;

  @override
  void dispose() {
    _beam.dispose();
    _move.dispose();
    _shake.dispose();
    _cheer.dispose();
    _scroll.dispose();
    _session.dispose();
    super.dispose();
  }

  BalancePuzzle get _puzzle => _session.puzzle;
  bool get _reduced => MediaQuery.disableAnimationsOf(context);
  bool get _busy => _session.finished || _weighing;
  int get _perSide => _puzzle.balls ~/ 2;
  bool get _usedUp => _records.length >= _puzzle.weighings;

  void _reset() {
    hideCampusToast();
    _epoch++;
    for (final pan in _pans) {
      pan.clear();
    }
    _records.clear();
    _suspects = balanceStart(_puzzle);
    _marks = List.filled(_puzzle.balls, _Mark.none);
    _tool = _Tool.left;
    _guessing = false;
    _guess = _found = _guessHeavy = _shaking = _pressed = null;
    _wrongs = 0;
    _weighing = false;
    _from.clear();
    _angleFrom = _angleTo = 0;
    _beam.value = 1;
    _move.value = 1;
    _shake.value = 0;
    _cheer.value = 0;
  }

  void _newGame(PuzzleTier? tier) {
    setState(() {
      _session.next(tier: tier);
      _reset();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _restart() => setState(() {
    _session.restart();
    _reset();
  });

  // 从头播一段；减少动画时直接到位。
  TickerFuture _play(AnimationController controller) {
    if (_reduced) {
      controller.value = 1;
      return TickerFuture.complete();
    }
    return controller.forward(from: 0);
  }

  // ---------- 局面 ----------

  // 球在哪：0 左盘、1 右盘、null 桌上。
  int? _panOf(int ball) => _pans[0].contains(ball) ? 0 : _pans[1].contains(ball) ? 1 : null;

  double get _wobble => _shaking == -1 && _shake.isAnimating ? math.sin(_shake.value * math.pi * 5) * .05 * (1 - _shake.value) : 0;

  double get _angle => _angleFrom + (_angleTo - _angleFrom) * Curves.easeOutCubic.transform(_beam.value) + _wobble;

  Offset _target(_BalanceLayout layout, int ball) {
    final pan = _panOf(ball);
    final shake = _shaking == ball && _shake.isAnimating ? math.sin(_shake.value * math.pi * 5) * 6 * (1 - _shake.value) : 0.0;
    final at = pan == null ? layout.tableSlot(ball) : layout.panSlot(pan, _pans[pan].indexOf(ball), _pans[pan].length, _angle);
    return at + Offset(shake, 0);
  }

  Offset _shown(_BalanceLayout layout, int ball) {
    final target = _target(layout, ball);
    final from = _from[ball];
    if (from == null || _move.value >= 1) return target;
    return Offset.lerp(from, target, Curves.easeOutCubic.transform(_move.value))!;
  }

  // 改局面并让换了位置的球走过去：起点是改之前显示的位置（上一段没走完的从半路接着走）。
  void _shift(VoidCallback change) {
    final layout = _layout;
    final before = [for (var ball = 0; ball < _puzzle.balls; ball++) layout == null ? null : _shown(layout, ball)];
    change();
    _from.clear();
    if (layout == null) return;
    for (final (ball, at) in before.indexed) {
      if (at != null && (at - _target(layout, ball)).distance > .5) _from[ball] = at;
    }
    unawaited(_play(_move));
  }

  // ---------- 操作 ----------

  void _tap(int ball) {
    if (_busy) return;
    if (_guessing) return _pick(ball);
    if (_tool == _Tool.mark) return _cycleMark(ball);
    final pan = _panOf(ball);
    if (pan == null) {
      final target = _tool == _Tool.left ? 0 : 1;
      if (_usedUp) return _refuse(ball, '${_puzzle.weighings} 次都称过了，点「指认」');
      if (_pans[target].length >= _perSide) return _refuse(ball, '一边最多放 $_perSide 个');
    }
    _stepped();
    setState(() => _shift(() {
      if (pan == null) {
        _pans[_tool == _Tool.left ? 0 : 1].add(ball);
      } else {
        _pans[pan].remove(ball);
      }
    }));
  }

  // 一步正常的操作：选择触感、开始计时，收起已经过时的提示（不让它停在屏幕上像是在说这一步）。
  void _stepped() {
    playTick();
    hideCampusToast();
    _session.moved();
  }

  void _cycleMark(int ball) {
    _stepped();
    final next = _puzzle.knownHeavy
        ? (_marks[ball] == _Mark.good ? _Mark.none : _Mark.good)
        : _Mark.values[(_marks[ball].index + 1) % _Mark.values.length];
    setState(() => _marks[ball] = next);
  }

  void _refuse(int ball, String message) {
    playRejected();
    showCampusToast(context, message);
    setState(() => _shaking = ball);
    if (!_reduced) unawaited(_shake.forward(from: 0));
  }

  Future<void> _weigh() async {
    if (_busy || _guessing) return;
    final left = [..._pans[0]]..sort(), right = [..._pans[1]]..sort();
    switch (balanceFault(_puzzle, left, right)) {
      case BalanceFault.empty:
        return _refuse(-1, '两边都要放球');
      case BalanceFault.uneven:
        return _refuse(-1, '两边的球数要一样：左边 ${left.length} 个，右边 ${right.length} 个');
      case BalanceFault.invalid:
        return;
      case null:
        break;
    }
    _stepped();
    final (leftMask, rightMask) = (balanceMask(left), balanceMask(right));
    final tilt = balanceRespond(_puzzle, _suspects, leftMask, rightMask, _records.length);
    final epoch = _epoch;
    final from = _angle;
    setState(() {
      _records.add((weighing: BalanceWeighing(left, right), tilt: tilt));
      _suspects = balanceSplit(_suspects, leftMask, rightMask)[tilt.index];
      _weighing = true;
      _shaking = null;
      _angleFrom = from;
      _angleTo = switch (tilt) {
        BalanceTilt.left => _maxAngle,
        BalanceTilt.right => -_maxAngle,
        BalanceTilt.level => 0,
      };
    });
    // 倾斜，停一会儿让人看清，再把球拿回桌上、天平回平。减少动画时直接斜到位，停得久一点。
    await _play(_beam);
    await Future<void>.delayed(Duration(milliseconds: _reduced ? 900 : 650));
    if (!mounted || epoch != _epoch) return;
    final angle = _angle;
    setState(() {
      _shift(() {
        for (final pan in _pans) {
          pan.clear();
        }
      });
      _angleFrom = angle;
      _angleTo = 0;
      _weighing = false;
    });
    unawaited(_play(_beam));
  }

  void _startGuess() {
    if (_busy) return;
    _stepped();
    setState(() {
      _guessing = true;
      _guess = null;
      _guessHeavy = null;
    });
  }

  void _cancelGuess() {
    if (_session.finished) return;
    playTick();
    hideCampusToast();
    setState(() => _guessing = false);
  }

  void _pick(int ball) {
    if (_guess == ball) return;
    _stepped();
    setState(() => _guess = ball);
  }

  void _chooseHeavy(bool? heavy) {
    _stepped();
    setState(() => _guessHeavy = heavy);
  }

  bool get _guessReady => _guess != null && (!_puzzle.direction || _guessHeavy != null);

  void _confirm() {
    if (_busy || !_guessReady) return;
    final ball = _guess!, heavy = _puzzle.direction ? _guessHeavy : null;
    _session.moved();
    final verdict = balanceVerdict(_puzzle, _suspects, ball, heavy);
    if (verdict == BalanceVerdict.solved) {
      playTick();
      hideCampusToast();
      unawaited(_finish(ball));
      return;
    }
    _wrongs++;
    final name = '${ball + 1} 号${heavy == null ? '' : heavy ? '偏重' : '偏轻'}';
    final message = verdict == BalanceVerdict.contradicts
        ? '$name和称的结果对不上'
        : _usedUp
        ? '还确定不了。${_puzzle.weighings} 次都称过了，可以从⋯里「这一题从头来」'
        : '还确定不了';
    _refuse(ball, message);
    // 还能称就回到称球，次数用完了留在指认里（可以换一个再试）。
    setState(() {
      _guess = null;
      _guessHeavy = null;
      _guessing = _usedUp;
    });
  }

  // 解开：停表记成绩；那个球轻轻鼓一下、别的球淡下去，再弹结果。减少动画时直接弹。中途换题或从头来就不再往下走。
  Future<void> _finish(int ball) async {
    final epoch = _epoch;
    final newBest = await _session.finish(moves: _records.length);
    if (!mounted || epoch != _epoch) return;
    setState(() {
      _guessing = false;
      _found = ball;
    });
    await _play(_cheer);
    if (!mounted || epoch != _epoch) return;
    final weighed = _records.length;
    final choice = await showPlayResult(context, session: _session, newBest: newBest, detail: '称 $weighed 次 · ${_wrongs == 0 ? '一次指认就对' : '指认错 $_wrongs 次'}');
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
  Widget build(BuildContext context) {
    final finished = _session.finished;
    final status = ['称了 ${_records.length}/${_puzzle.weighings} 次', if (_guessing) '点一个球指认'].join(' · ');
    return PlayFrame(
      session: _session,
      onNewGame: _newGame,
      onRestart: _restart,
      status: status,
      controls: _guessing ? _guessControls() : _weighControls(finished),
      board: LayoutBuilder(builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        final width = math.min(constraints.maxWidth, _BalanceLayout.maxWidth);
        final cached = _layout;
        final layout = cached != null && cached.puzzle == _puzzle && cached.width == width && cached.scale == scaler.scale(16) ? cached : _layout = _BalanceLayout(_puzzle, width, scaler);
        return CampusScrollFade(child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.only(bottom: 4),
          child: Center(child: SizedBox(width: width, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _Brief(puzzle: _puzzle),
            const SizedBox(height: 12),
            _scene(context, layout),
            if (_records.isNotEmpty) ...[const SizedBox(height: 16), _Records(records: _records)],
          ]))),
        ));
      }),
    );
  }

  List<Widget> _weighControls(bool finished) => [
    SizedBox(width: 264, child: CampusSegmented<_Tool>(
      values: _Tool.values,
      label: (tool) => switch (tool) {
        _Tool.left => '放左盘',
        _Tool.right => '放右盘',
        _Tool.mark => '做记号',
      },
      selected: _tool,
      onSelected: finished ? null : (tool) => setState(() => _tool = tool),
    )),
    FilledButton.icon(onPressed: finished || _weighing ? null : _startGuess, icon: const CampusIcon(CampusIcons.search), label: const Text('指认')),
    FilledButton.icon(
      style: campusProminent,
      onPressed: finished || _weighing || _usedUp || _pans.every((pan) => pan.isEmpty) ? null : _weigh,
      icon: const CampusIcon(CampusIcons.balance),
      label: const Text('称一下'),
    ),
  ];

  List<Widget> _guessControls() {
    final palette = CampusPalette.of(context);
    return [
      if (_puzzle.direction)
        Wrap(spacing: 8, runSpacing: 8, children: [
          CampusGlassChip(
            label: '偏重',
            selected: _guessHeavy == true,
            leading: CampusIcon(CampusIcons.arrowDown, size: 18, color: palette.onSurfaceVariant),
            onSelected: (selected) => _chooseHeavy(selected ? true : null),
          ),
          CampusGlassChip(
            label: '偏轻',
            selected: _guessHeavy == false,
            leading: CampusIcon(CampusIcons.arrowUp, size: 18, color: palette.onSurfaceVariant),
            onSelected: (selected) => _chooseHeavy(selected ? false : null),
          ),
        ]),
      FilledButton.icon(onPressed: _cancelGuess, icon: const CampusIcon(CampusIcons.close), label: const Text('取消')),
      FilledButton.icon(style: campusProminent, onPressed: _guessReady && !_busy ? _confirm : null, icon: const CampusIcon(CampusIcons.check), label: const Text('确认')),
    ];
  }

  Widget _scene(BuildContext context, _BalanceLayout layout) {
    final palette = CampusPalette.of(context);
    final colors = _BalanceColors.of(palette);
    final numberStyle = TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.1, fontFeatures: const [FontFeature.tabularFigures()]);
    return SizedBox(width: layout.width, height: layout.height, child: AnimatedBuilder(animation: _motion, builder: (context, _) {
      final angle = _angle;
      final onTable = [for (var ball = 0; ball < _puzzle.balls; ball++) _panOf(ball) == null];
      final cheer = _found == null ? 0.0 : _cheer.value;
      return Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(child: CustomPaint(painter: _ScenePainter(layout: layout, colors: colors, angle: angle, onTable: onTable))),
        Positioned(left: 0, top: 0, width: layout.width, height: layout.scaleHeight, child: Semantics(label: _scaleLabel(), child: const SizedBox.expand())),
        for (var ball = 0; ball < _puzzle.balls; ball++)
          () {
            final at = _shown(layout, ball);
            final where = switch (_panOf(ball)) {
              0 => '在左盘',
              1 => '在右盘',
              _ => '在桌上',
            };
            final mark = switch (_marks[ball]) {
              _Mark.none => '',
              _Mark.heavy => '，记号：可能偏重',
              _Mark.light => '，记号：可能偏轻',
              _Mark.good => '，记号：好球',
            };
            final found = _found == ball;
            return Positioned(
              key: ValueKey(ball),
              left: at.dx - layout.slot / 2,
              top: at.dy - layout.slot / 2,
              width: layout.slot,
              height: layout.slot,
              child: Semantics(
                button: true,
                selected: _guessing ? _guess == ball : null,
                label: '${ball + 1} 号球，$where$mark${found ? '，就是它' : ''}',
                onTap: _busy ? null : () => _tap(ball),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  excludeFromSemantics: true,
                  onTapDown: (_) => setState(() => _pressed = ball),
                  onTapCancel: () => setState(() => _pressed = null),
                  onTap: () {
                    setState(() => _pressed = null);
                    _tap(ball);
                  },
                  child: ExcludeSemantics(child: Center(child: _BallFace(
                    number: ball + 1,
                    diameter: layout.ball,
                    colors: colors,
                    style: numberStyle,
                    mark: _marks[ball],
                    pressed: _pressed == ball,
                    chosen: _guessing && _guess == ball,
                    found: found,
                    pulse: found ? cheer : 0,
                    faded: _found != null && !found ? cheer : 0,
                  ))),
                ),
              ),
            );
          }(),
      ]);
    }));
  }

  String _scaleLabel() {
    String pan(int side) => _pans[side].isEmpty ? '空着' : '有 ${([..._pans[side]]..sort()).map((ball) => ball + 1).join('、')} 号';
    return '天平：左盘${pan(0)}，右盘${pan(1)}';
  }
}

// 天平上方写这一道的规矩（「玩法」里是总的说明，这里按这一档的参数讲）。
class _Brief extends StatelessWidget {
  const _Brief({required this.puzzle});
  final BalancePuzzle puzzle;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final rule = puzzle.knownHeavy
        ? '其中一个比别的重，找出它。'
        : puzzle.direction
        ? '其中一个重量不同，不知道偏轻还是偏重。找出它，并说出它偏轻还是偏重。'
        : '其中一个重量不同，不知道偏轻还是偏重。找出它就行，不用说轻重。';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${puzzle.balls} 个球，最多称 ${puzzle.weighings} 次', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.4, color: palette.onSurface)),
      const SizedBox(height: 2),
      BalancedText(rule, style: TextStyle(fontSize: 14, height: 1.43, color: palette.onSurfaceVariant)),
    ]);
  }
}

// 每次称的记录：「1  左 1 2 3 · 右 4 5 6 → 左边重」，读屏读成一句。
class _Records extends StatelessWidget {
  const _Records({required this.records});
  final List<({BalanceWeighing weighing, BalanceTilt tilt})> records;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final style = TextStyle(fontSize: 14, height: 1.43, color: palette.onSurface, fontFeatures: const [FontFeature.tabularFigures()]);
    String balls(List<int> list) => list.map((ball) => ball + 1).join(' ');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (index, (:weighing, :tilt)) in records.indexed) ...[
        if (index > 0) const SizedBox(height: 8),
        Semantics(
          container: true,
          label: '第 ${index + 1} 次：左盘 ${weighing.left.map((ball) => ball + 1).join('、')} 号，右盘 ${weighing.right.map((ball) => ball + 1).join('、')} 号，${balanceTiltName(tilt)}',
          child: ExcludeSemantics(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              constraints: BoxConstraints(minWidth: MediaQuery.textScalerOf(context).scale(14) * 1.43),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(color: palette.surfaceSelected, borderRadius: BorderRadius.circular(10)),
              alignment: Alignment.center,
              child: Text('${index + 1}', style: style.copyWith(color: palette.onSurfaceVariant)),
            ),
            const SizedBox(width: 10),
            Expanded(child: DotSeparatedText('左 ${balls(weighing.left)} · 右 ${balls(weighing.right)} → ${balanceTiltName(tilt)}', style: style)),
          ])),
        ),
      ],
    ]);
  }
}

String balanceTiltName(BalanceTilt tilt) => switch (tilt) {
  BalanceTilt.left => '左边重',
  BalanceTilt.right => '右边重',
  BalanceTilt.level => '平衡',
};

// 场景几何：上面是天平（中间立柱，横梁两头吊着盘，盘里的球按格从下往上排），下面隔一段是桌面（每个球一个固定的格，几排居中）。
// 球的格（触区）至少 48，跟着字号放大；一个盘放不下三列就排两列（360 宽加 1.3 倍字号时是两列三排）。
class _BalanceLayout {
  factory _BalanceLayout(BalancePuzzle puzzle, double width, TextScaler scaler) {
    final ball = math.max(40.0, scaler.scale(16) + 22);
    final slot = math.max(48.0, ball + 6);
    final perSide = math.max(1, puzzle.balls ~/ 2);
    var columns = math.min(3, perSide);
    while (columns > 1 && 2 * (columns * slot + 2 * _panPad) + _postGap > width) {
      columns--;
    }
    final stack = (perSide / columns).ceil() * slot;
    final pan = columns * slot + 2 * _panPad;
    final arm = width / 2 - pan / 2 - 2;
    // 盘沉到最低时盘底再往下留出盘的深度，下面是底座。
    final footY = _top + arm * math.sin(_maxAngle) + _hang + stack + _dish + 6;
    final scaleHeight = footY + _foot + 4;
    final tableColumns = math.max(1, ((width - 2 * _tablePad) / slot).floor());
    final tableRows = (puzzle.balls / tableColumns).ceil();
    final perRow = (puzzle.balls / tableRows).ceil();
    final tableTop = scaleHeight + _gap;
    return _BalanceLayout._(
      puzzle: puzzle,
      width: width,
      scale: scaler.scale(16),
      ball: ball,
      slot: slot,
      columns: columns,
      stack: stack,
      pan: pan,
      arm: arm,
      footY: footY,
      scaleHeight: scaleHeight,
      perRow: perRow,
      tableTop: tableTop,
      tableHeight: tableRows * slot + 2 * _tablePad,
    );
  }

  _BalanceLayout._({
    required this.puzzle,
    required this.width,
    required this.scale,
    required this.ball,
    required this.slot,
    required this.columns,
    required this.stack,
    required this.pan,
    required this.arm,
    required this.footY,
    required this.scaleHeight,
    required this.perRow,
    required this.tableTop,
    required this.tableHeight,
  });

  static const maxWidth = 480.0;
  // 盘两边的留白、两盘之间给立柱留的空、横梁离顶、吊绳长、盘的深度、底座厚、天平与桌面的间距、桌面内边距。
  static const _panPad = 6.0, _postGap = 16.0, _top = 18.0, _hang = 22.0, _dish = 9.0, _foot = 8.0, _gap = 14.0, _tablePad = 8.0;

  final BalancePuzzle puzzle;
  // stack 是盘里球堆的高度（排数 × 格），footY 是底座的高度。
  final double width, scale, ball, slot, stack, pan, arm, footY, scaleHeight, tableTop, tableHeight;
  final int columns, perRow;

  double get height => tableTop + tableHeight;
  Offset get pivot => Offset(width / 2, _top);
  double get rimHeight => _dish;

  // 横梁两头（side 0 左、1 右）：左边沉 angle 为正。
  Offset end(int side, double angle) => pivot + Offset((side == 0 ? -1 : 1) * arm * math.cos(angle), (side == 0 ? 1 : -1) * arm * math.sin(angle));

  // 盘面（球底所在的高度）的中心：吊在横梁那一头下面。
  Offset dish(int side, double angle) => end(side, angle) + Offset(0, _hang + stack);

  // 盘里第 index 个球（共 count 个）的中心：从下往上一排排放，每排居中。
  Offset panSlot(int side, int index, int count, double angle) {
    final base = dish(side, angle);
    final row = index ~/ columns, inRow = math.min(columns, count - row * columns);
    return base + Offset((index % columns - (inRow - 1) / 2) * slot, -(row + .5) * slot);
  }

  // 桌上第 ball 个球的固定格。
  Offset tableSlot(int ball) {
    final row = ball ~/ perRow, inRow = math.min(perRow, puzzle.balls - row * perRow);
    return Offset(width / 2 + (ball % perRow - (inRow - 1) / 2) * slot, tableTop + _tablePad + (row + .5) * slot);
  }
}

// 配色全从当前配色推出：架子是次要文字色压淡的金属灰，盘是卡片色带一点灰，桌面同选中底；球是卡片色带一点激活色、字用正文色。
class _BalanceColors {
  _BalanceColors._(this.palette) {
    final dark = palette.isDark;
    frame = Color.lerp(palette.onSurfaceVariant, palette.surface, dark ? .3 : .22)!;
    dishFill = Color.lerp(palette.surface, palette.onSurfaceVariant, dark ? .24 : .14)!;
    strings = palette.onSurfaceVariant.withValues(alpha: dark ? .5 : .42);
    table = palette.surfaceSelected.withValues(alpha: dark ? .55 : .6);
    hole = palette.outline.withValues(alpha: dark ? .55 : .5);
    ballFill = Color.lerp(palette.surface, palette.accent, dark ? .3 : .17)!;
    ballEdge = Color.lerp(palette.surface, palette.accent, dark ? .55 : .42)!;
    goodFill = Color.lerp(palette.surface, palette.surfaceSelected, .7)!;
    shadow = Colors.black.withValues(alpha: dark ? .35 : .12);
  }

  static final _cache = Expando<_BalanceColors>();
  static _BalanceColors of(CampusPalette palette) => _cache[palette] ??= _BalanceColors._(palette);

  final CampusPalette palette;
  late final Color frame, dishFill, strings, table, hole, ballFill, ballEdge, goodFill, shadow;
}

// 天平与桌面：立柱、底座与横梁拼成一条路径，吊绳一条路径，两个盘一条路径；桌面一块圆角底，被拿走的球留下的空圈拼成一条路径。
class _ScenePainter extends CustomPainter {
  _ScenePainter({required this.layout, required this.colors, required this.angle, required this.onTable});
  final _BalanceLayout layout;
  final _BalanceColors colors;
  final double angle;
  final List<bool> onTable;

  @override
  void paint(Canvas canvas, Size size) {
    final pivot = layout.pivot, footY = layout.footY;
    final frame = Path()
      ..addRRect(RRect.fromRectAndRadius(Rect.fromLTRB(pivot.dx - 4, pivot.dy, pivot.dx + 4, footY), const Radius.circular(3)))
      ..addRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(pivot.dx, footY + 4), width: layout.width * .3, height: 8), const Radius.circular(4)))
      ..addOval(Rect.fromCircle(center: pivot, radius: 7));
    // 指针：从支点朝上，跟着横梁一起斜。
    final needle = Offset(-math.sin(angle), -math.cos(angle)) * 14;
    final left = layout.end(0, angle), right = layout.end(1, angle);
    final beam = Path()
      ..moveTo(left.dx, left.dy)
      ..lineTo(right.dx, right.dy)
      ..moveTo(pivot.dx, pivot.dy)
      ..lineTo(pivot.dx + needle.dx, pivot.dy + needle.dy);
    final strings = Path(), dishes = Path();
    for (final side in [0, 1]) {
      final top = layout.end(side, angle), dish = layout.dish(side, angle), half = layout.pan / 2;
      strings
        ..moveTo(top.dx, top.dy)
        ..lineTo(dish.dx - half + 4, dish.dy)
        ..moveTo(top.dx, top.dy)
        ..lineTo(dish.dx + half - 4, dish.dy);
      dishes
        ..moveTo(dish.dx - half, dish.dy)
        ..quadraticBezierTo(dish.dx, dish.dy + layout.rimHeight * 2, dish.dx + half, dish.dy)
        ..close();
    }
    canvas.drawPath(strings, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = colors.strings);
    canvas.drawPath(frame, Paint()..color = colors.frame);
    canvas.drawPath(beam, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..color = colors.frame);
    canvas.drawPath(dishes, Paint()..color = colors.dishFill);
    canvas.drawPath(dishes, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = colors.frame);
    final table = Rect.fromLTWH(0, layout.tableTop, layout.width, layout.tableHeight);
    canvas.drawRRect(RRect.fromRectAndRadius(table, const Radius.circular(20)), Paint()..color = colors.table);
    final holes = Path();
    for (final (ball, here) in onTable.indexed) {
      if (!here) holes.addOval(Rect.fromCircle(center: layout.tableSlot(ball), radius: layout.ball / 2 - 2));
    }
    canvas.drawPath(holes, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = colors.hole);
  }

  @override
  bool shouldRepaint(_ScenePainter old) => old.angle != angle || !identical(old.layout, layout) || !identical(old.colors, colors) || !_same(old.onTable, onTable);

  static bool _same(List<bool> first, List<bool> second) => first.length == second.length && first.indexed.every((entry) => second[entry.$1] == entry.$2);
}

// 一个球：圆形淡底、编号；自己的记号在右上角挂个小角标（可能偏重是向下的箭头、可能偏轻向上、好球是勾，球也淡下去）；
// 按下变暗；指认时选中的描一圈激活色；解开后那个球换成激活色鼓一下，别的球淡下去。
class _BallFace extends StatelessWidget {
  const _BallFace({
    required this.number,
    required this.diameter,
    required this.colors,
    required this.style,
    required this.mark,
    required this.pressed,
    required this.chosen,
    required this.found,
    required this.pulse,
    required this.faded,
  });
  final int number;
  final double diameter, pulse, faded;
  final _BalanceColors colors;
  final TextStyle style;
  final _Mark mark;
  final bool pressed, chosen, found;

  @override
  Widget build(BuildContext context) {
    final palette = colors.palette;
    final good = mark == _Mark.good && !found;
    var fill = found ? palette.accent : good ? colors.goodFill : colors.ballFill;
    if (pressed) fill = Color.lerp(fill, palette.onSurface, palette.isDark ? .12 : .08)!;
    // 激活色底上的白字不低于 4.5:1（见 CampusPalette.accent）。
    final ink = found ? Colors.white : good ? palette.onSurfaceVariant : palette.onSurface;
    final badge = switch (mark) {
      _Mark.none => null,
      _Mark.heavy => CampusIcons.arrowDown,
      _Mark.light => CampusIcons.arrowUp,
      _Mark.good => CampusIcons.check,
    };
    final grow = 1 + .18 * math.sin(pulse * math.pi);
    return Opacity(
      opacity: 1 - .55 * faded,
      child: Transform.scale(
        scale: grow,
        child: SizedBox.square(dimension: diameter, child: Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fill,
              border: Border.all(color: chosen ? palette.accent : good ? palette.outlineSubtle : colors.ballEdge, width: chosen ? 3 : 1.2),
              boxShadow: [BoxShadow(color: colors.shadow, blurRadius: 4, offset: const Offset(0, 1.5))],
            ),
            child: Center(child: Padding(
              padding: const EdgeInsets.all(3),
              child: FittedBox(fit: BoxFit.scaleDown, child: Text('$number', style: style.copyWith(color: ink))),
            )),
          )),
          if (badge != null)
            Positioned(
              right: -5,
              top: -5,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(shape: BoxShape.circle, color: palette.surface, border: Border.all(color: palette.outlineSubtle)),
                alignment: Alignment.center,
                child: CampusIcon(badge, size: 13, color: palette.onSurfaceVariant),
              ),
            ),
        ])),
      ),
    );
  }
}
