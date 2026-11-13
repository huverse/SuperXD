import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/play_result.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/knights/knights_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 人名按座位依次叫天干（不用真实人名）；计数与人数的说法。
const knightsNames = ['甲', '乙', '丙', '丁', '戊', '己'];
const _numbers = ['零', '一', '两', '三', '四', '五', '六'];

// 一句话按结构说成口语（题面只存结构），说话人自己说成「我」。分成几段，只在段与段之间换行：
// 窄屏两行时按字均分会把「至少」「同一类人」这样的词拆到两行，按意思断开读起来顺。
List<String> knightsPhrases(KnightsClaim claim, int speaker, int people) {
  String who(int person) => person == speaker ? '我' : knightsNames[person];
  final (first, second) = (claim.first, claim.second);
  final we = '我们${_numbers[people]}个人';
  return switch (claim.kind) {
    KnightsClaimKind.knight => ['${who(first)}是骑士。'],
    KnightsClaimKind.knave => ['${who(first)}是无赖。'],
    KnightsClaimKind.same => ['我和${who(first)}', '是同一类人。'],
    KnightsClaimKind.different => ['我和${who(first)}', '不是同一类人。'],
    KnightsClaimKind.exactly when first == 0 => [we, '全是无赖。'],
    KnightsClaimKind.exactly when first == people => [we, '全是骑士。'],
    KnightsClaimKind.exactly => ['$we里', '恰好有${_numbers[first]}个骑士。'],
    KnightsClaimKind.atLeast => ['$we里', '至少有${_numbers[first]}个骑士。'],
    KnightsClaimKind.atMost => ['$we里', '最多只有${_numbers[first]}个骑士。'],
    KnightsClaimKind.implies => ['如果${who(first)}是骑士，', '那么${who(second)}就是无赖。'],
    // 说话人在里面时「我」放前面（小的下标在前只是编码的写法）。
    KnightsClaimKind.eitherKnave => [
      first == speaker ? '我和${who(second)}' : second == speaker ? '我和${who(first)}' : '${who(first)}和${who(second)}',
      '至少有一个是无赖。',
    ],
    KnightsClaimKind.wouldSay => ['${who(first)}会说', '${who(second)}是无赖。'],
  };
}

String knightsSentence(KnightsClaim claim, int speaker, int people) => knightsPhrases(claim, speaker, people).join();

// 解开后的收尾：每张卡片绕横轴翻一下 _flipEach，自上而下依次错开 _flipGap（6 张一共约 1 秒）。
const _flipEach = 460, _flipGap = 110;
// 卡片区左右伸到页边：判错时卡片左右晃、解开时翻转带透视会比原来宽一点，不让滚动区的边把它切掉。
const _bleed = 16.0;

// 骑士与无赖对局页：每人一张卡片（头像、名字、他说的话）；卡片右上「骑士」「无赖」两个标签直接选，再点一次选中的取消。
// 选标签而不点整张卡循环：一步到位不用记循环顺序，卡片多时上下滑也不会误改，读屏也是两个现成的带选中状态的按钮。
// 全部定了就判：对了卡片依次翻一下再弹结果；不对不给答案，只把「话的真假和他的身份对不上」的人标警示色、轻震并晃一下。
class KnightsPage extends StatefulWidget {
  const KnightsPage({super.key, required this.game, required this.store, this.seeds});
  final PlaygroundGame game;
  final PlaygroundStore store;
  // 测试用：固定出题种子。
  final int Function()? seeds;

  @override
  State<KnightsPage> createState() => _KnightsPageState();
}

class _KnightsPageState extends State<KnightsPage> with TickerProviderStateMixin {
  static const _rules = KnightsRules();
  late final _session = PlaySession<KnightsPuzzle, List<bool>>(game: widget.game, rules: _rules, store: widget.store, seeds: widget.seeds);
  // 每人的标记：null 是未定，true 骑士，false 无赖。
  late var _marks = List<bool?>.filled(_puzzle.people, null);
  // 每一步改了谁、改之前是什么，撤销按步退回。
  final _history = <(int, bool?)>[];
  // 全部定了却不成立时，话的真假和身份对不上的人；改了任何一个标记就重新算。
  var _mismatches = <int>{};
  // 这一局判错过几次（结果里写）。
  var _wrongs = 0;
  final _scroll = ScrollController();
  late final _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  late final _flip = AnimationController(vsync: this);

  @override
  void dispose() {
    _shake.dispose();
    _flip.dispose();
    _scroll.dispose();
    _session.dispose();
    super.dispose();
  }

  KnightsPuzzle get _puzzle => _session.puzzle;
  bool get _still => MediaQuery.disableAnimationsOf(context);
  int get _knights => _marks.indexed.fold(0, (mask, entry) => entry.$2 == true ? mask | 1 << entry.$1 : mask);

  // 换题、从头来：先清自己的标记与动画，再交给 session，最后按新题的人数摆空标记。
  void _clear() {
    _history.clear();
    _mismatches = {};
    _wrongs = 0;
    _shake.value = 0;
    _flip.value = 0;
  }

  void _newGame(PuzzleTier? tier) {
    setState(() {
      _clear();
      _session.next(tier: tier);
      _marks = List.filled(_puzzle.people, null);
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _restart() => setState(() {
    _clear();
    _session.restart();
    _marks = List.filled(_puzzle.people, null);
  });

  // ---------- 标记与判定 ----------

  void _mark(int person, bool? mark) {
    if (_session.finished || _marks[person] == mark) return;
    playTick();
    _session.moved();
    setState(() {
      _history.add((person, _marks[person]));
      _marks[person] = mark;
    });
    _judge(alert: true);
  }

  void _undo() {
    if (_history.isEmpty || _session.finished) return;
    playTick();
    setState(() {
      final (person, previous) = _history.removeLast();
      _marks[person] = previous;
    });
    // 退回到的局面判过了：对不上的照样标出来，不再震。
    _judge(alert: false);
  }

  // 全部定了就按规则判：成立即解开；不成立只标出话和身份对不上的人（题目唯一，所以一定有），alert 时轻震、晃一下并记一次判错。
  void _judge({required bool alert}) {
    final complete = !_marks.contains(null);
    final mismatches = complete ? knightsMismatches(_puzzle, _knights).toSet() : <int>{};
    setState(() => _mismatches = mismatches);
    if (!complete) return;
    if (_rules.solved(_puzzle, [for (final mark in _marks) mark!])) {
      unawaited(_finish());
      return;
    }
    if (!alert) return;
    _wrongs++;
    playRejected();
    if (!_still) unawaited(_shake.forward(from: 0));
  }

  Future<void> _finish() async {
    final newBest = await _session.finish();
    if (!mounted) return;
    // 卡片自上而下依次翻一下，翻完再弹结果；减少动画时直接弹。
    if (!_still) await _flip.animateTo(1, duration: Duration(milliseconds: _flipEach + (_puzzle.people - 1) * _flipGap));
    if (!mounted) return;
    final people = _puzzle.people;
    final choice = await showPlayResult(context, session: _session, newBest: newBest, detail: '$people 人 · ${_wrongs == 0 ? '一次就对' : '判错 $_wrongs 次'}');
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
    status: '已定 ${_marks.where((mark) => mark != null).length}/${_puzzle.people}',
    controls: [
      FilledButton.icon(onPressed: _history.isEmpty || _session.finished ? null : _undo, icon: const CampusIcon(CampusIcons.undo), label: const Text('撤销')),
    ],
    board: LayoutBuilder(builder: (context, constraints) => OverflowBox(
      minWidth: constraints.maxWidth + 2 * _bleed,
      maxWidth: constraints.maxWidth + 2 * _bleed,
      child: CampusScrollFade(child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(horizontal: _bleed, vertical: 4),
        // 放得下时卡片在中间（同其他游戏的棋盘居中），放不下时从上往下滚。
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: math.max(0, constraints.maxHeight - 8)),
          child: Center(child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var person = 0; person < _puzzle.people; person++) ...[
                if (person > 0) const SizedBox(height: 12),
                // 晃动与翻转只改变换：卡片自成一层，动画时只重新合成、不重画里面的字与头像。
                _animated(person, RepaintBoundary(child: _card(context, person))),
              ],
            ]),
          )),
        ),
      )),
    )),
  );

  // 判错时对不上的卡片左右晃一下（越晃越小）；解开时依次绕横轴翻一下，翻过一半换成正面接着转回来（同一面朝上，不露镜像的背面），中途轻轻抬起。
  Widget _animated(int person, Widget card) => AnimatedBuilder(
    animation: Listenable.merge([_shake, _flip]),
    child: card,
    builder: (context, child) {
      final shaking = _shake.isAnimating && _mismatches.contains(person);
      final progress = ((_flip.value * (_flipEach + (_puzzle.people - 1) * _flipGap) - person * _flipGap) / _flipEach).clamp(0.0, 1.0);
      if (!shaking && (progress == 0 || progress == 1)) return child!;
      final turn = Curves.easeInOutCubic.transform(progress) * math.pi;
      // 透视取得浅：卡片宽，透视深了近的一边会伸出页边很多。
      final transform = Matrix4.identity()
        ..setEntry(3, 2, .0007)
        ..rotateX(turn > math.pi / 2 ? turn - math.pi : turn)
        ..scaleByDouble(1 + .035 * math.sin(progress * math.pi), 1 + .035 * math.sin(progress * math.pi), 1, 1);
      final offset = shaking ? math.sin(_shake.value * math.pi * 5) * 8 * (1 - _shake.value) : 0.0;
      return Transform.translate(offset: Offset(offset, 0), child: Transform(alignment: Alignment.center, transform: transform, child: child));
    },
  );

  Widget _card(BuildContext context, int person) {
    final palette = CampusPalette.of(context);
    final mark = _marks[person];
    final mismatch = _mismatches.contains(person);
    final name = knightsNames[person];
    final phrases = knightsPhrases(_puzzle.claims[person], person, _puzzle.people);
    final duration = _still ? Duration.zero : const Duration(milliseconds: 150);
    final markLabel = switch (mark) {
      null => '未定',
      true => '骑士',
      false => '无赖',
    };
    final speech = TextStyle(fontSize: 16, fontWeight: FontWeight.w500, height: 1.5, color: palette.onSurface);
    // 解开后标签照常显示选中（禁用的样子会盖掉选中色），点了不动（_mark 里拦）。
    return Semantics(
      container: true,
      label: '$name说：${phrases.join()} 标记：$markLabel${mismatch ? '，这句话和他的身份对不上' : ''}',
      child: Stack(children: [
        CampusSurface(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              ExcludeSemantics(child: AnimatedSwitcher(
                duration: duration,
                transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: ScaleTransition(scale: Tween(begin: .86, end: 1.0).animate(animation), child: child)),
                child: CustomPaint(
                  key: ValueKey((mark, mismatch)),
                  size: const Size.square(_KnightsAvatar.size),
                  painter: _KnightsAvatar(mark: mark, mismatch: mismatch, palette: palette),
                ),
              )),
              const SizedBox(width: 12),
              Expanded(child: Row(children: [
                ExcludeSemantics(child: Text(name, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: palette.onSurface))),
                const SizedBox(width: 8),
                // 大字号下两个标签并排放不下时上下排，仍靠右。
                Expanded(child: Align(alignment: AlignmentDirectional.centerEnd, child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 4, children: [
                  CampusGlassChip(
                    label: '骑士',
                    selected: mark == true,
                    leading: CampusIcon(CampusIcons.knight, size: 18, color: palette.accentText),
                    onSelected: (selected) => _mark(person, selected ? true : null),
                  ),
                  CampusGlassChip(
                    label: '无赖',
                    selected: mark == false,
                    leading: CampusIcon(CampusIcons.knave, size: 18, color: palette.onSurfaceVariant),
                    onSelected: (selected) => _mark(person, selected ? false : null),
                  ),
                ]))),
              ])),
            ]),
            const SizedBox(height: 8),
            ExcludeSemantics(child: _Bubble(
              // 对不上时气泡铺一层淡警示色：深色下的 danger 是浅粉，铺在深卡片上发灰，改用破坏性按钮的红底。
              color: mismatch
                  ? (palette.isDark ? palette.dangerFill.withValues(alpha: .24) : palette.danger.withValues(alpha: .09))
                  : palette.surfaceSelected.withValues(alpha: palette.isDark ? .55 : .6),
              duration: duration,
              // 气泡的小尖对着头像中心。
              tail: _KnightsAvatar.size / 2,
              child: Wrap(children: [for (final phrase in phrases) Text(phrase, style: speech)]),
            )),
          ]),
        ),
        // 对不上：卡片描一圈警示色的边（盖在卡片边上，不改卡片排版）。
        Positioned.fill(child: IgnorePointer(child: AnimatedOpacity(
          opacity: mismatch ? 1 : 0,
          duration: duration,
          child: DecoratedBox(decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: palette.danger.withValues(alpha: palette.isDark ? .8 : .7), width: 1.5),
          )),
        ))),
      ]),
    );
  }
}

// 说话的气泡：圆角块加一个朝上的小尖（对着头像），底色变化时过渡。
class _Bubble extends StatelessWidget {
  const _Bubble({required this.color, required this.duration, required this.tail, required this.child});
  final Color color;
  final Duration duration;
  final double tail;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<Color?>(
    tween: ColorTween(end: color),
    duration: duration,
    builder: (context, color, child) => CustomPaint(painter: _BubblePainter(color: color!, tail: tail), child: child),
    child: Padding(padding: const EdgeInsets.fromLTRB(14, 10 + _BubblePainter.tailHeight, 14, 10), child: child),
  );
}

class _BubblePainter extends CustomPainter {
  const _BubblePainter({required this.color, required this.tail});
  final Color color;
  final double tail;

  static const tailHeight = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
    final body = RRect.fromRectAndRadius(Rect.fromLTRB(0, tailHeight, size.width, size.height), const Radius.circular(16));
    // 小尖：底边两头顺着弧线并进气泡，尖上收圆，不是生硬的三角。
    final path = Path()
      ..addRRect(body)
      ..moveTo(tail - 10, tailHeight + 1)
      ..cubicTo(tail - 5, tailHeight, tail - 2.5, 2.5, tail - .8, .6)
      ..quadraticBezierTo(tail, 0, tail + .8, .6)
      ..cubicTo(tail + 2.5, 2.5, tail + 5, tailHeight, tail + 10, tailHeight + 1)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_BubblePainter old) => old.color != color || old.tail != tail;
}

// 头像：圆形底加半身剪影。未定是中性灰；骑士是激活色底、白色剪影，头上戴 T 字面甲的头盔、顶上一撮羽饰；
// 无赖是墨色底（文字主色）、纸色剪影，眼睛上蒙一条黑（深色模式下是白）色的眼罩，脑后飘两根带子。对不上时右下角挂一个警示色的「!」。
class _KnightsAvatar extends CustomPainter {
  const _KnightsAvatar({required this.mark, required this.mismatch, required this.palette});
  final bool? mark;
  final bool mismatch;
  final CampusPalette palette;

  static const size = 48.0;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final side = canvasSize.width;
    final dark = palette.isDark;
    final (background, figure) = switch (mark) {
      null => (palette.surfaceSelected, Color.lerp(palette.surfaceSelected, palette.onSurfaceVariant, dark ? .42 : .38)!),
      true => (dark ? Color.lerp(palette.accent, palette.onSurface, .1)! : palette.accent, Colors.white),
      false => (palette.primary, palette.surface),
    };
    final circle = Rect.fromLTWH(0, 0, side, side);
    // 剪影只画在底色圆上（srcATop，在 48 见方的小图层里合成）：裁剪的话圆边上两层抗锯齿会叠出一道底色的毛边。
    canvas.saveLayer(circle, Paint());
    canvas.drawOval(circle, Paint()..color = background);
    // 肩膀离圆边留一圈底色：剪影和卡片几乎同色，贴着圆边就把圆的下沿吃掉了。
    canvas.clipPath(Path()..addOval(circle.deflate(side * .05)));
    final center = side / 2;
    final paint = Paint()
      ..color = figure
      ..blendMode = BlendMode.srcATop;
    // 肩膀：下半个椭圆，被圆裁掉底；头与肩之间留一道缝（同系统联系人头像）。头盔、眼罩是布尔运算出来的路径，各画各的（并进别的路径会丢掉挖空）。
    canvas.drawOval(Rect.fromLTRB(side * .17, side * .69, side * .83, side * 1.28), paint);
    final headCenter = Offset(center, side * .42), head = side * .165;
    if (mark == true) {
      canvas.drawPath(_helmet(side), paint);
    } else {
      canvas.drawCircle(headCenter, head, paint);
    }
    if (mark == false) {
      canvas.drawPath(_mask(headCenter, head), Paint()
        ..color = palette.onSurface
        ..blendMode = BlendMode.srcATop);
    }
    canvas.restore();
    if (mismatch) _badge(canvas, side);
  }

  // 头盔：圆顶、两腮向下略收、下沿平，挖出 T 字面甲的缝；顶上一根向后扬起的羽饰。
  static Path _helmet(double side) {
    final center = side / 2, radius = side * .185, dome = side * .38, bottom = side * .61;
    final shell = Path()
      ..moveTo(center - radius, dome)
      ..arcTo(Rect.fromCircle(center: Offset(center, dome), radius: radius), math.pi, math.pi, false)
      ..lineTo(center + radius * .94, side * .53)
      ..quadraticBezierTo(center + radius * .86, bottom, center + radius * .52, bottom)
      ..lineTo(center - radius * .52, bottom)
      ..quadraticBezierTo(center - radius * .86, bottom, center - radius * .94, side * .53)
      ..close();
    final visor = Path()
      ..addRRect(RRect.fromRectAndRadius(Rect.fromLTRB(center - radius * .74, side * .405, center + radius * .74, side * .46), Radius.circular(side * .028)))
      ..addRRect(RRect.fromRectAndRadius(Rect.fromLTRB(center - side * .03, side * .43, center + side * .03, side * .575), Radius.circular(side * .03)));
    final plume = Path()
      ..moveTo(center - side * .045, side * .215)
      ..cubicTo(center - side * .055, side * .11, center + side * .1, side * .06, center + side * .21, side * .12)
      ..cubicTo(center + side * .12, side * .12, center + side * .06, side * .145, center + side * .045, side * .21)
      ..close();
    return Path.combine(PathOperation.union, Path.combine(PathOperation.difference, shell, visor), plume);
  }

  // 眼罩：横过眼睛的一条，两端略翘、中间鼻梁处向上收，挖出两个眼洞；脑后两根短带子。
  static Path _mask(Offset head, double radius) {
    final (x, y) = (head.dx, head.dy);
    Offset at(double dx, double dy) => Offset(x + dx * radius, y + dy * radius);
    final left = at(-1.24, -.3), right = at(1.24, -.3);
    final band = Path()
      ..moveTo(left.dx, left.dy)
      ..quadraticBezierTo(at(-.85, -.56).dx, at(-.85, -.56).dy, at(0, -.46).dx, at(0, -.46).dy)
      ..quadraticBezierTo(at(.85, -.56).dx, at(.85, -.56).dy, right.dx, right.dy)
      ..quadraticBezierTo(at(1, .34).dx, at(1, .34).dy, at(.32, .26).dx, at(.32, .26).dy)
      ..quadraticBezierTo(at(0, .04).dx, at(0, .04).dy, at(-.32, .26).dx, at(-.32, .26).dy)
      ..quadraticBezierTo(at(-1, .34).dx, at(-1, .34).dy, left.dx, left.dy)
      ..close();
    final eyes = Path()
      ..addOval(Rect.fromCenter(center: at(-.46, -.12), width: radius * .46, height: radius * .3))
      ..addOval(Rect.fromCenter(center: at(.46, -.12), width: radius * .46, height: radius * .3));
    final ribbons = Path()
      ..moveTo(at(1.12, -.34).dx, at(1.12, -.34).dy)
      ..quadraticBezierTo(at(1.5, -.3).dx, at(1.5, -.3).dy, at(1.72, .1).dx, at(1.72, .1).dy)
      ..quadraticBezierTo(at(1.42, -.04).dx, at(1.42, -.04).dy, at(1.14, -.08).dx, at(1.14, -.08).dy)
      ..close()
      ..moveTo(at(1.1, -.2).dx, at(1.1, -.2).dy)
      ..quadraticBezierTo(at(1.4, .1).dx, at(1.4, .1).dy, at(1.44, .5).dx, at(1.44, .5).dy)
      ..quadraticBezierTo(at(1.22, .2).dx, at(1.22, .2).dy, at(1.04, .04).dx, at(1.04, .04).dy)
      ..close();
    return Path.combine(PathOperation.union, Path.combine(PathOperation.difference, band, eyes), ribbons);
  }

  // 警示角标：卡片底色的一圈描边隔开头像，警示红底上一个白色「!」（形状本身也说明有问题，不只靠颜色）。
  void _badge(Canvas canvas, double side) {
    final center = Offset(side * .85, side * .85), radius = side * .17;
    canvas.drawCircle(center, radius + 2, Paint()..color = palette.surface);
    canvas.drawCircle(center, radius, Paint()..color = palette.dangerFill);
    final mark = Path()
      ..addRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: center.translate(0, -radius * .2), width: radius * .26, height: radius * .78), Radius.circular(radius * .13)))
      ..addOval(Rect.fromCircle(center: center.translate(0, radius * .48), radius: radius * .15));
    canvas.drawPath(mark, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_KnightsAvatar old) => old.mark != mark || old.mismatch != mismatch || old.palette != palette;
}
