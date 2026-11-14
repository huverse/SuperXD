import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/playground/challenge/play_challenge.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/logicgrid/logicgrid_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 一个引用说成句子里的几种成分（题面只存结构）：谓语「养猫」「是甲」、主语「养猫的」「甲」、宾语「养猫的人」「甲」。
String _predicate(LogicGridPuzzle puzzle, LogicGridRef ref) {
  if (ref.category == 0) return '是${logicGridPeople[ref.value]}';
  final category = puzzle.categories[ref.category - 1];
  return '${category.pool.verb}${category.label(ref.value)}';
}

String _subject(LogicGridPuzzle puzzle, LogicGridRef ref) => ref.category == 0 ? logicGridPeople[ref.value] : '${_predicate(puzzle, ref)}的';

String _object(LogicGridPuzzle puzzle, LogicGridRef ref) => ref.category == 0 ? logicGridPeople[ref.value] : '${_predicate(puzzle, ref)}的人';

// 一条线索按结构说成口语，分成几段，只在段与段之间换行（按字均分会把「养猫的」「左边一位」拆到两行）。
List<String> logicGridPhrases(LogicGridPuzzle puzzle, LogicGridClue clue) {
  final refs = clue.refs;
  final subject = _subject(puzzle, refs[0]);
  return switch (clue.kind) {
    LogicGridClueKind.same => [subject, '${_predicate(puzzle, refs[1])}。'],
    LogicGridClueKind.differ => [subject, '不${_predicate(puzzle, refs[1])}。'],
    LogicGridClueKind.either => [subject, '要么${_predicate(puzzle, refs[1])}，', '要么${_predicate(puzzle, refs[2])}。'],
    LogicGridClueKind.leftOf => ['$subject坐在', '${_object(puzzle, refs[1])}左边一位。'],
    LogicGridClueKind.nextTo => ['$subject挨着', '${_object(puzzle, refs[1])}坐。'],
    LogicGridClueKind.before => ['$subject坐在', '${_object(puzzle, refs[1])}左边，', '不一定挨着。'],
  };
}

String logicGridSentence(LogicGridPuzzle puzzle, LogicGridClue clue) => logicGridPhrases(puzzle, clue).join();

// 解开后的收尾：表格一行一行轻轻亮一下 _glowEach，自上而下错开 _glowGap（5 行一共约 0.9 秒）。
const _glowEach = 420, _glowGap = 110;
// 线索区左右伸到页边：判错时线索卡左右晃，不让滚动区的边把它切掉。
const _bleed = 16.0;

// 逻辑网格推理对局页：上面一张表（每行一个人、每列一类属性），下面是可滚动的线索。
// 点表格的一格弹出这一类的全部值：「是」一行点一个就填上（同一类里这个值原来在别人那一格就挪过来），「不是」一行可以标掉几个作排除记号。
// 不用经典的三角排除网格：5 人 4 类有 6 张 5×5 的小表，360dp 宽放不下也读不清；人与属性一张表在手机上一眼看全，排除记号记在格子里。
// 点一条线索标成用过了（变淡），再点取消。全部填满就判：对了表格依次亮一下再弹结果；不对不给答案，只把不成立的线索标警示色并轻震。
class LogicGridPage extends StatefulWidget {
  const LogicGridPage({super.key, required this.game, required this.store, this.seeds, this.challenge});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;
  // 挑战里的一关（题面是服务器给的）；自由模式为空。
  final PlayChallenge? challenge;

  @override
  State<LogicGridPage> createState() => _LogicGridPageState();
}

class _LogicGridPageState extends State<LogicGridPage> with TickerProviderStateMixin {
  static const _rules = LogicGridRules();
  late final _session = PlaySession<LogicGridPuzzle, List<List<int>>>(game: widget.game, rules: _rules, store: widget.store, seeds: widget.seeds, challenge: widget.challenge);
  // _values[c][p]：第 p 个人在第 c 类里填的值（−1 是没填）；_excluded[c][p]：标了「不是」的值（按位）。
  late var _values = _empty(-1);
  late var _excluded = _empty(0);
  // 每一步改了哪些格、改之前的值与排除记号，撤销按步退回。
  final _history = <List<(int, int, int, int)>>[];
  // 标了用过的线索；填满却不成立时不成立的线索（改了任何一格就重新算）。
  var _used = <int>{};
  var _violations = <int>{};
  // 这一局判错过几次（结果里写）。
  var _wrongs = 0;
  late var _clueKeys = _keys();
  final _scroll = ScrollController();
  late final _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  late final _glow = AnimationController(vsync: this);

  @override
  void dispose() {
    _shake.dispose();
    _glow.dispose();
    _scroll.dispose();
    _session.dispose();
    super.dispose();
  }

  LogicGridPuzzle get _puzzle => _session.puzzle;
  bool get _still => MediaQuery.disableAnimationsOf(context);
  List<List<int>> _empty(int fill) => [for (final _ in _puzzle.categories) List.filled(_puzzle.people, fill)];
  List<GlobalKey> _keys() => [for (final _ in _puzzle.clues) GlobalKey()];

  // 换题、从头来：先清自己的记号与动画，再交给 session，最后按新题摆空表。
  void _clear() {
    hideCampusToast();
    _history.clear();
    _used = {};
    _violations = {};
    _wrongs = 0;
    _shake.value = 0;
    _glow.value = 0;
  }

  void _reset() {
    _values = _empty(-1);
    _excluded = _empty(0);
    _clueKeys = _keys();
  }

  void _newGame(PuzzleTier? tier) {
    setState(() {
      _clear();
      _session.next(tier: tier);
      _reset();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _restart() => setState(() {
    _clear();
    _session.restart();
    _reset();
  });

  // ---------- 填表与判定 ----------

  // 一步：记下这几格改之前的样子，改完收起过时的提示、判一次。
  void _commit(List<(int, int)> cells, VoidCallback change) {
    playTick();
    hideCampusToast();
    _session.moved();
    setState(() {
      _history.add([for (final (category, person) in cells) (category, person, _values[category][person], _excluded[category][person])]);
      change();
    });
    _judge(alert: true);
  }

  // 填值（−1 是清空）：同一类里这个值原来在别人那一格就挪过来（那一格变空），这一格对这个值的「不是」一并去掉。
  void _fill(int category, int person, int value) {
    if (_session.finished || _session.judging || _values[category][person] == value) return;
    final holder = value < 0 ? -1 : _values[category].indexOf(value);
    _commit([(category, person), if (holder >= 0) (category, holder)], () {
      if (holder >= 0) _values[category][holder] = -1;
      _values[category][person] = value;
      if (value >= 0) _excluded[category][person] &= ~(1 << value);
    });
  }

  // 标上或取消「不是」：标掉的正好是这一格填的值就一并清空。
  void _exclude(int category, int person, int value) {
    if (_session.finished) return;
    _commit([(category, person)], () {
      _excluded[category][person] ^= 1 << value;
      if (_excluded[category][person] >> value & 1 == 1 && _values[category][person] == value) _values[category][person] = -1;
    });
  }

  void _undo() {
    if (_history.isEmpty || _session.finished) return;
    playTick();
    hideCampusToast();
    setState(() {
      for (final (category, person, value, excluded) in _history.removeLast().reversed) {
        _values[category][person] = value;
        _excluded[category][person] = excluded;
      }
    });
    // 退回到的局面判过了：不成立的照样标出来，不再震。
    _judge(alert: false);
  }

  // 用过的线索只是记号：不算一步、不开始计时、不进撤销。
  void _toggleUsed(int index) {
    playTick();
    setState(() => _used = _used.contains(index) ? ({..._used}..remove(index)) : {..._used, index});
  }

  // 全部填满就按规则判：成立即解开；不成立只标出不成立的线索（题目唯一，所以一定有），alert 时轻震、晃一下、滚到第一条并记一次判错。
  void _judge({required bool alert}) {
    final complete = _values.every((row) => !row.contains(-1));
    if (widget.challenge != null) {
      setState(() => _violations = {});
      if (complete && alert) unawaited(_submit());
      return;
    }
    final violations = complete ? logicGridViolations(_puzzle, _values).toSet() : <int>{};
    setState(() => _violations = violations);
    if (!complete) return;
    if (_rules.solved(_puzzle, _values)) {
      unawaited(_finish());
      return;
    }
    if (!alert) return;
    _wrongs++;
    playRejected();
    showCampusToast(context, '有 ${violations.length} 条线索对不上');
    if (!_still) unawaited(_shake.forward(from: 0));
    final first = _clueKeys[violations.reduce(math.min)].currentContext;
    if (first != null) unawaited(Scrollable.ensureVisible(first, alignment: .5, duration: _still ? Duration.zero : const Duration(milliseconds: 300), curve: Curves.easeOutCubic));
  }

  // 挑战模式：填满就交服务器判（每次判错计一次错交，所以退回的局面不在本机判、不先标）；判错了才标出不成立的线索。
  Future<void> _submit() async {
    final correct = await _session.judge([for (final row in _values) [...row]]);
    if (!mounted) return;
    if (correct == null) return showCampusToast(context, '没交上，连不上服务器；改一格再填满就会重交');
    if (correct) return unawaited(_finish());
    final violations = logicGridViolations(_puzzle, _values).toSet();
    setState(() => _violations = violations);
    _wrongs++;
    playRejected();
    showCampusToast(context, '有 ${violations.length} 条线索对不上');
    if (!_still) unawaited(_shake.forward(from: 0));
  }

  Future<void> _finish() async {
    final newBest = await _session.finish(answer: [for (final row in _values) [...row]]);
    if (!mounted) return;
    // 表格一行一行亮一下，亮完再弹结果；减少动画时直接弹。
    if (!_still) await _glow.animateTo(1, duration: Duration(milliseconds: _glowEach + (_puzzle.people - 1) * _glowGap));
    if (!mounted) return;
    final choice = await showPlayResult(
      context,
      session: _session,
      newBest: newBest,
      detail: '${_puzzle.people} 人 · ${_puzzle.categories.length} 类 · ${_wrongs == 0 ? '一次就对' : '判错 $_wrongs 次'}',
    );
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

  // 点一格：弹层里「是」一行点一个就填上并关掉，再点已填的那个是清空；「不是」一行点了只改记号、弹层不关，可以连着标几个。
  Future<void> _pick(int category, int person) async {
    if (_session.finished) return;
    final group = _puzzle.categories[category];
    final choice = await showCampusSheet<int>(context: context, builder: (context) => StatefulBuilder(builder: (context, setSheet) {
      final palette = CampusPalette.of(context);
      final (value, excluded) = (_values[category][person], _excluded[category][person]);
      final caption = TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: palette.onSurfaceVariant);
      // 两行的值一样，读屏标签带上「是」「不是」才分得开。
      Widget chip(String prefix, int option, bool selected, VoidCallback onTap) => Semantics(
        button: true,
        selected: selected,
        label: '$prefix${group.label(option)}',
        onTap: onTap,
        excludeSemantics: true,
        child: CampusGlassChip(label: group.label(option), selected: selected, onSelected: (_) => onTap()),
      );
      return CampusSheetPanel(child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 8, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(child: Text('${logicGridPeople[person]} · ${group.pool.name}', style: Theme.of(context).textTheme.titleLarge)),
            IconButton(tooltip: '关闭', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.close)),
          ]),
          const SizedBox(height: 8),
          Text('是', style: caption),
          const SizedBox(height: 8),
          Padding(padding: const EdgeInsets.only(right: 12), child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (var option = 0; option < _puzzle.people; option++)
              chip('是', option, value == option, () => Navigator.pop(context, value == option ? -1 : option)),
          ])),
          const SizedBox(height: 16),
          Text('不是', style: caption),
          const SizedBox(height: 8),
          Padding(padding: const EdgeInsets.only(right: 12), child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (var option = 0; option < _puzzle.people; option++)
              chip('不是', option, excluded >> option & 1 == 1, () {
                _exclude(category, person, option);
                setSheet(() {});
              }),
          ])),
        ]),
      ));
    }));
    if (choice == null || !mounted) return;
    _fill(category, person, choice);
  }

  // ---------- 画面 ----------

  @override
  Widget build(BuildContext context) {
    final total = _puzzle.people * _puzzle.categories.length;
    final filled = _values.fold(0, (sum, row) => sum + row.where((value) => value >= 0).length);
    return PlayFrame(
      session: _session,
      onNewGame: _newGame,
      onRestart: _restart,
      status: '已填 $filled/$total',
      controls: [
        FilledButton.icon(onPressed: _history.isEmpty || _session.finished ? null : _undo, icon: const CampusIcon(CampusIcons.undo), label: const Text('撤销')),
      ],
      board: LayoutBuilder(builder: (context, constraints) => Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // 表格最多占六成高，大字号、5 个人时放不下就在自己的区域里滚；线索在下面占满剩下的地方。
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * .6),
            child: _table(context),
          ),
          const SizedBox(height: 12),
          Expanded(child: LayoutBuilder(builder: (context, inner) => OverflowBox(
            minWidth: inner.maxWidth + 2 * _bleed,
            maxWidth: inner.maxWidth + 2 * _bleed,
            child: CampusScrollFade(child: ListView.separated(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(_bleed, 0, _bleed, 8),
              itemCount: _puzzle.clues.length,
              separatorBuilder: (context, index) => const SizedBox(height: 8),
              // 晃动只改变换：卡片自成一层，动画时只重新合成、不重画里面的字。
              itemBuilder: (context, index) => _shaking(index, RepaintBoundary(child: _clue(context, index))),
            )),
          ))),
        ]),
      ))),
    );
  }

  // 表头固定在卡片顶上，只有人那几行在表格自己的区域里滚（5 个人、大字号时放不下）：表头与人那几行是两张表，共用列宽，
  // 名字一列按最宽的名字量（经 campus_typesetting，同 Text 的口径）。
  Widget _table(BuildContext context) {
    final palette = CampusPalette.of(context);
    final head = TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: palette.onSurfaceVariant);
    final nameStyle = TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: palette.onSurface);
    var nameWidth = 0.0;
    for (final name in logicGridPeople.take(_puzzle.people)) {
      final painter = campusTextPainter(context, name, style: nameStyle, maxLines: 1);
      nameWidth = math.max(nameWidth, painter.width);
      painter.dispose();
    }
    final columns = {0: FixedColumnWidth(nameWidth.ceilToDouble() + 14)};
    return CampusSurface(
      padding: const EdgeInsets.all(8),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Table(columnWidths: columns, children: [
          TableRow(children: [
            const SizedBox.shrink(),
            for (final category in _puzzle.categories)
              Padding(padding: const EdgeInsets.fromLTRB(2, 2, 2, 6), child: ExcludeSemantics(child: Text(category.pool.name, textAlign: TextAlign.center, style: head))),
          ]),
        ]),
        Flexible(child: CampusScrollFade(child: SingleChildScrollView(child: Table(
          columnWidths: columns,
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            for (var person = 0; person < _puzzle.people; person++)
              TableRow(children: [
                Padding(padding: const EdgeInsets.fromLTRB(6, 0, 8, 0), child: ExcludeSemantics(child: Text(logicGridPeople[person], style: nameStyle))),
                // 同一行的格子一样高（长的值折两行时整行一起变高）。
                for (var category = 0; category < _puzzle.categories.length; category++)
                  TableCell(verticalAlignment: TableCellVerticalAlignment.intrinsicHeight, child: Padding(padding: const EdgeInsets.all(3), child: _cell(context, category, person))),
              ]),
          ],
        )))),
      ]),
    );
  }

  // 一格：填了写值（淡激活色底）；没填写还剩几个可能（标过「不是」时）或只画一个向下的箭头表示可以点；只剩一个可能时写出它（浅色，还没填）。
  Widget _cell(BuildContext context, int category, int person) {
    final palette = CampusPalette.of(context);
    final group = _puzzle.categories[category];
    final (value, excluded) = (_values[category][person], _excluded[category][person]);
    final left = [for (var option = 0; option < _puzzle.people; option++) if (excluded >> option & 1 == 0) option];
    final name = '${logicGridPeople[person]}的${group.pool.name}';
    final ruledOut = [for (var option = 0; option < _puzzle.people; option++) if (excluded >> option & 1 == 1) group.label(option)];
    final label = value >= 0 ? '$name：${group.label(value)}' : '$name：未填${ruledOut.isEmpty ? '' : '，不是${ruledOut.join('、')}'}';
    final Widget content = value >= 0
        ? BalancedText(group.label(value), textAlign: TextAlign.center, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: palette.onSurface))
        : excluded == 0
        ? CampusIcon(CampusIcons.expand, size: 18, color: palette.onSurfaceVariant.withValues(alpha: .7))
        : left.length == 1
        ? BalancedText(group.label(left.single), textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant))
        : Text('剩 ${left.length}', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: left.isEmpty ? palette.danger : palette.onSurfaceVariant));
    final base = value >= 0 ? palette.accent.withValues(alpha: palette.isDark ? .28 : .14) : palette.surfaceSelected.withValues(alpha: palette.isDark ? .55 : .7);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: () => _pick(category, person),
      child: AnimatedBuilder(
        animation: _glow,
        builder: (context, child) {
          final progress = ((_glow.value * (_glowEach + (_puzzle.people - 1) * _glowGap) - person * _glowGap) / _glowEach).clamp(0.0, 1.0);
          final color = Color.lerp(base, palette.accent.withValues(alpha: palette.isDark ? .6 : .42), math.sin(progress * math.pi))!;
          return Material(color: color, borderRadius: BorderRadius.circular(12), child: child);
        },
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _pick(category, person),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Center(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6), child: content)),
          ),
        ),
      ),
    );
  }

  // 判错时不成立的线索左右晃一下（越晃越小）。
  Widget _shaking(int index, Widget child) => AnimatedBuilder(
    animation: _shake,
    child: child,
    builder: (context, child) {
      if (!_shake.isAnimating || !_violations.contains(index)) return child!;
      return Transform.translate(offset: Offset(math.sin(_shake.value * math.pi * 5) * 8 * (1 - _shake.value), 0), child: child);
    },
  );

  // 一条线索：左边是序号（用过了换成勾，不成立换成警示图标），点整张卡标成用过了或取消；不成立时描一圈警示色的边、铺淡警示底。
  Widget _clue(BuildContext context, int index) {
    final palette = CampusPalette.of(context);
    final used = _used.contains(index), wrong = _violations.contains(index);
    final phrases = logicGridPhrases(_puzzle, _puzzle.clues[index]);
    final duration = _still ? Duration.zero : const Duration(milliseconds: 150);
    final style = TextStyle(fontSize: 15, fontWeight: FontWeight.w500, height: 1.45, color: palette.onSurface);
    final Widget mark = wrong
        ? CampusIcon(CampusIcons.warning, size: 18, color: palette.danger)
        : used
        ? CampusIcon(CampusIcons.check, size: 18, color: palette.accentText)
        : Text('${index + 1}', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: palette.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]));
    return Semantics(
      key: _clueKeys[index],
      button: true,
      label: '第 ${index + 1} 条：${phrases.join()}${used ? '，用过了' : ''}${wrong ? '，和表里填的对不上' : ''}',
      excludeSemantics: true,
      onTap: () => _toggleUsed(index),
      child: Stack(children: [
        CampusSurface(
          padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
          onTap: () => _toggleUsed(index),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 28, child: Center(child: Padding(padding: const EdgeInsets.only(top: 2), child: mark))),
            const SizedBox(width: 6),
            Expanded(child: AnimatedOpacity(
              opacity: used && !wrong ? .45 : 1,
              duration: duration,
              child: Wrap(children: [for (final phrase in phrases) Text(phrase, style: style)]),
            )),
          ]),
        ),
        // 不成立：卡片铺一层淡警示色、描一圈警示色的边（盖在卡片上，不改排版）。深色下的 danger 是浅粉，铺在深卡片上发灰，改用破坏性按钮的红底。
        Positioned.fill(child: IgnorePointer(child: AnimatedOpacity(
          opacity: wrong ? 1 : 0,
          duration: duration,
          child: DecoratedBox(decoration: BoxDecoration(
            color: palette.isDark ? palette.dangerFill.withValues(alpha: .2) : palette.danger.withValues(alpha: .07),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: palette.danger.withValues(alpha: palette.isDark ? .8 : .7), width: 1.5),
          )),
        ))),
      ]),
    );
  }
}
