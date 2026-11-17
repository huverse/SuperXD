import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/playground/challenge/play_challenge.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/lights/lights_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_tokens.dart';

// 点灯对局页：点一格，它和相邻的几格（十字或斜十字，环面绕到对边）各往亮走一级，被改的几盏同时过渡（从当前亮度续接，连点不跳）；
// 按住时这一格浮浅色方块、会被改到的几格浮更淡的方块（看得出斜十字与环面绕到哪），松手淡出（同 iOS 按下变暗）。
// 灯排在一张卡片上，亮灯是激活色的圆灯带一圈柔光，三态的暗灯是半透明的灯身、几乎不发光，灭灯是灰色实心圆带细边；
// 环面在卡片四边对着每行每列各画一小段接口，表示这一边接着对边。棋盘上方一行写这道题的规矩（形状图、三态、边连对边）。
// 全亮即解开：所有灯从中心向外依次亮一下，再弹结果。没有违规的点法，所以不用重震。
class LightsPage extends StatefulWidget {
  const LightsPage({super.key, required this.game, required this.store, this.seeds, this.first, this.challenge});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;
  // 外壳在后台出好的第一道题（自由模式；没备好或测试注入种子时为空，当场出）。
  final PlayFirst? first;
  // 挑战里的一关（题面是服务器给的）；自由模式为空。
  final PlayChallenge? challenge;

  @override
  State<LightsPage> createState() => _LightsPageState();
}

class _LightsPageState extends State<LightsPage> with TickerProviderStateMixin {
  late final _session = PlaySession<LightsPuzzle, List<int>>(game: widget.game, rules: const LightsRules(), store: widget.store, seeds: widget.seeds, first: widget.first, challenge: widget.challenge);
  late var _cells = [..._puzzle.cells];
  final _presses = <int>[];
  // 翻转过渡：每格这次过渡开始时显示的亮度与目标亮度（0 灭、1 亮，三态的暗是 0.5），随 _flip 从 _from 走到 _to；连点时从当时显示的亮度续接。
  late var _to = _targets();
  late var _from = _to;
  late final _flip = AnimationController(vsync: this, duration: const Duration(milliseconds: 180), value: 1);
  // 按下的那一格：松手后底下的浅色方块在原处淡出。
  int? _pressed;
  late final _press = AnimationController(vsync: this, duration: const Duration(milliseconds: 150));
  // 解开后的收尾：离中心越远越晚亮一下，最外一圈晚 _waveSpread 开始，每盏亮 _pulse。
  late final _wave = AnimationController(vsync: this, duration: _waveSpread + _pulse);
  late final _motion = Listenable.merge([_flip, _press, _wave]);

  static const _waveSpread = Duration(milliseconds: 360);
  static const _pulse = Duration(milliseconds: 320);
  // 一格最大的边长：3×3 在宽屏上不铺得过分大。
  static const _maxPitch = 92.0;

  @override
  void dispose() {
    _flip.dispose();
    _press.dispose();
    _wave.dispose();
    _session.dispose();
    super.dispose();
  }

  LightsPuzzle get _puzzle => _session.puzzle;
  int get _side => _puzzle.side;
  // 最少几步：挑战模式没有参考解（服务器不给），就不写。
  int? get _least => _session.reference?.length;
  bool get _reduced => MediaQuery.disableAnimationsOf(context);
  bool get _allLit => _cells.every((state) => state == _puzzle.lit);

  List<double> _targets() => [for (final state in _cells) state / _puzzle.lit];

  double _level(int cell) => _from[cell] + (_to[cell] - _from[cell]) * Curves.easeOutCubic.transform(_flip.value);

  List<double> _shown() => [for (var cell = 0; cell < _cells.length; cell++) _level(cell)];

  void _animate() {
    if (_reduced) {
      _flip.value = 1;
    } else {
      unawaited(_flip.forward(from: 0));
    }
  }

  // 换题、从头来：同样大小的棋盘从当前亮度过渡到新开局，换了大小直接换。
  void _reset() {
    final shown = _cells.length == _puzzle.cells.length ? _shown() : null;
    _cells = [..._puzzle.cells];
    _presses.clear();
    _to = _targets();
    _from = shown ?? _to;
    _pressed = null;
    _press.value = 0;
    _wave.value = 0;
    if (shown == null) {
      _flip.value = 1;
    } else {
      _animate();
    }
  }

  void _newGame(PuzzleTier? tier) => setState(() {
    _session.next(tier: tier);
    _reset();
  });

  void _restart() => setState(() {
    _session.restart();
    _reset();
  });

  // 点一格（times 下，撤销时点「级数减 1」下等于退回一下）：先把每格当前显示的亮度记成起点，再改，几盏一起过渡；减少动画时直接到位。
  void _pressAt(int cell, {int times = 1}) {
    _from = _shown();
    for (var time = 0; time < times; time++) {
      lightsPress(_puzzle, _cells, cell);
    }
    _to = _targets();
    _animate();
  }

  void _down(int cell) {
    if (_session.finished) return;
    _pressed = cell;
    _press.value = 1;
  }

  void _release() {
    if (_reduced) {
      _press.value = 0;
    } else {
      unawaited(_press.reverse());
    }
  }

  void _tap(int cell) {
    if (_session.finished) return;
    playTick();
    _session.moved();
    setState(() {
      _presses.add(cell);
      _pressAt(cell);
    });
    if (_allLit) unawaited(_finish());
  }

  void _undo() {
    if (_presses.isEmpty || _session.finished) return;
    playTick();
    setState(() => _pressAt(_presses.removeLast(), times: _puzzle.lit));
  }

  Future<void> _finish() async {
    final newBest = await _session.finish(moves: _presses.length, answer: [..._presses]);
    if (!mounted) return;
    if (!_reduced) {
      // 等最后一下的翻转走完，再从中心向外依次亮一下。
      await _flip.forward();
      await _wave.forward(from: 0);
    }
    if (!mounted) return;
    final least = _least, presses = _presses.length;
    final choice = await showPlayResult(context, session: _session, newBest: newBest, detail: least == null ? '$presses 步' : presses == least ? '$least 步，正好最少' : '$presses 步，最少 $least 步');
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

  // 收尾时每盏灯这一刻亮起的幅度 0–1：按到中心的距离错开，每盏是一段正弦起落。
  List<double> _pulses() {
    final count = _cells.length;
    if (_wave.value == 0 || _wave.value == 1) return List.filled(count, 0);
    final elapsed = _wave.value * (_waveSpread + _pulse).inMicroseconds;
    final middle = (_side - 1) / 2, farthest = math.max(1e-6, middle * math.sqrt2);
    return [
      for (var cell = 0; cell < count; cell++)
        () {
          final distance = math.sqrt(math.pow(cell ~/ _side - middle, 2) + math.pow(cell % _side - middle, 2));
          final local = (elapsed - distance / farthest * _waveSpread.inMicroseconds) / _pulse.inMicroseconds;
          return local <= 0 || local >= 1 ? 0.0 : math.sin(local * math.pi);
        }(),
    ];
  }

  @override
  Widget build(BuildContext context) => PlayFrame(
    session: _session,
    onNewGame: _newGame,
    onRestart: _restart,
    status: ['${_presses.length} 步', if (_least case final least?) '最少 $least 步'].join(' · '),
    controls: [
      FilledButton.icon(onPressed: _presses.isEmpty || _session.finished ? null : _undo, icon: const CampusIcon(CampusIcons.undo), label: const Text('撤销')),
    ],
    board: Column(children: [
      _LightsRules(puzzle: _puzzle),
      const SizedBox(height: CampusGap.medium),
      Expanded(child: PlayBoardBox(aspectRatio: 1, maxWidth: _maxPitch * (_side + 2 * _LightsLayout.insetOf(_puzzle)), builder: _board)),
    ]),
  );

  static const _stateNames = {2: ['灭', '亮'], 3: ['灭', '暗', '亮']};

  Widget _board(BuildContext context, Size size) {
    final palette = CampusPalette.of(context);
    final puzzle = _puzzle, side = _side;
    final layout = _LightsLayout(puzzle, size.width);
    final pixel = 1 / MediaQuery.devicePixelRatioOf(context);
    // 热区是整张卡片按格均分（格与格之间的缝、卡片的边都算进最近的那一格）：7×7 在 360dp 上一格约 44dp。
    // 落点按按下的那一格算，手指在容差内滑到隔壁也不翻错。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => _down(layout.cellAt(details.localPosition)),
      onTapUp: (_) {
        final cell = _pressed;
        _release();
        if (cell != null) _tap(cell);
      },
      onTapCancel: _release,
      child: CampusSurface(padding: EdgeInsets.zero, child: Stack(children: [
        Positioned.fill(child: RepaintBoundary(child: AnimatedBuilder(
          animation: _motion,
          builder: (context, _) => CustomPaint(painter: _LightsPainter(
            layout: layout,
            levels: _shown(),
            pulses: _pulses(),
            pressed: _pressed,
            press: _press.value,
            palette: palette,
            pixel: pixel,
          )),
        ))),
        // 读屏：每格一个按钮，读出第几行第几列与灭、暗、亮，点按同手指点这一格。
        for (var cell = 0; cell < side * side; cell++)
          Positioned.fromRect(rect: layout.cellRect(cell), child: Semantics(
            container: true,
            button: true,
            label: '第${cell ~/ side + 1}行第${cell % side + 1}列，${_stateNames[puzzle.states]![_cells[cell]]}',
            onTap: _session.finished ? null : () => _tap(cell),
            child: const SizedBox.expand(),
          )),
      ])),
    );
  }
}

// 棋盘上方一行写这道题的规矩：点一格会改哪几格的小图（十字或斜十字）、三态的轮换顺序、环面的边连对边。只读，不用主色。
class _LightsRules extends StatelessWidget {
  const _LightsRules({required this.puzzle});
  final LightsPuzzle puzzle;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final style = TextStyle(fontSize: CampusFontSize.secondary, color: palette.onSurfaceVariant);
    final diagonal = puzzle.shape == LightsShape.diagonal;
    final rules = [
      diagonal ? '斜十字：点一格变它和四个斜角' : '十字：点一格变它和上下左右',
      if (puzzle.states == 3) '三态：灭、暗、亮轮换',
      if (puzzle.wrap) '边连对边',
    ];
    final glyph = math.max(CampusFontSize.secondary, MediaQuery.textScalerOf(context).scale(CampusFontSize.secondary)) + CampusGap.tight;
    return Semantics(
      container: true,
      label: rules.join('；'),
      child: ExcludeSemantics(child: Wrap(alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, spacing: CampusGap.large, runSpacing: CampusGap.tight, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          CustomPaint(size: Size.square(glyph), painter: _ShapeGlyph(diagonal: diagonal, on: palette.onSurfaceVariant, off: palette.outlineSubtle)),
          const SizedBox(width: CampusGap.small),
          Text(diagonal ? '斜十字' : '十字', style: style),
        ]),
        if (puzzle.states == 3) Text('灭 → 暗 → 亮', style: style),
        if (puzzle.wrap) Text('边连对边', style: style),
      ])),
    );
  }
}

// 形状小图：3×3 个点，点一格会改到的（中间与十字或斜角）实心，其余是淡圈。
class _ShapeGlyph extends CustomPainter {
  _ShapeGlyph({required this.diagonal, required this.on, required this.off});
  final bool diagonal;
  final Color on, off;

  @override
  void paint(Canvas canvas, Size size) {
    final pitch = size.width / 3, radius = pitch * .32;
    final filled = Path(), hollow = Path();
    for (var cell = 0; cell < 9; cell++) {
      final row = cell ~/ 3, column = cell % 3;
      final reached = cell == 4 || (diagonal ? row != 1 && column != 1 : (row == 1) != (column == 1));
      (reached ? filled : hollow).addOval(Rect.fromCircle(center: Offset((column + .5) * pitch, (row + .5) * pitch), radius: radius));
    }
    canvas.drawPath(filled, Paint()..color = on);
    canvas.drawPath(hollow, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = off);
  }

  @override
  bool shouldRepaint(_ShapeGlyph old) => old.diagonal != diagonal || old.on != on || old.off != off;
}

// 棋盘几何：卡片四周留 inset 个格距的边（环面宽一点，画接口），里面按格均分；灯画在每格中心。
class _LightsLayout {
  _LightsLayout(this.puzzle, double extent) : inset = insetOf(puzzle), pitch = extent / (puzzle.side + 2 * insetOf(puzzle));

  static double insetOf(LightsPuzzle puzzle) => puzzle.wrap ? .24 : .16;
  final LightsPuzzle puzzle;
  final double inset;
  final double pitch;

  int get side => puzzle.side;
  double get padding => pitch * inset;
  double get extent => pitch * (side + 2 * inset);
  Offset center(int cell) => Offset(padding + (cell % side + .5) * pitch, padding + (cell ~/ side + .5) * pitch);
  Rect cellRect(int cell) => Rect.fromCenter(center: center(cell), width: pitch, height: pitch);
  int cellAt(Offset point) => ((point.dy - padding) / pitch).floor().clamp(0, side - 1) * side + ((point.dx - padding) / pitch).floor().clamp(0, side - 1);
}

class _LightsPainter extends CustomPainter {
  _LightsPainter({required this.layout, required this.levels, required this.pulses, required this.pressed, required this.press, required this.palette, required this.pixel});
  final _LightsLayout layout;
  // 每盏灯显示的亮度 0–1（过渡中在两头之间，三态的暗是 0.5）与收尾时亮一下的幅度 0–1。
  final List<double> levels;
  final List<double> pulses;
  final int? pressed;
  final double press;
  final CampusPalette palette;
  // 一个物理像素的逻辑尺寸：灯的边缘在渐变里留一像素的过渡当抗锯齿。
  final double pixel;

  // 灯身半径与光晕半径占格距的比例：光晕到格边正好淡完，相邻两盏的光晕不叠出亮缝。
  static const _body = .34, _glow = .5;

  @override
  void paint(Canvas canvas, Size size) {
    final pitch = layout.pitch, count = levels.length, puzzle = layout.puzzle;
    final dark = palette.isDark;
    final pressed = this.pressed;
    // 按住的那一格与会被改到的几格（环面上绕到对边的也在内）：这一格浅色方块，其余更淡，拼成两条路径各画一次。
    if (pressed != null && press > 0) {
      final own = Path(), reached = Path();
      for (final cell in lightsReach(puzzle, pressed)) {
        (cell == pressed ? own : reached).addRRect(RRect.fromRectAndRadius(layout.cellRect(cell).deflate(pitch * .05), Radius.circular(pitch * .26)));
      }
      final alpha = press * (dark ? .9 : .85);
      canvas.drawPath(own, Paint()..color = palette.surfaceSelected.withValues(alpha: alpha));
      canvas.drawPath(reached, Paint()..color = palette.surfaceSelected.withValues(alpha: alpha * .45));
    }

    // 环面：四边对着每行每列各一小段接口（上边对下边、左边对右边），拼成一条路径画。
    if (puzzle.wrap) {
      final ports = Path(), thick = math.max(2.0, layout.padding * .3), long = pitch * .34, extent = layout.extent;
      for (var index = 0; index < layout.side; index++) {
        final along = layout.padding + (index + .5) * pitch;
        final middle = layout.padding / 2;
        for (final rect in [
          Rect.fromCenter(center: Offset(along, middle), width: long, height: thick),
          Rect.fromCenter(center: Offset(along, extent - middle), width: long, height: thick),
          Rect.fromCenter(center: Offset(middle, along), width: thick, height: long),
          Rect.fromCenter(center: Offset(extent - middle, along), width: thick, height: long),
        ]) {
          ports.addRRect(RRect.fromRectAndRadius(rect, Radius.circular(thick / 2)));
        }
      }
      canvas.drawPath(ports, Paint()..color = dark ? palette.outline.withValues(alpha: .7) : Color.lerp(palette.outlineSubtle, palette.outline, .45)!);
    }

    // 灭着的（含暗的与正在过渡的）灯拼成一条路径，填色与细边各画一次。
    final radius = pitch * _body;
    final off = Path();
    for (var cell = 0; cell < count; cell++) {
      if (levels[cell] < 1) off.addOval(Rect.fromCircle(center: layout.center(cell), radius: radius));
    }
    canvas.drawPath(off, Paint()..color = dark ? Color.lerp(palette.surface, palette.backgroundTop, .55)! : Color.lerp(palette.surface, palette.outlineSubtle, .55)!);
    canvas.drawPath(off, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = dark ? palette.outlineSubtle.withValues(alpha: .85) : Color.lerp(palette.outlineSubtle, palette.outline, .18)!);

    // 亮着的灯：灯身与光晕是同一个径向渐变，一盏一次画完（光晕在格子里淡完，不经离屏贴图）。
    // 颜色从激活色推：色相不变，饱和度收在一段里，亮度由中心向边缘渐暗像灯泡；深色下中心不提到白，夜里看着亮而不刺眼。
    // 亮度 0 到 0.5 灯身由透明变实，0.5 到 1 由暗变亮、光晕出来：三态的暗灯（0.5）是不发光的实心灯，深色下压暗、浅色下发白，
    // 和灭灯（灰）、亮灯（发光）一眼分得开；两态翻转时一路走过去，看着是先显出灯身再亮起来。
    final accent = HSLColor.fromColor(palette.accent);
    final hue = accent.withSaturation(accent.saturation.clamp(.55, .8));
    Color tone(double lightness, [double alpha = 1]) => hue.withLightness(lightness.clamp(0, 1)).toColor().withValues(alpha: alpha.clamp(0, 1));
    // 亮度：中心、灯身、边缘、光晕；光晕起点比边缘透明得多，灯的轮廓保持清楚，浅底上不显得糊。
    final (core, body, rim, aura) = dark ? (.84, .72, .6, .62) : (.8, .66, .57, .6);
    final glow = pitch * _glow;
    final edge = (radius + .5) / glow, soft = pixel / glow;
    for (var cell = 0; cell < count; cell++) {
      final level = levels[cell];
      if (level <= 0) continue;
      final solid = math.min(1.0, level * 2), bright = math.max(0.0, level * 2 - 1);
      double shade(double lightness) => dark ? lightness * (.6 + .4 * bright) : lightness + (.9 - lightness) * .4 * (1 - bright);
      // 收尾亮一下：灯身由里向外提亮、光晕变浓并向外铺开一点。浅色下边缘几乎不提、光晕加得少：
      // 边缘一提亮就和光晕连成一片，看着像失焦。
      final pulse = pulses[cell];
      final halo = (dark ? .45 : .32) * (1 + pulse * (dark ? .8 : .35)) * bright * bright;
      final center = layout.center(cell);
      canvas.drawCircle(center, glow, Paint()..shader = RadialGradient(
        colors: [
          tone(shade(core) + pulse * (dark ? .06 : .1), solid),
          tone(shade(body) + pulse * .08, solid),
          tone(shade(rim) + pulse * (dark ? .06 : .02), solid),
          tone(aura, halo),
          tone(aura, halo * .3),
          tone(aura, 0),
        ],
        stops: [0, edge * .62, edge - soft, edge, edge + (1 - edge) * (.42 + pulse * (dark ? .18 : .1)), 1],
      ).createShader(Rect.fromCircle(center: center, radius: glow)));
    }
  }

  @override
  bool shouldRepaint(_LightsPainter old) => true;
}
