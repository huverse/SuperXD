import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/cipher/cipher_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

const _numbers = ['零', '一', '两', '三', '四', '五'];

// 一行线索的提示说成口语，分成几段、只在段与段之间换行（窄屏时不把「位置」这类词拆到两行）。
List<String> cipherHintPhrases(CipherRow row) {
  final (exact, misplaced) = (row.exact, row.misplaced);
  return switch ((exact, misplaced)) {
    (0, 0) => ['没有一个数字对'],
    (_, 0) => ['${_numbers[exact]}个数字对，', exact > 1 ? '位置也都对' : '位置也对'],
    (0, _) => ['${_numbers[misplaced]}个数字对，', misplaced > 1 ? '但位置都不对' : '但位置不对'],
    _ => ['${_numbers[exact]}个数字对且位置对，', '另有${_numbers[misplaced]}个数字对但位置不对'],
  };
}

String cipherHintText(CipherRow row) => cipherHintPhrases(row).join();

// 玩家给数字做的记号（只是玩家自己的笔记，不自动推）：没做、不在密码里（排除）、在密码里（确定）。
// 记号跟着数字走：点线索里任何一个 7，所有线索里的 7 与键盘上的 7 都换成同一个记号。
enum CipherMark {
  none('没做记号'),
  absent('不在密码里'),
  present('在密码里');

  const CipherMark(this.label);
  final String label;

  // 点一下换下一个：没做 → 排除 → 确定 → 没做（排除最常用，放第一下）。
  CipherMark get next => values[(index + 1) % values.length];
}

// 解开后的收尾：答案格自左向右依次亮成激活色、轻轻鼓一下，每格 _glowEach、错开 _glowGap。
const _glowEach = 320, _glowGap = 90;
// 线索里的数字方块与答案格的最小边长（触区至少 48）。
const _cell = 48.0;

// 密码破译对局页：上面是线索（每行几个数字方块加一句提示，点数字做记号），下面是答案格与数字键盘，填满点「确认」判定。
// 对了答案格依次亮一下再弹结果；不对不给答案，只标出和答案对不上的线索行、轻震并提示，判错次数写进结果。
class CipherPage extends StatefulWidget {
  const CipherPage({super.key, required this.game, required this.store, this.seeds});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;

  @override
  State<CipherPage> createState() => _CipherPageState();
}

class _CipherPageState extends State<CipherPage> with TickerProviderStateMixin {
  static const _rules = CipherRules();
  late final _session = PlaySession<CipherPuzzle, List<int>>(game: widget.game, rules: _rules, store: widget.store, seeds: widget.seeds);
  // 答案格：每位填的数字，null 是空。
  late var _slots = List<int?>.filled(_puzzle.length, null);
  // 每个数字的记号（下标是数字）。
  var _marks = List.filled(cipherMaxDigits, CipherMark.none);
  // 每一步改了什么、改之前是什么，撤销按步退回：(是不是记号, 数字或答案格的下标, 之前的记号序号或之前填的数字)。
  final _history = <(bool, int, int?)>[];
  // 上次点「确认」时和答案对不上的线索行；答案一改就清掉（标的是旧答案）。
  var _conflicts = <int>{};
  var _wrongs = 0;
  final _scroll = ScrollController();
  late var _rowKeys = _keys();
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

  CipherPuzzle get _puzzle => _session.puzzle;
  bool get _still => MediaQuery.disableAnimationsOf(context);
  bool get _full => !_slots.contains(null);
  List<GlobalKey> _keys() => [for (final _ in _puzzle.rows) GlobalKey()];

  // 换题、从头来：先清自己的棋盘与动画，再交给 session，最后按新题摆空答案格。
  void _clear() {
    _history.clear();
    _marks = List.filled(cipherMaxDigits, CipherMark.none);
    _conflicts = {};
    _wrongs = 0;
    _shake.value = 0;
    _glow.value = 0;
    hideCampusToast();
  }

  void _newGame(PuzzleTier? tier) {
    setState(() {
      _clear();
      _session.next(tier: tier);
      _slots = List.filled(_puzzle.length, null);
      _rowKeys = _keys();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _restart() => setState(() {
    _clear();
    _session.restart();
    _slots = List.filled(_puzzle.length, null);
  });

  // ---------- 操作 ----------

  // 一步正常操作：触感、开始计时、记进撤销，收起过时的提示。
  void _step((bool, int, int?) undo, VoidCallback change) {
    playTick();
    hideCampusToast();
    _session.moved();
    setState(() {
      _history.add(undo);
      change();
    });
  }

  void _mark(int digit) {
    if (_session.finished) return;
    final previous = _marks[digit];
    _step((true, digit, previous.index), () => _marks[digit] = previous.next);
  }

  // 键盘上点数字：填进第一个空格。已经填过的数字不收（密码里的数字各不相同），轻震并提示。
  void _type(int digit) {
    if (_session.finished || _full) return;
    if (_slots.contains(digit)) {
      playRejected();
      showCampusToast(context, '密码里的数字各不相同');
      return;
    }
    final slot = _slots.indexOf(null);
    _step((false, slot, null), () {
      _slots[slot] = digit;
      _conflicts = {};
    });
  }

  // 清掉一格：退格清最后填的一格，点已填的答案格清那一格。
  void _erase(int slot) {
    if (_session.finished || _slots[slot] == null) return;
    _step((false, slot, _slots[slot]), () {
      _slots[slot] = null;
      _conflicts = {};
    });
  }

  void _backspace() {
    final slot = _slots.lastIndexWhere((digit) => digit != null);
    if (slot >= 0) _erase(slot);
  }

  void _undo() {
    if (_history.isEmpty || _session.finished) return;
    playTick();
    hideCampusToast();
    setState(() {
      final (mark, index, previous) = _history.removeLast();
      if (mark) {
        _marks[index] = CipherMark.values[previous!];
      } else {
        _slots[index] = previous;
        _conflicts = {};
      }
    });
  }

  // 填满后点「确认」：按规则判。对了收尾；不对记一次判错，标出对不上的线索行、轻震、答案格晃一下，滚到第一行对不上的线索。
  void _confirm() {
    if (_session.finished || !_full) return;
    final answer = [for (final digit in _slots) digit!];
    if (_rules.solved(_puzzle, answer)) {
      hideCampusToast();
      unawaited(_finish());
      return;
    }
    final conflicts = cipherConflicts(_puzzle, answer);
    setState(() {
      _wrongs++;
      _conflicts = conflicts.toSet();
    });
    playRejected();
    showCampusToast(context, '还不对，标红的线索对不上');
    if (_still) return;
    unawaited(_shake.forward(from: 0));
    if (_rowKeys[conflicts.first].currentContext case final target?) _reveal(target);
  }

  // 第一行对不上的线索在可见区外时滚过去：在上面就贴着上沿露出来，在下面就贴着下沿，已经看得见的不动。
  void _reveal(BuildContext target) {
    final box = target.findRenderObject(), view = Scrollable.maybeOf(target)?.context.findRenderObject();
    if (box is! RenderBox || view is! RenderBox) return;
    final above = box.localToGlobal(Offset.zero).dy < view.localToGlobal(Offset.zero).dy;
    unawaited(Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignmentPolicy: above ? ScrollPositionAlignmentPolicy.keepVisibleAtStart : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    ));
  }

  Future<void> _finish() async {
    final newBest = await _session.finish();
    if (!mounted) return;
    // 答案格依次亮一下，亮完再弹结果；减少动画时直接弹。
    if (!_still) await _glow.animateTo(1, duration: Duration(milliseconds: _glowEach + (_puzzle.length - 1) * _glowGap));
    if (!mounted) return;
    final choice = await showPlayResult(context, session: _session, newBest: newBest, detail: '${_puzzle.length} 位 · ${_wrongs == 0 ? '一次就对' : '判错 $_wrongs 次'}');
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
    final filled = _slots.where((digit) => digit != null).length;
    return PlayFrame(
      session: _session,
      onNewGame: _newGame,
      onRestart: _restart,
      status: '已填 $filled/${_puzzle.length}',
      controls: [
        FilledButton.icon(onPressed: _history.isEmpty || _session.finished ? null : _undo, icon: const CampusIcon(CampusIcons.undo), label: const Text('撤销')),
        FilledButton.icon(style: campusProminent, onPressed: _full && !_session.finished ? _confirm : null, icon: const CampusIcon(CampusIcons.check), label: const Text('确认')),
      ],
      board: LayoutBuilder(builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        final keyHeight = math.max(52.0, scaler.scale(22) + 24);
        final keyRows = _keyRows().length;
        final inputHeight = keyHeight + 12 + keyRows * keyHeight + (keyRows - 1) * 8;
        final clues = _clues(context);
        final input = CampusToastAnchor(child: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _answer(context, keyHeight),
            const SizedBox(height: 12),
            _keypad(context, keyHeight),
          ]),
        )));
        // 放得下时键盘停在底部、线索在上面单独滚（线索少时在上面的区域里居中）；太矮（横屏、超大字号）时连键盘一起滚。
        if (constraints.maxHeight - inputHeight - 12 >= 140) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: LayoutBuilder(builder: (context, area) => CampusScrollFade(child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: ConstrainedBox(constraints: BoxConstraints(minHeight: math.max(0, area.maxHeight - 8)), child: Center(child: clues)),
            )))),
            const SizedBox(height: 12),
            input,
          ]);
        }
        return CampusScrollFade(child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [clues, const SizedBox(height: 12), input]),
        ));
      }),
    );
  }

  Widget _clues(BuildContext context) {
    final palette = CampusPalette.of(context);
    final puzzle = _puzzle;
    return Center(child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: DotSeparatedText('${puzzle.length} 位 · 数字 0–${puzzle.digits - 1} · 不重复', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
        ),
        for (final (index, row) in puzzle.rows.indexed) ...[
          if (index > 0) const SizedBox(height: 8),
          KeyedSubtree(key: _rowKeys[index], child: _clue(context, index, row)),
        ],
      ]),
    ));
  }

  Widget _clue(BuildContext context, int index, CipherRow row) {
    final palette = CampusPalette.of(context);
    final conflict = _conflicts.contains(index);
    final duration = _still ? Duration.zero : const Duration(milliseconds: 150);
    return Semantics(
      container: true,
      label: '第 ${index + 1} 行线索：${row.guess.join(' ')}，${cipherHintText(row)}${conflict ? '，和你的答案对不上' : ''}',
      child: Stack(children: [
        CampusSurface(
          radius: 20,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // 一行数字不折行（位置就是信息）：5 位也只占 264 宽，360dp 的屏上放得下。
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (final (position, digit) in row.guess.indexed) ...[
                if (position > 0) const SizedBox(width: 6),
                _tile(context, digit, duration),
              ],
            ]),
            const SizedBox(height: 8),
            ExcludeSemantics(child: Wrap(children: [
              for (final phrase in cipherHintPhrases(row)) Text(phrase, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, height: 1.4, color: palette.onSurface)),
            ])),
          ]),
        ),
        // 对不上：卡片描一圈警示色的边（盖在卡片边上，不改卡片排版）。
        Positioned.fill(child: IgnorePointer(child: AnimatedOpacity(
          opacity: conflict ? 1 : 0,
          duration: duration,
          child: DecoratedBox(decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: palette.danger.withValues(alpha: palette.isDark ? .85 : .75), width: 2),
          )),
        ))),
      ]),
    );
  }

  // 线索里的一个数字：点一下换记号。排除是淡字加删除线、确定是激活色底白字。
  Widget _tile(BuildContext context, int digit, Duration duration) {
    final palette = CampusPalette.of(context);
    final mark = _marks[digit];
    final (fill, border, color) = switch (mark) {
      CipherMark.none => (palette.onSurface.withValues(alpha: palette.isDark ? .10 : .06), Colors.transparent, palette.onSurface),
      CipherMark.absent => (Colors.transparent, palette.outlineSubtle, palette.onSurfaceVariant.withValues(alpha: .6)),
      CipherMark.present => (palette.accent, palette.accent, Colors.white),
    };
    return Semantics(
      button: true,
      label: '数字 $digit，${mark.label}',
      onTapHint: '改记号',
      onTap: () => _mark(digit),
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _mark(digit),
        child: AnimatedContainer(
          duration: duration,
          constraints: const BoxConstraints(minWidth: _cell, minHeight: _cell),
          padding: const EdgeInsets.symmetric(vertical: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(12), border: Border.all(color: border, width: 1.5)),
          child: Text('$digit', style: _digitStyle(color, mark)),
        ),
      ),
    );
  }

  static TextStyle _digitStyle(Color color, CipherMark mark, {double size = 22}) => TextStyle(
    fontSize: size,
    fontWeight: FontWeight.w600,
    height: 1.2,
    color: color,
    fontFeatures: const [FontFeature.tabularFigures()],
    decoration: mark == CipherMark.absent ? TextDecoration.lineThrough : null,
    decorationColor: color,
    decorationThickness: 2,
  );

  // 答案格加退格：点已填的格清掉那一格；下一个要填的格描激活色边；判错后描警示色边直到答案改动；解开后依次亮成激活色。
  Widget _answer(BuildContext context, double height) {
    final palette = CampusPalette.of(context);
    final length = _puzzle.length;
    final next = _slots.indexOf(null);
    final wrong = _conflicts.isNotEmpty;
    return LayoutBuilder(builder: (context, constraints) {
      const gap = 6.0;
      final width = math.min(60.0, (constraints.maxWidth - _cell - 8 - (length - 1) * gap) / length);
      return AnimatedBuilder(
        animation: Listenable.merge([_shake, _glow]),
        builder: (context, _) {
          final shaking = _shake.isAnimating;
          final offset = shaking ? math.sin(_shake.value * math.pi * 5) * 8 * (1 - _shake.value) : 0.0;
          return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Transform.translate(offset: Offset(offset, 0), child: Row(children: [
              for (var slot = 0; slot < length; slot++) ...[
                if (slot > 0) const SizedBox(width: gap),
                _slot(context, slot, width, height, next: slot == next, wrong: wrong),
              ],
            ])),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '退格',
              onPressed: _slots.any((digit) => digit != null) && !_session.finished ? _backspace : null,
              color: palette.onSurfaceVariant,
              icon: const CampusIcon(CampusIcons.backspace),
            ),
          ]);
        },
      );
    });
  }

  Widget _slot(BuildContext context, int slot, double width, double height, {required bool next, required bool wrong}) {
    final palette = CampusPalette.of(context);
    final digit = _slots[slot];
    final progress = _session.finished
        ? (_still ? 1.0 : ((_glow.value * (_glowEach + (_puzzle.length - 1) * _glowGap) - slot * _glowGap) / _glowEach).clamp(0.0, 1.0))
        : 0.0;
    final glow = Curves.easeOutCubic.transform(progress);
    final base = campusSurfaceFill(context);
    final fill = Color.lerp(base, palette.accent, glow)!;
    final border = progress > 0
        ? palette.accent
        : wrong
        ? palette.danger.withValues(alpha: palette.isDark ? .85 : .75)
        : next && !_session.finished
        ? palette.accent
        : palette.outline.withValues(alpha: .5);
    final color = Color.lerp(palette.onSurface, Colors.white, glow)!;
    final cell = Transform.scale(
      scale: 1 + .1 * math.sin(progress * math.pi),
      child: Container(
        width: width,
        constraints: BoxConstraints(minHeight: height),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(14), border: Border.all(color: border, width: next || wrong || progress > 0 ? 2 : 1.5)),
        child: Text(digit == null ? '' : '$digit', style: _digitStyle(color, CipherMark.none, size: 24)),
      ),
    );
    return Semantics(
      button: digit != null && !_session.finished,
      label: '答案第 ${slot + 1} 位：${digit ?? '空'}',
      onTapHint: digit != null ? '清掉' : null,
      onTap: digit == null ? null : () => _erase(slot),
      excludeSemantics: true,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: digit == null ? null : () => _erase(slot), child: cell),
    );
  }

  // 键盘按数字从小到大排：十个数字两行各五个，不超过六个排一行。
  List<List<int>> _keyRows() {
    final digits = _puzzle.digits;
    final perRow = digits <= 6 ? digits : (digits + 1) ~/ 2;
    return [
      for (var start = 0; start < digits; start += perRow) [for (var digit = start; digit < math.min(start + perRow, digits); digit++) digit],
    ];
  }

  // 数字键：色调胶囊，跟着记号显示（排除的淡字加删除线、确定的用强调色字），记号只是提醒、照样能点；填满后不能再点。
  Widget _keypad(BuildContext context, double height) {
    final palette = CampusPalette.of(context);
    final rows = _keyRows();
    final perRow = rows.first.length;
    final enabled = !_full && !_session.finished;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (final (index, row) in rows.indexed) ...[
        if (index > 0) const SizedBox(height: 8),
        Row(children: [
          for (var column = 0; column < perRow; column++) ...[
            if (column > 0) const SizedBox(width: 8),
            Expanded(child: column < row.length ? _key(palette, row[column], height, enabled) : const SizedBox.shrink()),
          ],
        ]),
      ],
    ]);
  }

  Widget _key(CampusPalette palette, int digit, double height, bool enabled) {
    final mark = _marks[digit];
    final color = !enabled
        ? palette.onSurfaceVariant
        : switch (mark) {
            CipherMark.none => palette.onSurface,
            CipherMark.absent => palette.onSurfaceVariant.withValues(alpha: .6),
            CipherMark.present => palette.accentText,
          };
    return Semantics(
      label: '$digit${mark == CipherMark.none ? '' : '，${mark.label}'}',
      excludeSemantics: true,
      button: true,
      enabled: enabled,
      onTap: enabled ? () => _type(digit) : null,
      child: FilledButton(
        onPressed: enabled ? () => _type(digit) : null,
        style: FilledButton.styleFrom(minimumSize: Size(_cell, height), padding: EdgeInsets.zero),
        child: Text('$digit', style: _digitStyle(color, mark)),
      ),
    );
  }
}
