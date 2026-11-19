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
import 'package:superxd/theme/campus_tone.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';

// 汉诺塔对局页：点一根柱子拿起最上面的盘子（盘子浮到柱顶上方），再点另一根放下；也可以直接按住盘子拖到别的柱子上。
// [人工决策-2026-11-17 14:17:05] 拿起盘子时不亮出能放的柱子（柱身不变色、读屏不读「可以放」）：用户认为那等于直接告诉哪里合规；方向不许时的提示条照旧。
// 棋盘上方是目标的缩略图；相邻、循环的挪法在底座下面画箭头。不合规的放法轻震、盘子左右晃一晃退回原处，不算步数；方向不许时提示条说规矩。
// [人工决策-2026-11-19 13:20:14] 盘子分得清、目标看得出是一组（用户截图：盘子都是一色系的相邻色，大小相近的分不出、目标与实物不像一组，选「拉开色相＋标号＋目标同款」）：
// 每个盘子一个颜色，按大小从红到紫排成一串等距色相（OKLCH 同明度，换色相看起来一样亮），盘子正中写号码（1 最小，同读屏的「几号」）；
// 目标缩略图用同一个盘子（同色、同号、同描边与渐变）按比例缩小，号码照写。
class HanoiPage extends StatefulWidget {
  const HanoiPage({super.key, required this.game, required this.store, this.seeds, this.first, this.challenge});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;
  // 外壳在后台出好的第一道题（自由模式；没备好或测试注入种子时为空，当场出）。
  final PlayFirst? first;
  // 挑战里的一关（题面是服务器给的）；自由模式为空。
  final PlayChallenge? challenge;

  @override
  State<HanoiPage> createState() => _HanoiPageState();
}

class _HanoiPageState extends State<HanoiPage> with SingleTickerProviderStateMixin {
  late final _session = PlaySession<HanoiPuzzle, List<HanoiMove>>(game: widget.game, rules: const HanoiRules(), store: widget.store, seeds: widget.seeds, first: widget.first, challenge: widget.challenge);
  late List<List<int>> _pegs = hanoiStacks(_puzzle.pegs, _puzzle.start);
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
  // 这道题的最少步数（自由模式就是参考解的步数，挑战里按规则搜一遍），换题时清掉。
  int? _leastCache;

  static const _settle = Duration(milliseconds: 240);

  @override
  void dispose() {
    _shake.dispose();
    _session.dispose();
    super.dispose();
  }

  HanoiPuzzle get _puzzle => _session.puzzle;
  int get _least => _leastCache ??= _session.reference?.length ?? hanoiMinMoves(_puzzle);

  // 挑战里碎片改目标（人工决策见 challenge_rules.dart）：不画目标、柱子标 ①②③④，玩家按门上的数自己算；全部盘子到了同一根柱（不是开局那根）就交。
  bool get _hidden => widget.challenge?.goal ?? false;

  bool get _gathered {
    final puzzle = _puzzle;
    if (!_hidden) return hanoiSameStacks(_pegs, hanoiStacks(puzzle.pegs, puzzle.goal));
    final start = puzzle.start.every((peg) => peg == puzzle.start.first) ? puzzle.start.first : null;
    return [for (var peg = 0; peg < puzzle.pegs; peg++) if (peg != start && _pegs[peg].length == puzzle.disks) peg].isNotEmpty;
  }

  void _reset() {
    hideCampusToast();
    _pegs = hanoiStacks(_puzzle.pegs, _puzzle.start);
    _moves.clear();
    _lifted = _dragPeg = null;
    _drag = null;
    _leastCache = null;
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
    if (!hanoiLegal(_puzzle, _pegs, move)) {
      playRejected();
      _shakingDisk = _pegs[from].last;
      unawaited(_shake.forward(from: 0));
      setState(() => _lifted = null);
      // 方向不许（相邻、循环）时提示条说规矩；只是大盘压小盘的照旧只晃一下。
      if (!hanoiAllowed(_puzzle, from, to)) showCampusToast(context, _puzzle.variant == HanoiVariant.adjacent ? '只能挪到旁边的柱子' : '只能顺着箭头挪到下一根');
      return;
    }
    hideCampusToast();
    playTick();
    _session.moved();
    setState(() {
      _pegs[to].add(_pegs[from].removeLast());
      _moves.add(move);
      _lifted = null;
    });
    if (_gathered) unawaited(_finish());
  }

  Future<void> _finish() async {
    final newBest = await _session.finish(moves: _moves.length, answer: [..._moves]);
    // 等最后一个盘子落定再弹结果。
    await Future<void>.delayed(_settle);
    if (!mounted) return;
    final least = _least;
    final choice = await showPlayResult(context, session: _session, newBest: newBest, detail: _hidden ? '${_moves.length} 步' : _moves.length == least ? '$least 步，正好最少' : '${_moves.length} 步，最少 $least 步');
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
    hideCampusToast();
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
    status: _hidden ? '${_moves.length} 步' : '${_moves.length} 步 · 最少 $_least 步',
    controls: [
      FilledButton.icon(onPressed: _moves.isEmpty || _session.finished ? null : _undo, icon: const CampusIcon(CampusIcons.undo), label: const Text('撤销')),
    ],
    board: LayoutBuilder(builder: (context, constraints) {
      final width = math.min(constraints.maxWidth, 560.0);
      return Column(children: [
        if (!_hidden) ...[_goal(context, width), const SizedBox(height: CampusGap.medium)],
        Expanded(child: LayoutBuilder(builder: (context, inner) => _board(context, Size(width, inner.maxHeight)))),
      ]);
    }),
  );

  // 盘子宽度：盘数少时最小盘也宽一些，不缩成圆点。棋盘与目标缩略图同一个比例。
  static double _narrowest(int disks, double widest) => widest * (disks <= 4 ? .44 : .38);

  static double _diskWidth(int disk, int disks, double widest) {
    final narrowest = _narrowest(disks, widest);
    return disks == 1 ? widest : narrowest + (widest - narrowest) * disk / (disks - 1);
  }

  // 目标的缩略图：旗子与「目标」，右边一排小柱子摆着目标局面（同一个盘子按比例缩小、同色同号，人工决策见文件头 11-19 那条），读屏念出每根柱子上从下到上是几号。
  Widget _goal(BuildContext context, double width) {
    final palette = CampusPalette.of(context);
    final puzzle = _puzzle;
    final goal = hanoiStacks(puzzle.pegs, puzzle.goal);
    // 盘子高到写得下 14 号的号码；底座与柱子同棋盘一个颜色、按比例细一些。
    final miniWidth = math.min(width * .62, 60.0 * puzzle.pegs), column = miniWidth / puzzle.pegs, widest = column - 6;
    final diskHeight = _goalDiskHeight(context), rod = puzzle.disks * diskHeight + 6, height = rod + 4;
    final tower = puzzle.tower;
    final label = tower != null
        ? '目标，全部叠到第${tower + 1}根柱子'
        : '目标，${[for (var peg = 0; peg < puzzle.pegs; peg++) if (goal[peg].isNotEmpty) '第${peg + 1}根柱子从下到上是${goal[peg].map((disk) => '${disk + 1}号').join('、')}'].join('，')}';
    return Semantics(
      container: true,
      label: label,
      child: ExcludeSemantics(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        CampusIcon(CampusIcons.flag, size: 16, color: palette.onSurfaceVariant),
        const SizedBox(width: CampusGap.tight),
        Text('目标', style: TextStyle(fontSize: CampusFontSize.secondary, color: palette.onSurfaceVariant)),
        const SizedBox(width: CampusGap.medium),
        SizedBox(width: miniWidth, height: height, child: Stack(children: [
          Positioned(left: 0, right: 0, bottom: 0, height: 4, child: DecoratedBox(decoration: BoxDecoration(color: palette.outlineSubtle, borderRadius: BorderRadius.circular(2)))),
          for (var peg = 0; peg < puzzle.pegs; peg++) ...[
            Positioned(left: column * (peg + .5) - 1.5, width: 3, bottom: 4, height: rod, child: DecoratedBox(decoration: BoxDecoration(color: palette.outlineSubtle, borderRadius: BorderRadius.circular(1.5)))),
            for (final (level, disk) in goal[peg].indexed)
              Positioned(
                left: column * (peg + .5) - _diskWidth(disk, puzzle.disks, widest) / 2,
                width: _diskWidth(disk, puzzle.disks, widest),
                bottom: 4 + level * diskHeight,
                height: diskHeight,
                child: _Disk(color: _diskColor(palette, disk, puzzle.disks), label: disk + 1, raised: false),
              ),
          ],
        ])),
      ])),
    );
  }

  Widget _board(BuildContext context, Size area) {
    final palette = CampusPalette.of(context);
    final puzzle = _puzzle;
    final pegs = puzzle.pegs, disks = puzzle.disks;
    final column = area.width / pegs;
    final widest = column - 10;
    // 底座下面：相邻、循环的箭头（循环多一条从最后一根绕回第一根的线），挑战藏目标时的柱子编号。
    final arrows = switch (puzzle.variant) {
      HanoiVariant.classic => 0.0,
      HanoiVariant.adjacent => 18.0,
      HanoiVariant.cyclic => 26.0,
    };
    final below = arrows + (_hidden ? 28.0 : 0.0) + 6;
    // 盘子高度随盘数与可用高度定：柱子留一个盘子的余量，柱顶上方留拿起的位置；扁平，高不超过 32、不超过最大盘宽的 1/3.2 与最小盘宽的 1/1.5（四柱多盘时最小盘不成圆点）。
    final height = ((area.height - below - 10) / (disks + 3.0)).clamp(14.0, math.min(32.0, math.min(widest / 3.2, _narrowest(disks, widest) / 1.5))).toDouble();
    final rod = (disks + 1.2) * height;
    final content = height * 1.8 + rod + 10 + below;
    final top = math.max(0.0, (area.height - content) / 2);
    final rodTop = top + height * 1.8;
    final base = rodTop + rod;
    final motion = MediaQuery.disableAnimationsOf(context) ? Duration.zero : _settle;

    int pegAt(double x) => (x / column).floor().clamp(0, pegs - 1);

    final children = <Widget>[
      // 底座与柱子。
      Positioned(left: 4, right: 4, top: base, height: 10, child: DecoratedBox(decoration: BoxDecoration(color: palette.outlineSubtle, borderRadius: BorderRadius.circular(5)))),
      for (var peg = 0; peg < pegs; peg++) ...[
        Positioned(
          left: column * (peg + .5) - 3, width: 6, top: rodTop, height: rod + 2,
          child: DecoratedBox(decoration: BoxDecoration(color: palette.outlineSubtle, borderRadius: BorderRadius.circular(3))),
        ),
        if (_hidden)
          Positioned(left: column * peg, width: column, top: base + 10 + arrows, child: Text('①②③④'[peg], textAlign: TextAlign.center, style: TextStyle(fontSize: CampusFontSize.body, color: palette.onSurfaceVariant))),
      ],
      if (puzzle.variant != HanoiVariant.classic)
        Positioned(
          left: 0, width: area.width, top: base + 10, height: arrows,
          child: Semantics(
            label: puzzle.variant == HanoiVariant.adjacent ? '只能挪到旁边的柱子' : '只能顺着箭头挪到下一根，最后一根挪回第一根',
            child: CustomPaint(painter: _RulePainter(variant: puzzle.variant, pegs: pegs, color: palette.onSurfaceVariant)),
          ),
        ),
    ];
    for (var peg = 0; peg < pegs; peg++) {
      for (final (level, disk) in _pegs[peg].indexed) {
        final width = _diskWidth(disk, disks, widest);
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
            child: _Disk(color: _diskColor(palette, disk, disks), label: disk + 1, raised: lifted || dragging),
          ),
        ));
      }
    }
    // 读屏：每根柱子一个按钮，读出盘子数与最上面是几号，点按同手指点柱子。
    for (var peg = 0; peg < pegs; peg++) {
      final stack = _pegs[peg];
      children.add(Positioned(left: column * peg, width: column, top: 0, bottom: 0, child: Semantics(
        container: true,
        button: true,
        label: '第${peg + 1}根柱子，${stack.isEmpty ? '空' : '${stack.length}个盘子，最上面是${stack.last + 1}号'}${_lifted == peg ? '，已拿起' : ''}',
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

  // 盘子配色（人工决策见文件头 11-19 那条）：从小到大按 OKLCH 色相从红（约 29°）到紫（约 310°）等距排开，明度、彩度一样，
  // 盘数少时相邻两个隔得更开；颜色够浅，号码一律用深色写（深浅两种模式都对得上 4.5:1 以上）。
  static Color _diskColor(CampusPalette palette, int disk, int count) {
    final progress = count == 1 ? 0.0 : disk / (count - 1);
    return CampusTone.degrees(29 + progress * 281).pick(palette.isDark ? .76 : .8, .15);
  }

  // 目标里的盘子高：写得下一行 14 号的号码（跟着字号放大）。
  static double _goalDiskHeight(BuildContext context) => MediaQuery.textScalerOf(context).scale(14) + 3;
}

// 底座下面的挪法箭头（拼成一条路径一次画完）：相邻是相邻两根之间的双向箭头；循环是指向下一根的单向箭头，再从最后一根下面绕回第一根。
class _RulePainter extends CustomPainter {
  const _RulePainter({required this.variant, required this.pegs, required this.color});
  final HanoiVariant variant;
  final int pegs;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final column = size.width / pegs, line = 8.0, path = Path();
    void head(Offset tip, Offset toward) {
      final back = tip - toward * 6, side = Offset(-toward.dy, toward.dx) * 4;
      path
        ..moveTo((back + side).dx, (back + side).dy)
        ..lineTo(tip.dx, tip.dy)
        ..lineTo((back - side).dx, (back - side).dy);
    }

    for (var peg = 0; peg + 1 < pegs; peg++) {
      final left = Offset(column * (peg + .5) + 14, line), right = Offset(column * (peg + 1.5) - 14, line);
      path
        ..moveTo(left.dx, left.dy)
        ..lineTo(right.dx, right.dy);
      head(right, const Offset(1, 0));
      if (variant == HanoiVariant.adjacent) head(left, const Offset(-1, 0));
    }
    if (variant == HanoiVariant.cyclic) {
      final first = column * .5, last = column * (pegs - .5), bottom = line + 12;
      path
        ..moveTo(last, line + 2)
        ..lineTo(last, bottom)
        ..lineTo(first, bottom)
        ..lineTo(first, line + 2);
      head(Offset(first, line + 2), const Offset(0, -1));
    }
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_RulePainter oldDelegate) => oldDelegate.variant != variant || oldDelegate.pegs != pegs || oldDelegate.color != color;
}

// 一个盘子：圆角胶囊，上沿略亮（同实物的受光面），细边加深一点保证浅色盘在浅底上也看得清，正中写号码；拿起时浮起一层柔和投影。
// 棋盘与目标缩略图共用（人工决策见文件头 11-19 那条）。号码放不下时整体缩小，不挤出盘子。
class _Disk extends StatelessWidget {
  const _Disk({required this.color, required this.label, required this.raised});
  final Color color;
  final int label;
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
        // 号码不单独读：读屏按柱子读「从下到上是几号」。盘子都是浅色，深浅两种模式都用深色字（深色模式下深色的是 backgroundBottom）。
        child: ExcludeSemantics(child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text('$label', style: TextStyle(fontSize: 14, height: 1, fontWeight: FontWeight.w600, color: palette.isDark ? palette.backgroundBottom : palette.onSurface)),
        )))),
      ),
    );
  }
}
