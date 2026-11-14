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

// 点灯对局页：点一格翻转它和上下左右的灯，被翻的几盏同时过渡（从当前亮度续接，连点不跳）；
// 按下的那一格底下浮一块浅色方块、松手淡出（同 iOS 按下变暗）。灯排在一张卡片上，亮灯是激活色的圆灯带一圈柔光，灭灯是灰色实心圆带细边。
// 全亮即解开：所有灯从中心向外依次亮一下，再弹结果。没有违规的点法，所以不用重震。
class LightsPage extends StatefulWidget {
  const LightsPage({super.key, required this.game, required this.store, this.seeds, this.challenge});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;
  // 挑战里的一关（题面是服务器给的）；自由模式为空。
  final PlayChallenge? challenge;

  @override
  State<LightsPage> createState() => _LightsPageState();
}

class _LightsPageState extends State<LightsPage> with TickerProviderStateMixin {
  late final _session = PlaySession<LightsPuzzle, List<int>>(game: widget.game, rules: const LightsRules(), store: widget.store, seeds: widget.seeds, challenge: widget.challenge);
  late var _lit = [..._session.puzzle.lit];
  final _presses = <int>[];
  // 翻转过渡：每格这次过渡开始时显示的亮度，随 _flip 走到 _lit 的目标；连点时从当时显示的亮度续接。
  late var _from = _targets();
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

  int get _side => _session.puzzle.side;
  // 最少几步：挑战模式没有参考解（服务器不给），就不写。
  int? get _least => _session.reference?.length;
  bool get _reduced => MediaQuery.disableAnimationsOf(context);

  List<double> _targets() => [for (final on in _lit) on ? 1.0 : 0.0];

  double _level(int cell) {
    final from = _from[cell];
    return from + ((_lit[cell] ? 1 : 0) - from) * Curves.easeOutCubic.transform(_flip.value);
  }

  // 换题、从头来：同样大小的棋盘从当前亮度过渡到新开局，换了大小直接换。
  void _reset() {
    final shown = _lit.length == _session.puzzle.lit.length ? [for (var cell = 0; cell < _lit.length; cell++) _level(cell)] : null;
    _lit = [..._session.puzzle.lit];
    _presses.clear();
    _from = shown ?? _targets();
    _pressed = null;
    _press.value = 0;
    _wave.value = 0;
    if (shown == null || _reduced) {
      _flip.value = 1;
    } else {
      unawaited(_flip.forward(from: 0));
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

  // 点一格：先把每格当前显示的亮度记成起点，再翻转，几盏一起过渡；减少动画时直接到位。
  void _flipAt(int cell) {
    _from = [for (var index = 0; index < _lit.length; index++) _level(index)];
    lightsPress(_lit, _side, cell);
    if (_reduced) {
      _flip.value = 1;
    } else {
      unawaited(_flip.forward(from: 0));
    }
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
      _flipAt(cell);
    });
    if (!_lit.contains(false)) unawaited(_finish());
  }

  void _undo() {
    if (_presses.isEmpty || _session.finished) return;
    playTick();
    setState(() => _flipAt(_presses.removeLast()));
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
    final count = _lit.length;
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
    board: PlayBoardBox(aspectRatio: 1, maxWidth: _maxPitch * (_side + 2 * _LightsLayout.inset), builder: _board),
  );

  Widget _board(BuildContext context, Size size) {
    final palette = CampusPalette.of(context);
    final side = _side;
    final layout = _LightsLayout(side, size.width);
    final pixel = 1 / MediaQuery.devicePixelRatioOf(context);
    // 热区是整张卡片按格均分（格与格之间的缝、卡片的边都算进最近的那一格）：7×7 在 360dp 上一格约 45dp。
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
            levels: [for (var cell = 0; cell < side * side; cell++) _level(cell)],
            pulses: _pulses(),
            pressed: _pressed,
            press: _press.value,
            palette: palette,
            pixel: pixel,
          )),
        ))),
        // 读屏：每格一个按钮，读出第几行第几列与亮灭，点按同手指点这一格。
        for (var cell = 0; cell < side * side; cell++)
          Positioned.fromRect(rect: layout.cellRect(cell), child: Semantics(
            container: true,
            button: true,
            label: '第${cell ~/ side + 1}行第${cell % side + 1}列，${_lit[cell] ? '亮' : '灭'}',
            onTap: _session.finished ? null : () => _tap(cell),
            child: const SizedBox.expand(),
          )),
      ])),
    );
  }
}

// 棋盘几何：卡片四周留 inset 个格距的边，里面按格均分；灯画在每格中心。
class _LightsLayout {
  _LightsLayout(this.side, double extent) : pitch = extent / (side + 2 * inset);

  static const inset = .16;
  final int side;
  final double pitch;

  double get padding => pitch * inset;
  Offset center(int cell) => Offset(padding + (cell % side + .5) * pitch, padding + (cell ~/ side + .5) * pitch);
  Rect cellRect(int cell) => Rect.fromCenter(center: center(cell), width: pitch, height: pitch);
  int cellAt(Offset point) => ((point.dy - padding) / pitch).floor().clamp(0, side - 1) * side + ((point.dx - padding) / pitch).floor().clamp(0, side - 1);
}

class _LightsPainter extends CustomPainter {
  _LightsPainter({required this.layout, required this.levels, required this.pulses, required this.pressed, required this.press, required this.palette, required this.pixel});
  final _LightsLayout layout;
  // 每盏灯显示的亮度 0–1（过渡中在两头之间）与收尾时亮一下的幅度 0–1。
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
    final pitch = layout.pitch, count = levels.length;
    final dark = palette.isDark;
    final pressed = this.pressed;
    if (pressed != null && press > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(layout.cellRect(pressed).deflate(pitch * .05), Radius.circular(pitch * .26)),
        Paint()..color = palette.surfaceSelected.withValues(alpha: press * (dark ? .9 : .85)),
      );
    }

    // 灭着的（含正在过渡的）灯拼成一条路径，填色与细边各画一次。
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
      // 收尾亮一下：灯身由里向外提亮、光晕变浓并向外铺开一点。浅色下边缘几乎不提、光晕加得少：
      // 边缘一提亮就和光晕连成一片，看着像失焦。
      final pulse = pulses[cell];
      final halo = (dark ? .45 : .32) * (1 + pulse * (dark ? .8 : .35));
      final center = layout.center(cell);
      canvas.drawCircle(center, glow, Paint()..shader = RadialGradient(
        colors: [
          tone(core + pulse * (dark ? .06 : .1), level),
          tone(body + pulse * .08, level),
          tone(rim + pulse * (dark ? .06 : .02), level),
          tone(aura, halo * level),
          tone(aura, halo * .3 * level),
          tone(aura, 0),
        ],
        stops: [0, edge * .62, edge - soft, edge, edge + (1 - edge) * (.42 + pulse * (dark ? .18 : .1)), 1],
      ).createShader(Rect.fromCircle(center: center, radius: glow)));
    }
  }

  @override
  bool shouldRepaint(_LightsPainter old) => true;
}
