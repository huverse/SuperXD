import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:superxd/playground/challenge/play_challenge.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/hanoi/hanoi_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';

// 汉诺塔对局页：点一根柱子拿起最上面的盘子（盘子浮到柱顶上方），再点另一根放下；也可以直接按住盘子拖到别的柱子上。
// 不合规的放法（大盘压小盘）轻震一下、盘子左右晃一晃退回原处，不算步数。
class HanoiPage extends StatefulWidget {
  const HanoiPage({super.key, required this.game, required this.store, this.seeds, this.challenge});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;
  // 挑战里的一关（题面是服务器给的）；自由模式为空。
  final PlayChallenge? challenge;

  @override
  State<HanoiPage> createState() => _HanoiPageState();
}

class _HanoiPageState extends State<HanoiPage> with SingleTickerProviderStateMixin {
  late final _session = PlaySession<HanoiPuzzle, List<HanoiMove>>(game: widget.game, rules: const HanoiRules(), store: widget.store, seeds: widget.seeds, challenge: widget.challenge);
  late List<List<int>> _pegs = hanoiStacks(_session.puzzle);
  final _moves = <HanoiMove>[];
  // 点选拿起的那根柱子。
  int? _lifted;
  // 拖动中的盘子来自哪根柱子、手指在棋盘上的位置；只跟第一根手指，按下的位置用来分点按与拖动。
  int? _dragPeg;
  Offset? _drag;
  int? _pointer;
  Offset? _pressAt;
  late final _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 360));
  int? _shakingDisk;

  static const _settle = Duration(milliseconds: 240);

  @override
  void dispose() {
    _shake.dispose();
    _session.dispose();
    super.dispose();
  }

  int get _least => hanoiMinMoves(_session.puzzle.start, _session.puzzle.target);

  void _reset() {
    _pegs = hanoiStacks(_session.puzzle);
    _moves.clear();
    _lifted = _dragPeg = null;
    _drag = null;
  }

  void _newGame(PuzzleTier? tier) => setState(() {
    _session.next(tier: tier);
    _reset();
  });

  void _restart() => setState(() {
    _session.restart();
    _reset();
  });

  void _tapPeg(int peg) {
    if (_session.finished) return;
    final lifted = _lifted;
    if (lifted == null) {
      if (_pegs[peg].isEmpty) return;
      playTick();
      setState(() => _lifted = peg);
    } else if (lifted == peg) {
      setState(() => _lifted = null);
    } else {
      _attempt(lifted, peg);
    }
  }

  void _attempt(int from, int to) {
    final move = (from: from, to: to);
    if (!hanoiLegal(_pegs, move)) {
      playRejected();
      _shakingDisk = _pegs[from].last;
      unawaited(_shake.forward(from: 0));
      setState(() => _lifted = null);
      return;
    }
    playTick();
    _session.moved();
    setState(() {
      _pegs[to].add(_pegs[from].removeLast());
      _moves.add(move);
      _lifted = null;
    });
    if (_pegs[_session.puzzle.target].length == _session.puzzle.disks) unawaited(_finish());
  }

  Future<void> _finish() async {
    final newBest = await _session.finish(moves: _moves.length, answer: [..._moves]);
    // 等最后一个盘子落定再弹结果。
    await Future<void>.delayed(_settle);
    if (!mounted) return;
    final least = _least;
    final choice = await showPlayResult(context, session: _session, newBest: newBest, detail: _moves.length == least ? '$least 步，正好最少' : '${_moves.length} 步，最少 $least 步');
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

  void _undo() {
    if (_moves.isEmpty || _session.finished) return;
    playTick();
    setState(() {
      final move = _moves.removeLast();
      _pegs[move.from].add(_pegs[move.to].removeLast());
      _lifted = null;
    });
  }

  @override
  Widget build(BuildContext context) => PlayFrame(
    session: _session,
    onNewGame: _newGame,
    onRestart: _restart,
    status: '${_moves.length} 步 · 最少 $_least 步',
    controls: [
      FilledButton.icon(onPressed: _moves.isEmpty || _session.finished ? null : _undo, icon: const CampusIcon(CampusIcons.undo), label: const Text('撤销')),
    ],
    board: LayoutBuilder(builder: (context, constraints) => _board(context, Size(math.min(constraints.maxWidth, 560), constraints.maxHeight))),
  );

  Widget _board(BuildContext context, Size area) {
    final palette = CampusPalette.of(context);
    final puzzle = _session.puzzle;
    final disks = puzzle.disks;
    final column = area.width / hanoiPegs;
    // 盘子扁平（高不超过宽的三分之一左右）；盘数少时最小盘也宽一些，不缩成圆点。
    final widest = column - 12, narrowest = widest * (disks <= 4 ? .44 : .34);
    // 盘子高度随盘数与可用高度定：柱子留一个盘子的余量，柱顶上方留拿起的位置，最下面写「目标」。
    final labelSpace = 36.0;
    final height = ((area.height - labelSpace) / (disks + 3.2)).clamp(14.0, math.min(32.0, widest / 3.2)).toDouble();
    final rod = (disks + 1.2) * height;
    final content = height * 1.8 + rod + 10 + labelSpace;
    final top = math.max(0.0, (area.height - content) / 2);
    final rodTop = top + height * 1.8;
    final base = rodTop + rod;
    final motion = MediaQuery.disableAnimationsOf(context) ? Duration.zero : _settle;

    double diskWidth(int disk) => disks == 1 ? widest : narrowest + (widest - narrowest) * disk / (disks - 1);
    int pegAt(double x) => (x / column).floor().clamp(0, hanoiPegs - 1);

    final children = <Widget>[
      // 底座与三根柱子；目标柱的柱身着激活色淡色，下面写「目标」。
      Positioned(left: 4, right: 4, top: base, height: 10, child: DecoratedBox(decoration: BoxDecoration(color: palette.outlineSubtle, borderRadius: BorderRadius.circular(5)))),
      for (var peg = 0; peg < hanoiPegs; peg++) ...[
        Positioned(
          left: column * (peg + .5) - 3, width: 6, top: rodTop, height: rod + 2,
          child: DecoratedBox(decoration: BoxDecoration(color: peg == puzzle.target ? Color.lerp(palette.outlineSubtle, palette.accent, .45) : palette.outlineSubtle, borderRadius: BorderRadius.circular(3))),
        ),
        if (peg == puzzle.target)
          Positioned(left: column * peg, width: column, top: base + 16, child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            CampusIcon(CampusIcons.flag, size: 16, color: palette.onSurfaceVariant),
            const SizedBox(width: 4),
            Text('目标', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
          ])),
      ],
    ];
    for (var peg = 0; peg < hanoiPegs; peg++) {
      for (final (level, disk) in _pegs[peg].indexed) {
        final width = diskWidth(disk);
        final top = level == _pegs[peg].length - 1;
        final dragging = top && _dragPeg == peg && _drag != null;
        final lifted = top && _lifted == peg;
        var center = Offset(column * (peg + .5), base - (level + .5) * height);
        if (lifted) center = Offset(center.dx, rodTop - height * .9);
        if (dragging) center = Offset(_drag!.dx.clamp(width / 2, area.width - width / 2), (_drag!.dy - height).clamp(height / 2, base - height / 2));
        children.add(AnimatedPositioned(
          key: ValueKey(disk),
          duration: dragging ? Duration.zero : motion,
          curve: Curves.easeOutCubic,
          left: center.dx - width / 2,
          top: center.dy - height / 2,
          width: width,
          height: height,
          child: AnimatedBuilder(
            animation: _shake,
            builder: (context, child) {
              final progress = _shakingDisk == disk && _shake.isAnimating ? _shake.value : 1.0;
              return Transform.translate(offset: Offset(math.sin(progress * math.pi * 5) * 7 * (1 - progress), 0), child: child);
            },
            child: _Disk(color: _diskColor(palette, disk, disks), raised: lifted || dragging),
          ),
        ));
      }
    }
    // 读屏：每根柱子一个按钮，读出盘子数与最上面是几号，点按同手指点柱子。
    for (var peg = 0; peg < hanoiPegs; peg++) {
      final stack = _pegs[peg];
      children.add(Positioned(left: column * peg, width: column, top: 0, bottom: 0, child: Semantics(
        container: true,
        button: true,
        label: '第${peg + 1}根柱子${peg == puzzle.target ? '，目标' : ''}，${stack.isEmpty ? '空' : '${stack.length}个盘子，最上面是${stack.last + 1}号'}${_lifted == peg ? '，已拿起' : ''}',
        onTap: () => _tapPeg(peg),
        child: const SizedBox.expand(),
      )));
    }

    // 点按与拖动按原始指针自己分（走过触摸门槛算拖动，否则松手算点按），外面垫一个手指一落下就赢下手势竞争的识别器：
    // iOS 的页面任意位置右滑返回约 18dp 就认横向拖动，用普通的拖动识别器（36dp 才认）往右拖盘子会被它抢走、整页滑走。
    return Center(child: SizedBox(width: area.width, height: area.height, child: RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(EagerGestureRecognizer.new, (_) {})},
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          if (_pointer != null) return;
          _pointer = event.pointer;
          _pressAt = event.localPosition;
        },
        onPointerMove: (event) {
          final pressAt = _pressAt;
          if (event.pointer != _pointer || pressAt == null) return;
          if (_dragPeg == null) {
            if ((event.localPosition - pressAt).distance < kTouchSlop) return;
            final peg = pegAt(pressAt.dx);
            if (_session.finished || _pegs[peg].isEmpty) {
              _pressAt = null;
              return;
            }
            setState(() {
              _lifted = null;
              _dragPeg = peg;
            });
          }
          setState(() => _drag = event.localPosition);
        },
        onPointerUp: (event) {
          if (event.pointer != _pointer) return;
          final pressAt = _pressAt;
          _pointer = _pressAt = null;
          if (_dragPeg != null) {
            _drop(pegAt);
          } else if (pressAt != null) {
            _tapPeg(pegAt(pressAt.dx));
          }
        },
        onPointerCancel: (event) {
          if (event.pointer != _pointer) return;
          _pointer = _pressAt = null;
          setState(() {
            _dragPeg = null;
            _drag = null;
          });
        },
        child: Stack(clipBehavior: Clip.none, children: children),
      ),
    )));
  }

  void _drop(int Function(double x) pegAt) {
    final from = _dragPeg, finger = _drag;
    setState(() {
      _dragPeg = null;
      _drag = null;
    });
    if (from == null || finger == null) return;
    final to = pegAt(finger.dx);
    if (to != from) _attempt(from, to);
  }

  // 盘子配色：以控件激活色为中心、色相向两边各偏 35°，小盘浅、大盘深，同一套配色里成一组相邻色（深色模式整体提亮）。
  static Color _diskColor(CampusPalette palette, int disk, int count) {
    final base = HSLColor.fromColor(palette.accent);
    final progress = count == 1 ? .5 : disk / (count - 1);
    final lightness = palette.isDark ? .74 - progress * .18 : .64 - progress * .22;
    return HSLColor.fromAHSL(1, (base.hue + (progress - .5) * 70) % 360, base.saturation.clamp(.45, .7), lightness).toColor();
  }
}

// 一个盘子：圆角胶囊，上沿略亮（同实物的受光面），细边加深一点保证浅色盘在浅底上也看得清；拿起时浮起一层柔和投影。
class _Disk extends StatelessWidget {
  const _Disk({required this.color, required this.raised});
  final Color color;
  final bool raised;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color.lerp(color, Colors.white, .22)!, color]),
          border: Border.all(color: Color.lerp(color, palette.onSurface, .25)!),
          boxShadow: [if (raised) BoxShadow(color: Colors.black.withValues(alpha: palette.isDark ? .4 : .18), blurRadius: 14, offset: const Offset(0, 6))],
        ),
      ),
    );
  }
}
