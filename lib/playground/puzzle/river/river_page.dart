import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:superxd/playground/challenge/play_challenge.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/river/river_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_typesetting.dart';

// 过河问题对局页：俯看一条河，左岸、河、右岸横排，船停在当前这一岸的岸边。点岸上的人上船（船要在这一岸、没坐满），
// 点船上的人下船回到船所在的岸；人齐了点「开船」，船载着人渡到对岸，船上的人靠岸后留在船上（算在那一岸），下一趟可以接着坐。
// 开船那一刻按规则查：会犯规就不开，轻震、船晃一下，把牵涉的人圈出来，提示条写明原因。撤销按整次渡河退回到开船前。
// 每个人在两岸各有固定的站位（左右镜像），上下船只在站位与座位之间移动，别人不挪。全部到了右岸：船上的人下船，大家依次轻轻跳一下，再弹结果。
class RiverPage extends StatefulWidget {
  const RiverPage({super.key, required this.game, required this.store, this.seeds, this.challenge});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;
  // 挑战里的一关（题面是服务器给的）；自由模式为空。
  final PlayChallenge? challenge;

  @override
  State<RiverPage> createState() => _RiverPageState();
}

// 开船前的局面：撤销整次渡河就回到这里（船上坐的人也照原样）。
typedef _Before = ({int left, int side, List<int?> seats});

class _RiverPageState extends State<RiverPage> with TickerProviderStateMixin {
  static const _rules = RiverRules();
  late final _session = PlaySession<RiverPuzzle, List<RiverCrossing>>(game: widget.game, rules: _rules, store: widget.store, seeds: widget.seeds, challenge: widget.challenge);
  // 左岸有谁（含停在左岸的船上的人）、船在哪岸、船上每个座位坐着谁（座位固定，下船的人空出座位，别人不挪）。
  late int _left = _puzzle.everyone;
  int _side = riverLeft;
  late List<int?> _seats = List.filled(_puzzle.capacity, null);
  final _history = <_Before>[];

  // 上下船：每个人从按下那一刻显示的位置走到新的站位或座位；座位跟着船走，所以坐着没动的人不记起点，直接贴着座位。
  final _from = <int, Offset>{};
  late final _move = AnimationController(vsync: this, duration: const Duration(milliseconds: 220), value: 1);
  // 开船：船从 _boatFrom（0 左岸、1 右岸）驶到 _side。
  late final _sail = AnimationController(vsync: this, duration: const Duration(milliseconds: 400), value: 1);
  double _boatFrom = 0;
  // 不让开或点错：晃一下（_shaking 是晃的那个人，-1 是船），犯规牵涉的人圈一圈警示色再淡掉。
  late final _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 360));
  int? _shaking;
  late final _flash = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400), value: 1);
  Set<int> _flagged = {};
  // 解开后在右岸依次轻轻跳一下：每人 _hopEach，按站位错开 _hopGap。
  late final _hop = AnimationController(vsync: this);
  late final _motion = Listenable.merge([_move, _sail, _shake, _flash, _hop]);
  int? _pressed;
  _RiverLayout? _layout;

  static const _hopEach = 380, _hopGap = 55;

  @override
  void dispose() {
    _move.dispose();
    _sail.dispose();
    _shake.dispose();
    _flash.dispose();
    _hop.dispose();
    _session.dispose();
    super.dispose();
  }

  RiverPuzzle get _puzzle => _session.puzzle;
  // 最少几次：挑战模式没有参考解（服务器不给），就不写。
  int? get _least => _session.reference?.length;
  bool get _reduced => MediaQuery.disableAnimationsOf(context);
  bool get _busy => _session.finished || _sail.isAnimating;

  void _reset() {
    hideCampusToast();
    _left = _puzzle.everyone;
    _side = riverLeft;
    _seats = List.filled(_puzzle.capacity, null);
    _history.clear();
    _from.clear();
    _boatFrom = 0;
    _shaking = _pressed = null;
    _flagged = {};
    _move.value = 1;
    _sail.value = 1;
    _shake.value = 0;
    _flash.value = 1;
    _hop.value = 0;
  }

  void _newGame(PuzzleTier? tier) => setState(() {
    _session.next(tier: tier);
    _reset();
  });

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

  // 每个人现在待的地方：座位号，或 100 + 哪一岸。
  int _anchor(int person) {
    final seat = _seats.indexOf(person);
    return seat >= 0 ? seat : 100 + (_left & (1 << person) != 0 ? riverLeft : riverRight);
  }

  double get _boatAt => _boatFrom + (_side - _boatFrom) * Curves.easeInOutCubic.transform(_sail.value);

  double _wobble(int target) => _shaking == target && _shake.isAnimating ? math.sin(_shake.value * math.pi * 5) * 6 * (1 - _shake.value) : 0;

  Offset _target(_RiverLayout layout, int person) {
    final seat = _seats.indexOf(person);
    if (seat >= 0) return layout.seat(seat, _boatAt) + Offset(_wobble(-1), 0);
    return layout.cell(person, _left & (1 << person) != 0 ? riverLeft : riverRight) + Offset(_wobble(person), 0);
  }

  Offset _shown(_RiverLayout layout, int person) {
    final target = _target(layout, person);
    final from = _from[person];
    if (from == null || _move.value >= 1) return target;
    return Offset.lerp(from, target, Curves.easeOutCubic.transform(_move.value))!;
  }

  // 改局面并让换了地方的人走过去：起点是改之前显示的位置（上一段没走完的从半路接着走）。
  void _shift(VoidCallback change) {
    final layout = _layout;
    final moving = _move.value < 1 ? {..._from.keys} : const <int>{};
    final before = [for (var person = 0; person < _puzzle.count; person++) (anchor: _anchor(person), at: layout == null ? null : _shown(layout, person))];
    change();
    _from.clear();
    for (final (person, (:anchor, :at)) in before.indexed) {
      if (at != null && (anchor != _anchor(person) || moving.contains(person))) _from[person] = at;
    }
    unawaited(_play(_move));
  }

  // ---------- 操作 ----------

  void _tap(int person) {
    if (_busy) return;
    final seat = _seats.indexOf(person);
    if (seat < 0) {
      final bank = _left & (1 << person) != 0 ? riverLeft : riverRight;
      if (bank != _side) return _refuse(person, '船在对岸');
      final free = _seats.indexOf(null);
      if (free < 0) return _refuse(person, '船上最多 ${_puzzle.capacity} 个');
    }
    playTick();
    // 犯规的提示已经过时（用户接着做了一步能做的操作），收起来，免得还停在屏幕上像是在说这一步。
    hideCampusToast();
    _session.moved();
    setState(() {
      _flagged = {};
      _shift(() {
        if (seat >= 0) {
          _seats[seat] = null;
        } else {
          _seats[_seats.indexOf(null)] = person;
        }
      });
    });
  }

  void _refuse(int person, String message) {
    playRejected();
    showCampusToast(context, message);
    setState(() {
      _shaking = person;
      _flagged = {};
    });
    if (!_reduced) unawaited(_shake.forward(from: 0));
  }

  void _launch() {
    if (_busy) return;
    final group = riverMask(_seats.nonNulls);
    if (riverCheck(_puzzle, _left, _side, group) case final violation?) return _reject(violation);
    playTick();
    hideCampusToast();
    _session.moved();
    final from = _boatAt;
    setState(() {
      _history.add((left: _left, side: _side, seats: [..._seats]));
      _left = riverAfter(_left, _side, group);
      _side = 1 - _side;
      _boatFrom = from;
      _flagged = {};
    });
    final sail = _play(_sail);
    if (_left == 0) unawaited(_finish(sail));
  }

  // 犯规：不开船，船晃一下、牵涉的人圈出来（减少动画时圈着不动，下一次操作再撤），提示条写原因。
  void _reject(RiverViolation violation) {
    playRejected();
    showCampusToast(context, _message(violation));
    setState(() {
      _shaking = -1;
      _flagged = {...violation.people};
    });
    if (_reduced) {
      _flash.value = 0;
    } else {
      unawaited(_shake.forward(from: 0));
      unawaited(_flash.forward(from: 0));
    }
  }

  String _message(RiverViolation violation) {
    final people = _puzzle.people;
    String name(int index) => riverName(people[index]);
    final place = switch (violation.place) {
      RiverPlace.left => '左岸',
      RiverPlace.right => '右岸',
      RiverPlace.boat => '船上',
      null => '',
    };
    return switch (violation.fault) {
      RiverFault.empty => '船上还没有人',
      RiverFault.crowded => '船上最多 ${_puzzle.capacity} 个',
      RiverFault.absent => '有人不在船这一岸',
      RiverFault.noRower => _puzzle.variant == RiverVariant.farmer ? '只有农夫会划船' : '船上没有会划船的人',
      RiverFault.eaten => '$place没人看着，${name(violation.people[0])}会吃掉${name(violation.people[1])}',
      RiverFault.outnumbered => '$place小孩比大人多，管不过来',
      RiverFault.unguarded => '$place：大${riverFamilyNames[people[violation.people[0]].family]}不在，${name(violation.people[0])}不能和${name(violation.people[1])}待在一起',
    };
  }

  void _undo() {
    if (_history.isEmpty || _busy) return;
    playTick();
    hideCampusToast();
    final last = _history.removeLast();
    final from = _boatAt;
    setState(() {
      _flagged = {};
      _shift(() {
        _left = last.left;
        _side = last.side;
        _seats = [...last.seats];
        _boatFrom = from;
      });
    });
    unawaited(_play(_sail));
  }

  // 解开：停表记成绩；等船靠岸，船上的人下船站到右岸，大家依次轻轻跳一下，再弹结果。减少动画时直接弹。
  // 中途换题或从头来会停掉动画，等着的这一段就不再往下走。
  Future<void> _finish(TickerFuture sail) async {
    final newBest = await _session.finish(moves: _history.length, answer: [for (final step in _history) [...step.seats.nonNulls]]);
    await sail;
    if (!mounted) return;
    setState(() => _shift(() => _seats = List.filled(_puzzle.capacity, null)));
    if (!_reduced) {
      await _move.forward();
      if (!mounted) return;
      _hop.duration = Duration(milliseconds: _hopEach + (_puzzle.count - 1) * _hopGap);
      await _hop.forward(from: 0);
    }
    if (!mounted) return;
    final least = _least, crossings = _history.length;
    final choice = await showPlayResult(context, session: _session, newBest: newBest, detail: least == null ? '渡河 $crossings 次' : crossings == least ? '渡河 $least 次，正好最少' : '渡河 $crossings 次，最少 $least 次');
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
    return PlayFrame(
      session: _session,
      onNewGame: _newGame,
      onRestart: _restart,
      status: ['渡河 ${_history.length} 次', if (_least case final least?) '最少 $least 次'].join(' · '),
      controls: [
        FilledButton.icon(onPressed: _history.isEmpty || finished ? null : _undo, icon: const CampusIcon(CampusIcons.undo), label: const Text('撤销')),
        FilledButton.icon(
          style: campusProminent,
          onPressed: finished || _seats.every((seat) => seat == null) ? null : _launch,
          icon: const CampusIcon(CampusIcons.river),
          label: const Text('开船'),
        ),
      ],
      board: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Brief(puzzle: _puzzle),
        const SizedBox(height: 12),
        Expanded(child: LayoutBuilder(builder: (context, constraints) => _scene(context, constraints.biggest))),
      ]),
    );
  }

  Widget _scene(BuildContext context, Size area) {
    final palette = CampusPalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final cached = _layout;
    final layout = cached != null && cached.puzzle == _puzzle && cached.area == area && cached.scale == scaler.scale(16) ? cached : _layout = _RiverLayout(_puzzle, area, scaler);
    final colors = _RiverColors.of(palette);
    final label = TextStyle(fontSize: 14, height: 1.3, color: palette.onSurfaceVariant);
    final scene = SizedBox.fromSize(size: layout.size, child: Stack(clipBehavior: Clip.none, children: [
      Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: _ScenePainter(layout: layout, colors: colors)))),
      // 两岸的名字写在岸下方；右岸带一面小旗，是要去的地方。
      for (final side in [riverLeft, riverRight])
        Positioned(
          left: side == riverLeft ? 0 : layout.size.width - layout.bank,
          width: layout.bank,
          bottom: layout.labelBottom,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (side == riverRight) ...[CampusIcon(CampusIcons.flag, size: 16, color: palette.onSurfaceVariant), const SizedBox(width: 4)],
            Text(side == riverLeft ? '左岸' : '右岸', style: label),
          ]),
        ),
      Positioned.fill(child: AnimatedBuilder(animation: _motion, builder: (context, _) => _pieces(layout, colors))),
    ]));
    return Center(child: layout.fits ? scene : FittedBox(child: scene));
  }

  Widget _pieces(_RiverLayout layout, _RiverColors colors) {
    final puzzle = _puzzle;
    final boat = layout.boatRect(_boatAt).shift(Offset(_wobble(-1), 0));
    final travel = _sail.isAnimating ? math.sin(_sail.value * math.pi) * (_side - _boatFrom).sign : 0.0;
    final aboard = _seats.nonNulls.map((index) => riverName(puzzle.people[index]));
    final alert = _flagged.isEmpty ? 0.0 : _flash.value < .6 ? 1.0 : 1 - Curves.easeIn.transform((_flash.value - .6) / .4);
    // 收尾时每个人跳到哪：按站位从上到下、从靠河到岸里错开。
    final hopAt = _hop.value * (_hopEach + (puzzle.count - 1) * _hopGap);
    return Stack(clipBehavior: Clip.none, children: [
      Positioned.fromRect(
        rect: boat.inflate(_BoatPainter.margin),
        child: Semantics(
          label: '船，停在${_side == riverLeft ? '左岸' : '右岸'}，${aboard.isEmpty ? '空着' : '船上有${aboard.join('、')}'}',
          child: CustomPaint(painter: _BoatPainter(colors: colors, capacity: puzzle.capacity, slot: layout.slot, cap: layout.boatCap, wake: travel)),
        ),
      ),
      for (var person = 0; person < puzzle.count; person++)
        () {
          final at = _shown(layout, person);
          final local = ((hopAt - layout.rank[person] * _hopGap) / _hopEach).clamp(0.0, 1.0);
          final seated = _seats.contains(person);
          final where = seated ? '在船上' : _left & (1 << person) != 0 ? '在左岸' : '在右岸';
          return Positioned(
            key: ValueKey(person),
            left: at.dx - layout.slot / 2,
            top: at.dy - layout.slot / 2,
            width: layout.slot,
            height: layout.slot,
            child: Semantics(
              button: true,
              label: '${_label(person)}，$where',
              onTap: _session.finished ? null : () => _tap(person),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTapDown: (_) => setState(() => _pressed = person),
                onTapCancel: () => setState(() => _pressed = null),
                onTap: () {
                  setState(() => _pressed = null);
                  _tap(person);
                },
                child: _Badge(
                  person: puzzle.people[person],
                  diameter: layout.diameter(puzzle.people[person]),
                  colors: colors,
                  pressed: _pressed == person,
                  alert: _flagged.contains(person) ? alert : 0,
                  hop: local == 0 || local == 1 ? 0 : math.sin(local * math.pi),
                  lift: layout.slot * .24,
                ),
              ),
            ),
          );
        }(),
    ]);
  }

  // 读屏名字：一样的人（大人、小孩）按站位编号。
  String _label(int person) {
    final people = _puzzle.people;
    final role = people[person].role;
    if (role != RiverRole.adult && role != RiverRole.kid) return riverName(people[person]);
    final order = people.take(person + 1).where((item) => item.role == role).length;
    return '第$order个${riverName(people[person])}';
  }
}

// 中文数字（题面上的「三对父子」「两个小孩」）。
String _chinese(int value) => const ['零', '一', '两', '三', '四', '五', '六', '七', '八', '九', '十'][value];

// 河上方的题面说明：这一道是哪种题、船载几个、要守什么规矩（「玩法」里是总的说明，这里按这一道的题型讲）。
class _Brief extends StatelessWidget {
  const _Brief({required this.puzzle});
  final RiverPuzzle puzzle;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final capacity = puzzle.capacity;
    final roles = [for (final person in puzzle.people) person.role];
    final (title, rule) = switch (puzzle.variant) {
      RiverVariant.farmer => ('农夫过河', '只有农夫会划船，船上除了他最多再带一样；没人看着时，狼会吃羊，羊会吃白菜。'),
      RiverVariant.guardians => (
        '${_chinese(roles.where((role) => role == RiverRole.adult).length)}个大人、${_chinese(roles.where((role) => role == RiverRole.kid).length)}个小孩',
        '人人会划船，船上最多 $capacity 人；有大人的岸上，小孩不能比大人多，靠岸时连船上的人一起算。',
      ),
      RiverVariant.families => ('${_chinese(puzzle.count ~/ 2)}对父子', '人人会划船，船上最多 $capacity 人；爸爸不在时，孩子不能和别人家的爸爸待在一起，船上也算。'),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.4, color: palette.onSurface)),
      const SizedBox(height: 2),
      BalancedText(rule, style: TextStyle(fontSize: 14, height: 1.43, color: palette.onSurfaceVariant)),
    ]);
  }
}

// 场景几何：岸上每人一格（触区 slot 见方），农夫过河一列，其余两列（大人、爸爸靠河，小孩、孩子在里侧，父子同一行）；
// 两岸左右镜像，同一个人在两岸站同一行同一列。船竖着停在河里靠当前岸的一边，座位从上到下一格一个。
// 宽度不够时先把格子收到 48（徽章跟着收），高度不够时整个场景等比缩小放进去（只在极端大字号的小屏上发生）。
class _RiverLayout {
  factory _RiverLayout(RiverPuzzle puzzle, Size area, TextScaler scaler) {
    final columns = puzzle.variant == RiverVariant.farmer ? 1 : 2;
    final cells = _cells(puzzle);
    final rows = cells.fold(0.0, (most, cell) => math.max(most, cell.row + 1)).ceil();
    final width = math.min(area.width, 560.0);
    var big = math.max(40.0, scaler.scale(16) + 18), small = math.max(32.0, scaler.scale(14) + 12);
    var slot = math.max(48.0, big + 8);
    // 河至少要放得下船、两头各留一点，再给船走 40 的路。
    double riverFor(double big) => big + 16 + 2 * _dock + 40;
    final widest = (width - riverFor(big) - 2 * (_pad + _shore)) / (2 * columns);
    if (slot > widest) {
      slot = math.max(48.0, widest);
      big = math.min(big, slot - 8);
      small = math.min(small, big - 6);
    }
    final bank = _pad + columns * slot + _shore;
    final boatWidth = big + 16, boatCap = boatWidth * .62;
    final boatLength = puzzle.capacity * slot + boatCap * 2;
    final label = scaler.scale(14) * 1.3;
    final content = math.max(rows * slot, boatLength);
    final natural = _top + content + _gap + label + _bottom;
    final height = math.max(natural, math.min(area.height, width * 1.1));
    final middle = _top + (height - _top - _gap - label - _bottom) / 2;
    return _RiverLayout._(
      puzzle: puzzle,
      area: area,
      scale: scaler.scale(16),
      size: Size(width, height),
      fits: natural <= area.height,
      cells: cells,
      rows: rows,
      slot: slot,
      big: big,
      small: small,
      bank: bank,
      boatWidth: boatWidth,
      boatLength: boatLength,
      boatCap: boatCap,
      middle: middle,
      labelBottom: _bottom,
    );
  }

  _RiverLayout._({
    required this.puzzle,
    required this.area,
    required this.scale,
    required this.size,
    required this.fits,
    required this.cells,
    required this.rows,
    required this.slot,
    required this.big,
    required this.small,
    required this.bank,
    required this.boatWidth,
    required this.boatLength,
    required this.boatCap,
    required this.middle,
    required this.labelBottom,
  }) : rank = _ranks(cells);

  // 岸外沿留白、站位离岸线、船离岸线、内容上下的留白与岸名上方的间距。
  static const _pad = 8.0, _shore = 6.0, _dock = 6.0, _top = 18.0, _gap = 14.0, _bottom = 12.0;

  final RiverPuzzle puzzle;
  final Size area, size;
  final double scale, slot, big, small, bank, boatWidth, boatLength, boatCap, middle, labelBottom;
  final bool fits;
  final List<({double row, int column})> cells;
  final int rows;
  final List<int> rank;

  double diameter(RiverPerson person) => person.role == RiverRole.kid || person.role == RiverRole.son ? small : big;

  Offset cell(int person, int side) {
    final (:row, :column) = cells[person];
    final inset = bank - _shore - slot * (column + .5);
    return Offset(side == riverLeft ? inset : size.width - inset, middle + (row - (rows - 1) / 2) * slot);
  }

  double boatX(double at) {
    final left = bank + _dock + boatWidth / 2, right = size.width - bank - _dock - boatWidth / 2;
    return left + (right - left) * at;
  }

  Rect boatRect(double at) => Rect.fromCenter(center: Offset(boatX(at), middle), width: boatWidth, height: boatLength);

  Offset seat(int index, double at) => Offset(boatX(at), middle + (index - (puzzle.capacity - 1) / 2) * slot);

  // 每个人在岸上的格：列 0 靠河。一列人比另一列少时居中。
  static List<({double row, int column})> _cells(RiverPuzzle puzzle) {
    final people = puzzle.people;
    switch (puzzle.variant) {
      case RiverVariant.farmer:
        return [for (var index = 0; index < people.length; index++) (row: index.toDouble(), column: 0)];
      case RiverVariant.guardians:
        final adults = people.where((person) => person.role == RiverRole.adult).length, kids = people.length - adults;
        final rows = math.max(adults, kids);
        var adult = 0, kid = 0;
        return [
          for (final person in people)
            person.role == RiverRole.adult ? (row: adult++ + (rows - adults) / 2, column: 0) : (row: kid++ + (rows - kids) / 2, column: 1),
        ];
      case RiverVariant.families:
        final families = [for (final person in people) if (person.role == RiverRole.father) person.family];
        return [for (final person in people) (row: families.indexOf(person.family).toDouble(), column: person.role == RiverRole.father ? 0 : 1)];
    }
  }

  // 收尾跳一下的先后：从上到下，同一行靠河的先。
  static List<int> _ranks(List<({double row, int column})> cells) {
    final order = [for (var index = 0; index < cells.length; index++) index]
      ..sort((first, second) => cells[first].row != cells[second].row ? cells[first].row.compareTo(cells[second].row) : cells[first].column.compareTo(cells[second].column));
    final rank = List.filled(cells.length, 0);
    for (final (position, index) in order.indexed) {
      rank[index] = position;
    }
    return rank;
  }
}

// 配色全从当前配色推出：岸是卡片底色带一点标签绿（草地），岸边一道暖色的沙，河取三种雾色里最冷的那一个，近岸浅、河心深；
// 船是提醒色（琥珀）压深的木色。人物徽章是各自色相的淡底、同色相压深（深色下提亮）的字，字和底的对比度不低于 4.5。
class _RiverColors {
  _RiverColors._(this.palette) {
    final dark = palette.isDark, surface = palette.surface;
    double coldness(Color color) {
      final away = (HSLColor.fromColor(color).hue - 200).abs();
      return away > 180 ? 360 - away : away;
    }

    final fog = [palette.fogSage, palette.fogChampagne, palette.fogPearl].reduce((best, color) => coldness(color) < coldness(best) ? color : best);
    final green = palette.tagColors[2];
    land = Color.lerp(surface, green, dark ? .08 : .1)!;
    speck = Color.lerp(land, green, dark ? .3 : .28)!;
    sand = dark ? Color.lerp(surface, palette.attention, .14)! : Color.lerp(surface, palette.attention, .2)!;
    shallow = dark ? Color.lerp(palette.backgroundBottom, fog, .62)! : Color.lerp(surface, fog, .45)!;
    deep = dark ? Color.lerp(palette.backgroundTop, fog, .5)! : Color.lerp(Color.lerp(surface, fog, .8)!, palette.accent, .12)!;
    foam = Colors.white.withValues(alpha: dark ? .16 : .75);
    ripple = Colors.white.withValues(alpha: dark ? .12 : .6);
    edge = palette.outlineSubtle;
    hull = dark ? Color.lerp(palette.attention, palette.backgroundTop, .58)! : Color.lerp(palette.attention, palette.onSurface, .48)!;
    deck = dark ? Color.lerp(hull, palette.onSurface, .1)! : Color.lerp(hull, surface, .42)!;
    plank = dark ? Color.lerp(hull, palette.backgroundTop, .25)! : Color.lerp(hull, surface, .18)!;
    rim = dark ? Color.lerp(hull, palette.onSurface, .22)! : Color.lerp(hull, Colors.white, .3)!;
    shadow = Colors.black.withValues(alpha: dark ? .4 : .16);
  }

  static final _cache = Expando<_RiverColors>();
  static _RiverColors of(CampusPalette palette) => _cache[palette] ??= _RiverColors._(palette);

  final CampusPalette palette;
  late final Color land, speck, sand, shallow, deep, foam, ripple, edge, hull, deck, plank, rim, shadow;
  final _tones = <Color, (Color, Color)>{};

  // 每个人的色相：农夫与大人取控件激活色，狼取轮廓灰，羊取提醒色，白菜与小孩取标签色的绿与橙，父子按家取标签色（同一家同色）。
  Color hue(RiverPerson person) => switch (person.role) {
    RiverRole.farmer || RiverRole.adult => palette.accent,
    RiverRole.wolf => Color.lerp(palette.outline, palette.onSurfaceVariant, .35)!,
    RiverRole.goat => palette.attention,
    RiverRole.cabbage => palette.tagColors[2],
    RiverRole.kid => palette.tagColors[1],
    RiverRole.father || RiverRole.son => palette.tagColors[person.family % palette.tagColors.length],
  };

  // 徽章的底与字：底是卡片色带一点色相；字从色相出发往正文色走，直到对底的对比度不低于 4.5。
  (Color, Color) tone(Color hue) => _tones[hue] ??= () {
    final dark = palette.isDark;
    final fill = Color.lerp(palette.surface, hue, dark ? .3 : .16)!;
    var ink = hue;
    for (var step = 1; step <= 10 && _contrast(ink, fill) < 4.5; step++) {
      ink = Color.lerp(hue, palette.onSurface, step * .1)!;
    }
    return (fill, ink);
  }();

  static double _contrast(Color first, Color second) {
    final (a, b) = (first.computeLuminance(), second.computeLuminance());
    return (math.max(a, b) + .05) / (math.min(a, b) + .05);
  }
}

// 静态层：两岸草地（细小的草点）、岸边的沙、河（近岸浅河心深，几道水纹，岸边一线白浪）与外框。题、尺寸或配色变了才重画。
class _ScenePainter extends CustomPainter {
  _ScenePainter({required this.layout, required this.colors});
  final _RiverLayout layout;
  final _RiverColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(22));
    canvas.save();
    canvas.clipRRect(frame);
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.land);
    canvas.drawRawPoints(ui.PointMode.points, _specks(size), Paint()
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..color = colors.speck);
    final river = _river(size);
    // 沙：河的轮廓描一道宽边，河面盖上去以后只剩岸这一侧的一半。
    canvas.drawPath(river, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeJoin = StrokeJoin.round
      ..color = colors.sand);
    final water = Rect.fromLTRB(layout.bank - 6, 0, size.width - layout.bank + 6, size.height);
    canvas.drawPath(river, Paint()
      ..shader = LinearGradient(colors: [colors.shallow, colors.deep, colors.deep, colors.shallow], stops: const [0, .38, .62, 1]).createShader(water));
    canvas.save();
    canvas.clipPath(river);
    // 岸边一线白浪：沿河的轮廓描一道，裁在河里只露里侧那一半。
    canvas.drawPath(river, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..color = colors.foam);
    canvas.drawPath(_ripples(size), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = colors.ripple);
    canvas.restore();
    canvas.restore();
    canvas.drawRRect(frame.deflate(.5), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = colors.edge);
  }

  // 河：两条岸线（竖着走、左右轻轻起伏）围成的一条带子；岸线是隔一段取一个点、按点平滑连成的曲线。
  Path _river(Size size) {
    List<Offset> shore(double x, int salt) {
      final count = math.max(4, (size.height / 44).round());
      return [for (var index = 0; index <= count; index++) Offset(x + _noise(index * 31 + salt) * 3.2, size.height * index / count)];
    }

    final left = shore(layout.bank, 7), right = shore(size.width - layout.bank, 19).reversed.toList();
    final path = Path()..moveTo(left.first.dx, -8);
    _smooth(path, [Offset(left.first.dx, -8), ...left, Offset(left.last.dx, size.height + 8)]);
    path.lineTo(right.first.dx, size.height + 8);
    _smooth(path, [Offset(right.first.dx, size.height + 8), ...right, Offset(right.last.dx, -8)]);
    return path..close();
  }

  // Catmull-Rom 换成三次贝塞尔：曲线穿过每个点、处处圆滑。
  static void _smooth(Path path, List<Offset> points) {
    for (var index = 0; index < points.length - 1; index++) {
      final before = points[math.max(0, index - 1)], from = points[index], to = points[index + 1], after = points[math.min(points.length - 1, index + 2)];
      final first = from + (to - before) / 6, second = to - (after - from) / 6;
      path.cubicTo(first.dx, first.dy, second.dx, second.dy, to.dx, to.dy);
    }
  }

  // 水纹：河里散几道很淡的短弧，位置按序号散开，船停靠的那一段竖线附近不放（免得压在船底下露出一截）。
  Path _ripples(Size size) {
    final path = Path();
    final left = layout.bank + 10, right = size.width - layout.bank - 10;
    final count = ((right - left) * size.height / 2600).round().clamp(5, 16);
    for (var index = 0; index < count; index++) {
      final x = left + (_noise(index * 13 + 3) * .5 + .5) * (right - left);
      final y = 14 + (index + .5 + _noise(index * 17 + 5) * .35) / count * (size.height - 28);
      final width = 9 + (_noise(index * 23 + 11) * .5 + .5) * 9;
      path
        ..moveTo(x - width / 2, y)
        ..quadraticBezierTo(x - width / 4, y - 3, x, y)
        ..quadraticBezierTo(x + width / 4, y + 3, x + width / 2, y);
    }
    return path;
  }

  // 草点：两岸各撒一些，避开岸线。
  Float32List _specks(Size size) {
    final points = <double>[];
    final count = (layout.bank * size.height / 900).round();
    for (final side in [0, 1]) {
      for (var index = 0; index < count; index++) {
        final x = 6 + (_noise(index * 7 + side * 997) * .5 + .5) * (layout.bank - 20);
        points
          ..add(side == 0 ? x : size.width - x)
          ..add(6 + (_noise(index * 11 + side * 991 + 1) * .5 + .5) * (size.height - 12));
      }
    }
    return Float32List.fromList(points);
  }

  // 按整数取 [-1, 1] 的固定噪声（同一个输入总是同一个值，画面每次一样）。
  static double _noise(int value) {
    var hash = (value * 0x9E3779B1) & 0xFFFFFFFF;
    hash = ((hash ^ (hash >> 15)) * 0x85EBCA6B) & 0xFFFFFFFF;
    hash = (hash ^ (hash >> 13)) & 0xFFFF;
    return hash / 0xFFFF * 2 - 1;
  }

  @override
  bool shouldRepaint(_ScenePainter old) => !identical(old.layout, layout) || !identical(old.colors, colors);
}

// 船：俯看的一条平底小船，两头收尖，船舷一圈亮边，船舱里每个座位一块横板；水面上一团柔和的影子。行驶时船尾一侧拖两道淡淡的水痕。
class _BoatPainter extends CustomPainter {
  _BoatPainter({required this.colors, required this.capacity, required this.slot, required this.cap, required this.wake});
  final _RiverColors colors;
  final int capacity;
  final double slot, cap;
  // 水痕：正负表示往右或往左走，绝对值是浓淡。
  final double wake;

  // 画布比船身四周多出的边，留给影子与水痕。
  static const margin = 22.0;

  @override
  void paint(Canvas canvas, Size size) {
    final body = (Offset.zero & size).deflate(margin);
    if (wake != 0) {
      final strength = wake.abs(), behind = wake > 0 ? body.left : body.right, away = wake > 0 ? -1.0 : 1.0;
      final trail = Path();
      for (final (index, spread) in [(0, 5.0), (1, 11.0)]) {
        final x = behind + away * spread, inset = body.height * (.22 + index * .1);
        trail
          ..moveTo(x + away * -2, body.top + inset)
          ..quadraticBezierTo(x + away * 3, body.center.dy, x + away * -2, body.bottom - inset);
      }
      canvas.drawPath(trail, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..color = colors.foam.withValues(alpha: colors.foam.a * strength));
    }
    final hull = _hull(body);
    canvas.drawPath(hull.shift(const Offset(2, 5)), Paint()
      ..color = colors.shadow
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    canvas.drawPath(hull, Paint()..color = colors.hull);
    final inner = _hull(body.deflate(4.5));
    canvas.drawPath(inner, Paint()..color = colors.deck);
    // 座位：每个座位中间一块横板，裁在船舱里。
    canvas.save();
    canvas.clipPath(inner);
    final planks = Path();
    for (var seat = 0; seat < capacity; seat++) {
      final y = body.top + cap + slot * (seat + .5);
      planks.addRect(Rect.fromLTRB(body.left, y - 5, body.right, y + 5));
    }
    canvas.drawPath(planks, Paint()..color = colors.plank);
    canvas.restore();
    canvas.drawPath(hull, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = colors.rim);
  }

  // 船身：两头收成圆钝的尖，中段笔直。
  static Path _hull(Rect body) {
    final width = body.width, center = body.center.dx, taper = width * .95;
    return Path()
      ..moveTo(center, body.top)
      ..cubicTo(center + width * .4, body.top, body.right, body.top + taper * .45, body.right, body.top + taper)
      ..lineTo(body.right, body.bottom - taper)
      ..cubicTo(body.right, body.bottom - taper * .45, center + width * .4, body.bottom, center, body.bottom)
      ..cubicTo(center - width * .4, body.bottom, body.left, body.bottom - taper * .45, body.left, body.bottom - taper)
      ..lineTo(body.left, body.top + taper)
      ..cubicTo(body.left, body.top + taper * .45, center - width * .4, body.top, center, body.top)
      ..close();
  }

  @override
  bool shouldRepaint(_BoatPainter old) => old.wake != wake || !identical(old.colors, colors) || old.capacity != capacity || old.slot != slot;
}

// 人物徽章：圆形淡底、同色相的字（农夫过河写「农」「狼」「羊」「菜」，父子写家里的那个字），大人与小孩画一个人形；
// 小孩、孩子的徽章小一圈。按下变暗；犯规时外面圈一道警示色；收尾时跳起来（影子留在地上）。
class _Badge extends StatelessWidget {
  const _Badge({required this.person, required this.diameter, required this.colors, required this.pressed, required this.alert, required this.hop, required this.lift});
  final RiverPerson person;
  final double diameter, alert, hop, lift;
  final _RiverColors colors;
  final bool pressed;

  @override
  Widget build(BuildContext context) {
    final palette = colors.palette;
    final (fill, ink) = colors.tone(colors.hue(person));
    final glyph = switch (person.role) {
      RiverRole.farmer => '农',
      RiverRole.wolf => '狼',
      RiverRole.goat => '羊',
      RiverRole.cabbage => '菜',
      RiverRole.father || RiverRole.son => riverFamilyNames[person.family],
      RiverRole.adult || RiverRole.kid => null,
    };
    final small = person.role == RiverRole.kid || person.role == RiverRole.son;
    return Center(child: Transform.translate(
      offset: Offset(0, -hop * lift),
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: pressed ? Color.lerp(fill, palette.onSurface, palette.isDark ? .12 : .08) : fill,
          border: Border.all(color: Color.lerp(ink.withValues(alpha: palette.isDark ? .45 : .3), palette.danger, alert)!, width: 1 + alert * 1.6),
          boxShadow: [
            BoxShadow(color: colors.shadow.withValues(alpha: colors.shadow.a * (1 - hop * .5)), blurRadius: 5 + hop * 6, offset: Offset(0, 2 + hop * lift * .6)),
          ],
        ),
        alignment: Alignment.center,
        child: glyph == null
            ? CustomPaint(size: Size.square(diameter), painter: _FigurePainter(color: ink, child: small))
            : Padding(
                padding: const EdgeInsets.all(4),
                child: FittedBox(fit: BoxFit.scaleDown, child: Text(glyph, style: TextStyle(fontSize: small ? 14 : 16, fontWeight: FontWeight.w600, height: 1.1, color: ink))),
              ),
      ),
    ));
  }
}

// 人形：圆脑袋加一段圆肩（同通讯录的默认头像），裁在徽章里；小孩的脑袋相对大一点、肩窄一点。
class _FigurePainter extends CustomPainter {
  _FigurePainter({required this.color, required this.child});
  final Color color;
  final bool child;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.width, center = size.center(Offset.zero);
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: side / 2 - 1)));
    final head = child ? side * .2 : side * .17;
    final figure = Path()
      ..addOval(Rect.fromCircle(center: center + Offset(0, -side * (child ? .1 : .12)), radius: head))
      ..addOval(Rect.fromCenter(center: center + Offset(0, side * .42), width: side * (child ? .62 : .72), height: side * .56));
    canvas.drawPath(figure, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FigurePainter old) => old.color != color || old.child != child;
}
