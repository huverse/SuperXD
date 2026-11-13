import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/flash/flash_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';

// 亮之前先暗一下、一轮点齐后停一下、点错后亮着答案的时长（测试按它推进时钟）；亮着的时长在题面里。
const flashLead = Duration(milliseconds: 450);
const flashHold = Duration(milliseconds: 500);
const flashReveal = Duration(milliseconds: 1200);

// 一次尝试走过的阶段：开始前、暗一下、亮着、作答、点错后亮答案、这一轮点齐、全部解开。
enum _Phase { ready, lead, showing, input, reveal, passed, solved }

// 记忆闪光对局页：先点棋盘上的「开始」（计时从这里起），每次先暗一下，再同时亮起这一组，亮够题面给的时长熄灭，熄灭后才能点。
// 点对的格保持点亮（激活色）；点错的格标警示色打叉并轻震，同时亮出漏掉的格，停一会儿换这一轮的下一组重来。
// 亮起与熄灭是游戏内容不是装饰：减少动画时照样亮、照样灭，只是不渐变。阶段用 Timer 计时，不用 AnimationController
// （减少动画时它的时长会被压成二十分之一，图案就一闪而过）。切到后台时正在亮的这一组作废，回来重新暗一下再亮。
// 读屏：每格一个按钮读行列与亮灭；棋盘下的一行提示是播报区，亮起时把亮的格逐个念出来，读屏用户听完再点。
class FlashPage extends StatefulWidget {
  const FlashPage({super.key, required this.game, required this.store, this.seeds});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;

  @override
  State<FlashPage> createState() => _FlashPageState();
}

class _FlashPageState extends State<FlashPage> with TickerProviderStateMixin, WidgetsBindingObserver {
  late final _session = PlaySession<FlashPuzzle, List<List<int>>>(game: widget.game, rules: const FlashRules(), store: widget.store, seeds: widget.seeds);
  var _phase = _Phase.ready;
  // 第几轮、这一轮第几次尝试（从 0 数）与这一局点错的次数：点齐或点错的那一下就记上，下一次亮哪一组按它取（同规则的 flashPattern）。
  var _round = 0, _tries = 0, _mistakes = 0;
  // 这一次的图案、点对的格（按点的先后）与点错的那一格；换下一组时先淡掉再清。
  var _target = <int>[];
  var _hits = <int>{};
  int? _wrong;
  Timer? _timer;
  // 切到后台时正在暗、正在亮或正在等下一组：回到前台重新暗一下再亮。
  var _interrupted = false;
  // 图案亮起的程度；最新一下（点对的格，或点错的格连同亮出的答案）出现的程度；这一次的标记整体的程度（换下一组时淡出）。
  late final _flash = AnimationController(vsync: this, duration: _fade);
  late final _mark = AnimationController(vsync: this, duration: _fade);
  late final _answer = AnimationController(vsync: this, duration: _fade, value: 1);
  // 按下的那一格：盖一层淡墨色（同按下变暗），松手淡出。
  int? _pressed;
  late final _press = AnimationController(vsync: this, duration: const Duration(milliseconds: 150));
  // 解开后的收尾：从中心一圈一圈往外亮一下，最外一圈晚 _waveSpread 开始，每圈亮 _pulse。
  late final _wave = AnimationController(vsync: this, duration: _waveSpread + _pulse);
  late final _motion = Listenable.merge([_flash, _mark, _answer, _press, _wave]);

  static const _fade = Duration(milliseconds: 140);
  static const _waveSpread = Duration(milliseconds: 360);
  static const _pulse = Duration(milliseconds: 320);
  // 一格最大的边长：3×3 在宽屏上不铺得过分大。
  static const _maxPitch = 88.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _flash.dispose();
    _mark.dispose();
    _answer.dispose();
    _press.dispose();
    _wave.dispose();
    _session.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_interrupted) return;
      _interrupted = false;
      _show();
    } else if (const [_Phase.lead, _Phase.showing, _Phase.reveal, _Phase.passed].contains(_phase)) {
      _timer?.cancel();
      _interrupted = true;
    }
  }

  FlashPuzzle get _puzzle => _session.puzzle;
  int get _side => _puzzle.side;
  bool get _reduced => MediaQuery.disableAnimationsOf(context);

  // 亮起熄灭与标记出现：平时渐变，减少动画时直接到位。
  void _fadeTo(AnimationController controller, double target) {
    if (_reduced) {
      controller.value = target;
    } else {
      unawaited(controller.animateTo(target));
    }
  }

  void _appear() {
    if (_reduced) {
      _mark.value = 1;
    } else {
      unawaited(_mark.forward(from: 0));
    }
  }

  void _schedule(Duration delay, VoidCallback next) {
    _timer?.cancel();
    _timer = Timer(delay, next);
  }

  // 换题、从头来：停掉等着的下一步，回到开始前。
  void _reset() {
    _timer?.cancel();
    _interrupted = false;
    _phase = _Phase.ready;
    _round = _tries = _mistakes = 0;
    _target = [];
    _hits = {};
    _wrong = null;
    _pressed = null;
    for (final controller in [_flash, _mark, _press, _wave]) {
      controller.value = 0;
    }
    _answer.value = 1;
  }

  void _newGame(PuzzleTier? tier) => setState(() {
    _session.next(tier: tier);
    _reset();
  });

  void _restart() => setState(() {
    _session.restart();
    _reset();
  });

  void _start() {
    if (_phase != _Phase.ready) return;
    playTick();
    _session.moved();
    _show();
  }

  // 暗一下再亮：上一次的标记淡掉，flashLead 后换上这一次的图案亮起，亮够题面给的时长熄灭、开始作答。
  void _show() {
    setState(() => _phase = _Phase.lead);
    _fadeTo(_answer, 0);
    _fadeTo(_flash, 0);
    _schedule(flashLead, () {
      setState(() {
        _target = flashPattern(_puzzle, _round, _tries);
        _hits = {};
        _wrong = null;
        _phase = _Phase.showing;
      });
      _answer.value = 1;
      _mark.value = 0;
      _fadeTo(_flash, 1);
      _schedule(Duration(milliseconds: _puzzle.showMillis), () {
        setState(() => _phase = _Phase.input);
        _fadeTo(_flash, 0);
      });
    });
  }

  // 只有作答时按下才算：亮着、暗着时点了不响应、不震。
  void _down(int cell) {
    _pressed = _phase == _Phase.input ? cell : null;
    if (_pressed != null) _press.value = 1;
  }

  void _release() {
    if (_reduced) {
      _press.value = 0;
    } else {
      unawaited(_press.reverse());
    }
  }

  void _tap(int cell) {
    if (_phase != _Phase.input) return;
    switch (flashTap(_target, _hits, cell)) {
      case FlashTap.repeated:
        return;
      case FlashTap.hit:
        playTick();
        setState(() {
          _hits.add(cell);
        });
        _appear();
      case FlashTap.cleared:
        playTick();
        setState(() {
          _hits.add(cell);
          _round++;
          _tries = 0;
          _phase = _round == _puzzle.rounds.length ? _Phase.solved : _Phase.passed;
        });
        _appear();
        if (_phase == _Phase.solved) {
          unawaited(_finish());
        } else {
          _schedule(flashHold, _show);
        }
      case FlashTap.missed:
        playRejected();
        setState(() {
          _wrong = cell;
          _mistakes++;
          _tries++;
          _phase = _Phase.reveal;
        });
        _appear();
        _schedule(flashReveal, _show);
    }
  }

  Future<void> _finish() async {
    final newBest = await _session.finish();
    if (!mounted) return;
    if (!_reduced) {
      // 等最后一格亮好，再从中心一圈一圈往外亮一下。
      await _mark.forward();
      await _wave.forward(from: 0);
    }
    if (!mounted) return;
    final mistakes = _mistakes;
    final choice = await showPlayResult(context, session: _session, newBest: newBest, detail: '${_puzzle.rounds.length} 轮 · ${mistakes == 0 ? '一次没错' : '点错 $mistakes 次'}');
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

  // 收尾时每一圈这一刻亮一下的幅度 0–1：从中心那圈起依次错开，每圈是一段正弦起落。
  List<double> _pulses(int rings) {
    if (_wave.value == 0 || _wave.value == 1) return List.filled(rings, 0);
    final elapsed = _wave.value * (_waveSpread + _pulse).inMicroseconds;
    return [
      for (var ring = 0; ring < rings; ring++)
        () {
          final local = (elapsed - ring / math.max(1, rings - 1) * _waveSpread.inMicroseconds) / _pulse.inMicroseconds;
          return local <= 0 || local >= 1 ? 0.0 : math.sin(local * math.pi);
        }(),
    ];
  }

  String _cellName(int cell) => '第${cell ~/ _side + 1}行第${cell % _side + 1}列';

  String _cellState(int cell) => switch (_phase) {
    _Phase.showing when _target.contains(cell) => '亮',
    _ when _hits.contains(cell) => '已点亮',
    _ when cell == _wrong => '点错了',
    _Phase.reveal when _target.contains(cell) => '应该亮',
    _ => '未点亮',
  };

  // 棋盘下的提示（看得见的短句）与读屏播报（亮着时逐个念出亮的格）。
  String get _hint => switch (_phase) {
    _Phase.ready => '记住亮起的格，再点出来',
    _Phase.lead || _Phase.showing => '记住亮起的格',
    _Phase.input => '点出刚才亮的格',
    _Phase.reveal => '点错了，换一组重来',
    _Phase.passed => '这一轮全对',
    _Phase.solved => '全部记对了',
  };

  String get _announcement => _phase == _Phase.showing ? '亮起 ${_target.length} 格：${_target.map(_cellName).join('、')}' : _hint;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final rounds = _puzzle.rounds.length;
    return PlayFrame(
      session: _session,
      onNewGame: _newGame,
      onRestart: _restart,
      status: '第 ${math.min(_round + 1, rounds)}/$rounds 轮 · 点错 $_mistakes 次',
      board: Column(children: [
        Expanded(child: PlayBoardBox(aspectRatio: 1, maxWidth: _maxPitch * (_side + 2 * _FlashLayout.inset), builder: _board)),
        const SizedBox(height: 12),
        Semantics(
          container: true,
          liveRegion: true,
          label: _announcement,
          child: ExcludeSemantics(child: Text(_hint, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant))),
        ),
      ]),
    );
  }

  Widget _board(BuildContext context, Size size) {
    final palette = CampusPalette.of(context);
    final side = _side;
    final layout = _FlashLayout(side, size.width);
    // 点错后：点对的都已停稳，漏掉的格与点错的格一起出现；没点错时最新点对的那一格在出现。
    final missed = _wrong == null ? const <int>[] : [for (final cell in _target) if (!_hits.contains(cell)) cell];
    final fresh = _wrong == null ? _hits.lastOrNull : null;
    // 热区是整张卡片按格均分（格与格之间的缝、卡片的边都算进最近的那一格）：6×6 在 360dp 上一格约 52dp。
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
          builder: (context, _) => CustomPaint(painter: _FlashPainter(
            layout: layout,
            target: _target,
            flash: _flash.value,
            settled: [for (final cell in _hits) if (cell != fresh) cell],
            fresh: fresh,
            missed: missed,
            wrong: _wrong,
            mark: _mark.value,
            answer: _answer.value,
            pressed: _pressed,
            press: _press.value,
            pulses: _pulses(layout.rings),
            palette: palette,
          )),
        ))),
        // 读屏：每格一个按钮，读出第几行第几列与亮灭；只有作答时能点。
        for (var cell = 0; cell < side * side; cell++)
          Positioned.fromRect(rect: layout.cellRect(cell), child: Semantics(
            container: true,
            button: true,
            label: '${_cellName(cell)}，${_cellState(cell)}',
            onTap: _phase == _Phase.input ? () => _tap(cell) : null,
            child: const SizedBox.expand(),
          )),
        if (_phase == _Phase.ready)
          Center(child: FilledButton.icon(style: campusProminent, onPressed: _start, icon: const CampusIcon(CampusIcons.resume), label: const Text('开始'))),
      ])),
    );
  }
}

// 棋盘几何：卡片四周留 inset 个格距的边，里面按格均分；每格画一块圆角方块，四边各缩一点留出缝。
class _FlashLayout {
  _FlashLayout(this.side, double extent) : pitch = extent / (side + 2 * inset);

  static const inset = .16;
  final int side;
  final double pitch;

  double get padding => pitch * inset;
  // 收尾时一圈一圈亮：圈数（偶数边长时最里一圈是中间 2×2）。
  int get rings => (side + 1) ~/ 2;
  Offset center(int cell) => Offset(padding + (cell % side + .5) * pitch, padding + (cell ~/ side + .5) * pitch);
  Rect cellRect(int cell) => Rect.fromCenter(center: center(cell), width: pitch, height: pitch);
  RRect tile(int cell) => RRect.fromRectAndRadius(cellRect(cell).deflate(pitch * .07), Radius.circular(pitch * .2));
  int cellAt(Offset point) => ((point.dy - padding) / pitch).floor().clamp(0, side - 1) * side + ((point.dx - padding) / pitch).floor().clamp(0, side - 1);
  // 第几圈：到棋盘中心的横竖距离取大的那个。
  int ring(int cell) => math.max((cell ~/ side - (side - 1) / 2).abs(), (cell % side - (side - 1) / 2).abs()).floor();
}

class _FlashPainter extends CustomPainter {
  _FlashPainter({
    required this.layout,
    required this.target,
    required this.flash,
    required this.settled,
    required this.fresh,
    required this.missed,
    required this.wrong,
    required this.mark,
    required this.answer,
    required this.pressed,
    required this.press,
    required this.pulses,
    required this.palette,
  });
  final _FlashLayout layout;
  // 这一次的图案与它亮起的程度 0–1。
  final List<int> target;
  final double flash;
  // 这一次的标记：停稳的点对的格、正在出现的最新点对的一格、点错后亮出的漏掉的格与点错的格；
  // mark 是最新一下出现的程度，answer 是这一层整体的程度（换下一组时淡出）。
  final List<int> settled;
  final int? fresh;
  final List<int> missed;
  final int? wrong;
  final double mark;
  final double answer;
  final int? pressed;
  final double press;
  // 收尾时每一圈亮一下的幅度 0–1。
  final List<double> pulses;
  final CampusPalette palette;

  // 同一种样子的格拼成一条路径，一次画完。
  Path _tiles(Iterable<int> cells) {
    final path = Path();
    for (final cell in cells) {
      path.addRRect(layout.tile(cell));
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final dark = palette.isDark;
    final count = layout.side * layout.side;
    final accent = palette.accent;
    // 暗着的格：同点灯的灭灯，底色加一圈细边。
    final all = _tiles([for (var cell = 0; cell < count; cell++) cell]);
    canvas.drawPath(all, Paint()..color = dark ? Color.lerp(palette.surface, palette.backgroundTop, .55)! : Color.lerp(palette.surface, palette.outlineSubtle, .55)!);
    canvas.drawPath(all, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = dark ? palette.outlineSubtle.withValues(alpha: .85) : Color.lerp(palette.outlineSubtle, palette.outline, .18)!);
    final pressed = this.pressed;
    if (pressed != null && press > 0) canvas.drawRRect(layout.tile(pressed), Paint()..color = palette.onSurface.withValues(alpha: press * (dark ? .14 : .08)));

    if (flash > 0) canvas.drawPath(_tiles(target), Paint()..color = accent.withValues(alpha: flash));
    if (answer > 0) {
      canvas.drawPath(_tiles(settled), Paint()..color = accent.withValues(alpha: answer));
      final shown = answer * mark;
      final fresh = this.fresh, wrong = this.wrong;
      if (fresh != null) canvas.drawRRect(layout.tile(fresh), Paint()..color = accent.withValues(alpha: shown));
      // 漏掉的格：淡激活色铺底加激活色的边，和点对的实心格分得开。
      if (missed.isNotEmpty) {
        final ghosts = _tiles(missed);
        canvas.drawPath(ghosts, Paint()..color = accent.withValues(alpha: shown * (dark ? .32 : .26)));
        canvas.drawPath(ghosts, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = accent.withValues(alpha: shown));
      }
      // 点错的格：警示红底上一个叉（形状本身也说明点错了，不只靠颜色）。
      if (wrong != null) {
        final tile = layout.tile(wrong);
        final center = tile.center, arm = tile.width * .17;
        canvas.drawRRect(tile, Paint()..color = palette.dangerFill.withValues(alpha: shown));
        canvas.drawPath(
          Path()
            ..moveTo(center.dx - arm, center.dy - arm)
            ..lineTo(center.dx + arm, center.dy + arm)
            ..moveTo(center.dx + arm, center.dy - arm)
            ..lineTo(center.dx - arm, center.dy + arm),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = tile.width * .08
            ..strokeCap = StrokeCap.round
            ..color = palette.onDanger.withValues(alpha: shown),
        );
      }
    }

    // 收尾：每一圈的格拼成一条路径，盖一层提亮的激活色（暗着的格亮成浅激活色，点亮的格更亮一下）。
    final glow = Color.lerp(accent, palette.onPrimary, .35)!;
    for (var ring = 0; ring < pulses.length; ring++) {
      if (pulses[ring] <= 0) continue;
      canvas.drawPath(_tiles([for (var cell = 0; cell < count; cell++) if (layout.ring(cell) == ring) cell]), Paint()..color = glow.withValues(alpha: pulses[ring] * .9));
    }
  }

  @override
  bool shouldRepaint(_FlashPainter old) => true;
}
