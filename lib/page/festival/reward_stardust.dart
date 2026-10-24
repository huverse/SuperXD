import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'reward_card.dart';
import 'reward_kit.dart';

// 开启动效「星尘」：几百颗星尘绕着中间一粒光转成一张斜看的盘（开普勒转速，里快外慢；迎着你转来的一侧略亮；沿旋度噪声场轻轻流动，像一缕缕气流），
// 中间那粒光是白芯、一圈柔晕与一道很淡的四角星芒，晕与星盘的底光自然接上，外面不画环（试过正圆环与躺在盘面里的环，都像贴上去的）；背后一层稀疏的远景星。
// 画面上只有这一样东西、节日名与两行小字。
// 点开（预备—释放）：盘收紧、越转越快，旋进去的星尘拉出运动模糊的光尾，光越来越亮；放开的那一刻那粒光本身长成卡（容器的卡形从这团光里长出来），
// 同时星尘顺着旋转的方向流出去，四成贴着卡边把轮廓描出来、其余落进卡里，卡长全时隐进卡面；没有空框、没有炸开。
// 粒子合成一次 drawRawAtlas、加色叠加。

class StardustLook extends RewardLook {
  const StardustLook();

  // 整段的秒数与放开的那一刻（时间线上的位置）。
  static const _seconds = 2.0;
  static const _release = .22;

  @override
  Duration get openLength => const Duration(milliseconds: 2000);
  @override
  double get burstAt => _release;

  @override
  List<Widget> layers(BuildContext context, RewardScene scene) {
    final t = scene.open;
    final opacity = Curves.easeOutCubic.transform(scene.enter) * (1 - Curves.easeInCubic.transform(scene.exit));
    final radius = scene.cardWidth * .5;
    final charge = scene.envelope ? Curves.easeInCubic.transform(rewardSpan(t, 0, _release)) : 1.0;
    final since = scene.envelope ? (t - _release) * _seconds : RewardDust.settled;
    final words = scene.envelope ? (1 - Curves.easeIn.transform(rewardSpan(t, 0, .14))) * opacity : 0.0;
    final lift = Offset(0, (1 - Curves.easeOutCubic.transform(scene.enter)) * 30);
    final palette = scene.palette;
    return [
      Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: RewardDustStage(scene: scene, since: since, opacity: opacity, glow: 1 + charge * .4)))),
      if (scene.envelope && t < .2) ...[
        Positioned(
          left: 24,
          right: 24,
          top: scene.center.dy - radius * .62 - 92,
          child: Opacity(opacity: words.clamp(0.0, 1.0), child: Text(scene.title, textAlign: TextAlign.center, style: TextStyle(fontFamily: rewardSerif, fontSize: 32, fontWeight: FontWeight.w600, letterSpacing: 9, color: palette.ink))),
        ),
        Positioned(
          left: 24,
          right: 24,
          top: scene.center.dy + radius * .52 + 34,
          child: Opacity(opacity: words.clamp(0.0, 1.0), child: Column(children: [
            Text('开发者送你一个红包', textAlign: TextAlign.center, style: TextStyle(fontSize: 15, letterSpacing: 2, color: palette.muted)),
            const SizedBox(height: 12),
            AnimatedBuilder(
              animation: scene.clock,
              builder: (context, _) => Text('轻触开启', style: TextStyle(fontSize: 14, letterSpacing: 4, color: palette.muted.withValues(alpha: .5 + .4 * (.5 + .5 * math.sin(scene.clock.value * 2.2))))),
            ),
          ])),
        ),
        Positioned.fromRect(rect: Rect.fromCenter(center: scene.center + lift, width: radius * 2, height: radius * 1.6), child: scene.seal(const SizedBox.expand())),
      ],
      RewardDust.card(scene, since, opacity),
      Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _DustField(scene: scene, radius: radius, charge: charge, since: since, opacity: opacity, lift: lift)))),
    ];
  }
}

// 星核与吸积盘（等点与蓄力）；放开后交给 RewardDust.condense。
class _DustField extends CustomPainter {
  _DustField({required this.scene, required this.radius, required this.charge, required this.since, required this.opacity, required this.lift}) : super(repaint: Listenable.merge([scene.clock, scene.tilt, scene.pressed]));
  final RewardScene scene;
  final double radius;
  final double charge;
  final double since;
  final double opacity;
  final Offset lift;

  @override
  void paint(Canvas canvas, Size size) {
    if (scene.reduced || opacity <= 0) return;
    final time = scene.clock.value, tilt = scene.tilt.value;
    final center = scene.center + lift;
    final press = scene.pressed.value && scene.sealed ? .96 : 1.0;
    final particles = RewardParticles();
    if (since < 0) {
      final disc = RewardDust.disc(center, radius * (1 - .42 * charge) * press, tilt);
      // 30 毫秒前的蓄力进度（按真的时间线倒推），算出这一帧的速度给光尾。
      final chargeBefore = scene.envelope ? Curves.easeInCubic.transform(rewardSpan(scene.open - .03 / StardustLook._seconds, 0, StardustLook._release)) : 1.0;
      RewardDust.accretion(canvas, particles, scene: scene, disc: disc, time: time, charge: charge, chargeBefore: chargeBefore, opacity: opacity);
      RewardDust.pearl(canvas, particles, center, heat: charge, scale: press, opacity: opacity, time: time, palette: scene.palette);
    } else {
      final disc = RewardDust.unfurl(center, radius * .58, radius * 1.1, tilt, since);
      RewardDust.condense(canvas, particles, scene: scene, since: since, opacity: opacity, origin: (mote, lag) => disc.place(mote, time - lag, 1, spun: since - lag).$1);
    }
    particles.paint(canvas);
  }

  @override
  bool shouldRepaint(_DustField oldDelegate) => true;
}

// 星尘的固定参数、斜看的星盘、吸积盘的画法、星核、放开后的流向与卡的显现节奏。
abstract final class RewardDust {
  static final motes = List.generate(700, RewardMote.new);
  // 不拆（再打开）时当作放开后很久，星尘都已落定。
  static const settled = 9.0;

  // 盘几乎侧对着你（倾角约 76°，压成一条带），手指拖动时倾角与侧倾跟着变。
  static RewardDisc disc(Offset center, double radius, Offset tilt) => RewardDisc(center, radius, 1.32 + tilt.dy * .14, -.12 + tilt.dx * .18);

  // 放开后星盘舒展开（还在转、还是斜的），星尘再从舒展的星盘上流进卡里：读起来是星系展开、落定，不是从中心炸开。
  static RewardDisc unfurl(Offset center, double from, double to, Offset tilt, double since) => disc(center, from + (to - from) * Curves.easeOutCubic.transform(rewardSpan(since, 0, .55)), tilt);

  // 放开后卡形长出来的进度（共享元素：从星核那团光里长出来）与内容浮现的进度（秒）。
  static double body(double since) => Curves.easeInOutCubic.transform(rewardSpan(since, 0, .9));
  static double content(double since) => Curves.easeOutCubic.transform(rewardSpan(since, .55, 1.1));

  // 奖品卡：放开之前在 Offstage 里排版（量大小），之后从中心长出来、内容浮现，略带一点过冲回弹（弹簧）。
  static Widget card(RewardScene scene, double since, double opacity) {
    final settle = rewardSpan(since, .55, 1.3);
    final spring = 1 + .02 * math.sin(settle * math.pi * 2) * (1 - settle);
    return Positioned.fill(child: CustomSingleChildLayout(
      delegate: RewardCenter(scene.center),
      child: Offstage(
        offstage: since <= 0,
        child: Opacity(
          opacity: (scene.envelope ? 1 - scene.exit : opacity).clamp(0.0, 1.0),
          child: Transform.scale(scale: scene.envelope ? spring : 1, child: scene.card(body: scene.envelope ? body(since) : 1, content: scene.envelope ? content(since) : 1)),
        ),
      ),
    ));
  }

  // 星盘：每颗星尘按开普勒转速转、沿旋度噪声流动，迎着你转来的一侧略亮；底下一层压扁的柔光把星尘连成盘面；蓄力时旋进去的星尘拉出运动模糊的光尾。
  static void accretion(Canvas canvas, RewardParticles particles, {required RewardScene scene, required RewardDisc disc, required double time, required double charge, required double chargeBefore, required double opacity}) {
    final palette = scene.palette;
    canvas.save();
    canvas.translate(disc.center.dx, disc.center.dy);
    canvas.rotate(disc.roll);
    canvas.scale(1, disc.squash);
    final spread = disc.radius * 1.1;
    canvas.drawCircle(Offset.zero, spread, Paint()
      ..blendMode = BlendMode.plus
      ..shader = RadialGradient(colors: [palette.light.withValues(alpha: (.2 + .16 * charge) * opacity), palette.light.withValues(alpha: .05 * opacity), palette.light.withValues(alpha: 0)], stops: const [0, .5, 1]).createShader(Rect.fromCircle(center: Offset.zero, radius: spread)));
    canvas.restore();
    for (final (index, mote) in motes.indexed) {
      final (point, depth, angle) = disc.flow(mote, time, charge);
      final before = disc.flow(mote, time - .03, chargeBefore).$1;
      final motion = point - before;
      final color = palette.dust[index % palette.dust.length];
      final alpha = ((.4 + .6 * depth) * disc.beam(angle) * mote.glow(time) * opacity).clamp(0.0, 1.0);
      if (charge > .15 && motion.distance > 2.5 && mote.grain < .35) {
        particles.add(RewardSprites.streak, point, math.min(30, 6 + motion.distance * 1.6), color.withValues(alpha: alpha * .6), rotation: motion.direction);
      } else {
        particles.add(RewardSprites.dot, point, mote.size * (1.1 + .5 * depth), color.withValues(alpha: alpha));
      }
    }
  }

  // 星核：一圈柔晕、一个白芯与一道很淡的四角星芒，随呼吸明暗；heat 越大越亮越大。
  static void pearl(Canvas canvas, RewardParticles particles, Offset center, {required double heat, required double scale, required double opacity, required double time, required RewardPalette palette}) {
    final glow = (opacity * (.9 + .1 * math.sin(time * 2.2))).clamp(0.0, 1.0);
    final halo = 64.0 * (1 + .4 * heat) * scale;
    canvas.drawCircle(center, halo, Paint()
      ..blendMode = BlendMode.plus
      ..shader = RadialGradient(colors: [palette.dust.last.withValues(alpha: (.5 + .3 * heat) * glow), palette.light.withValues(alpha: (.22 + .14 * heat) * glow), palette.light.withValues(alpha: 0)], stops: const [0, .2, 1]).createShader(Rect.fromCircle(center: center, radius: halo)));
    particles
      ..add(RewardSprites.star, center, (52 + 30 * heat) * scale, palette.dust.last.withValues(alpha: .4 * glow), rotation: time * .06)
      ..add(RewardSprites.dot, center, (20 + 18 * heat) * scale, palette.dust.last.withValues(alpha: glow));
  }

  // 放开之后：星核的光收进正在长出来的卡里（它就是卡），星尘从 origin（各自放开那一刻所在、之后还跟着星盘转的位置；lag 是往回推的秒数，用来算速度）
  // 顺着流场流出去：四成贴着卡边把轮廓描出来（先到），其余落进卡里，卡长全时隐进卡面；留在卡外的几颗慢慢飘、越来越淡。
  // 光尾与星盘上同一个规则（按这一帧的速度），放开那一刻不会从拖尾突然变成圆点。
  static void condense(Canvas canvas, RewardParticles particles, {required RewardScene scene, required double since, required double opacity, required Offset Function(RewardMote mote, double lag) origin}) {
    final time = scene.clock.value;
    final card = scene.cardRect;
    final palette = scene.palette;
    if (since < .45 && scene.envelope) {
      final fade = 1 - rewardSpan(since, 0, .45);
      pearl(canvas, particles, scene.center, heat: 1, scale: 1 + since * 1.5, opacity: opacity * fade * fade, time: time, palette: palette);
    }
    for (final (index, mote) in motes.indexed) {
      final color = palette.dust[index % palette.dust.length];
      final target = mote.target(card, time, since);
      final start = (mote.edge ? .04 : .12) + .2 * mote.delay;
      final duration = mote.edge ? .55 : .7;
      double flightAt(double moment) => scene.envelope ? Curves.easeInOutCubic.transform(rewardSpan(moment, start, start + duration)) : 1.0;
      Offset at(double progress, double lag) {
        final from = origin(mote, lag) - scene.center;
        if (progress <= 0) return scene.center + from;
        final along = Offset.lerp(from, target - scene.center, progress)!;
        final swirl = math.sin(progress * math.pi) * (.35 + .2 * mote.bend);
        final turned = Offset(along.dx * math.cos(swirl) - along.dy * math.sin(swirl), along.dx * math.sin(swirl) + along.dy * math.cos(swirl));
        // 路上顺着旋度噪声场走一点弯（一缕缕的气流），落定时归零。
        return scene.center + turned + rewardCurl(turned.dx / 90 + time * .2, turned.dy / 90 - time * .15) * 16 * math.sin(progress * math.pi);
      }
      final flight = flightAt(since);
      final point = at(flight, 0);
      final heading = point - at(flightAt(since - .03), .03);
      // 描边的星尘在卡边亮一会儿再随卡面长全隐去；卡里的落定后隐进卡面；卡外的留下来，慢慢淡到浮尘的程度。
      final settle = rewardSpan(since, start + duration + (mote.edge ? .15 : 0), start + duration + .45);
      final keep = mote.linger ? 1 - .6 * settle : 1 - settle;
      final alpha = ((.6 + .4 * math.sin(math.pi * math.min(1, flight * 1.2))) * keep * opacity * (mote.linger ? mote.glow(time) : 1) * (mote.edge ? 1.15 : 1)).clamp(0.0, 1.0);
      if (alpha <= .004) continue;
      final trail = (1 - flight) * (1 - flight);
      if (heading.distance > 2.5 && trail > .08 && mote.grain < .35) {
        particles.add(RewardSprites.streak, point, math.min(30, 6 + heading.distance * 1.6) * (.4 + .6 * trail), color.withValues(alpha: alpha * .55 * (.3 + .7 * trail)), rotation: heading.direction);
      } else {
        particles.add(RewardSprites.dot, point, mote.size * (1 + .45 * (1 - flight)) * (mote.edge ? 1.2 : 1), color.withValues(alpha: alpha));
      }
    }
  }
}

// 二维旋度噪声（curl noise）：值噪声的梯度转 90°，无散度的流场，粒子顺着走不会聚堆、像一缕缕气流。返回值大约在 −1–1。
Offset rewardCurl(double x, double y) {
  const step = .01;
  final dx = (_noise(x + step, y) - _noise(x - step, y)) / (2 * step);
  final dy = (_noise(x, y + step) - _noise(x, y - step)) / (2 * step);
  return Offset(dy, -dx) * .35;
}

double _hash(int x, int y) {
  var h = x * 374761393 + y * 668265263;
  h = (h ^ (h >> 13)) * 1274126177;
  return ((h ^ (h >> 16)) & 0xffff) / 65535;
}

double _noise(double x, double y) {
  final ix = x.floor(), iy = y.floor();
  final fx = x - ix, fy = y - iy;
  final ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy);
  final top = _hash(ix, iy) + (_hash(ix + 1, iy) - _hash(ix, iy)) * ux;
  final bottom = _hash(ix, iy + 1) + (_hash(ix + 1, iy + 1) - _hash(ix, iy + 1)) * ux;
  return top + (bottom - top) * uy;
}

// 斜看的星盘：倾角（压扁多少）与侧倾，半径。
class RewardDisc {
  RewardDisc(this.center, this.radius, double incline, this.roll) : squash = math.cos(incline), depthAxis = math.sin(incline);
  final Offset center;
  final double radius;
  final double roll;
  final double squash;
  final double depthAxis;

  // 一颗星尘在 time 时的位置与远近（0 远 1 近）：charge 越大转得越快（多转的角度是 1.8 乘 charge 的平方）；
  // spun 是放开后的秒数，放开后从蓄力末尾的转速（约每秒 24 弧度）按指数慢慢停下。
  (Offset, double) place(RewardMote mote, double time, double charge, {double spun = 0}) {
    final (point, depth, _) = flow(mote, time, charge, spun: spun);
    return (point, depth);
  }

  // 同上，另外给出这颗星尘在盘上的方位角（迎着转来的一侧略亮要用），位置叠上旋度噪声的流动。
  (Offset, double, double) flow(RewardMote mote, double time, double charge, {double spun = 0}) {
    final orbit = mote.orbit * radius;
    final boost = 1.8 * charge * charge + (spun > 0 ? 24.5 / 4 * (1 - math.exp(-4 * spun)) : 0);
    final angle = mote.phase + .22 * math.pow(1 / mote.orbit, 1.5) * time + boost / math.sqrt(mote.orbit);
    final x = orbit * math.cos(angle), y = orbit * math.sin(angle) * squash;
    final cos = math.cos(roll), sin = math.sin(roll);
    final swirl = rewardCurl(x / 70 + time * .12, y / 40 - time * .08) * 9;
    return (center + Offset(x * cos - y * sin, x * sin + y * cos) + swirl, .5 + .5 * math.sin(angle) * depthAxis, angle);
  }

  // 迎着你转来的一侧略亮（多普勒增亮的近似），远去的一侧略暗。
  double beam(double angle) => 1 + .3 * math.cos(angle + math.pi * .1);
}

// 低差异序列（Halton）：落进卡里的位置均匀铺开，不扎堆也不排成格子。
double _halton(int index, int base) {
  var fraction = 1.0, result = 0.0, rest = index + 1;
  while (rest > 0) {
    fraction /= base;
    result += fraction * (rest % base);
    rest ~/= base;
  }
  return result;
}

// 一颗星尘的固定参数（按序号的种子生成，每次一样）。
class RewardMote {
  RewardMote(int index) : this._(math.Random(index * 7349 + 11), index);
  RewardMote._(math.Random random, int index)
    : orbit = .42 + .58 * math.pow(random.nextDouble(), .8),
      phase = random.nextDouble() * math.pi * 2,
      grain = random.nextDouble(),
      twinkle = random.nextDouble(),
      delay = random.nextDouble(),
      bend = random.nextDouble() * 2 - 1,
      spread = random.nextDouble(),
      across = _halton(index, 2),
      down = _halton(index, 3),
      along = (index * .6180339887) % 1,
      edge = index % 5 < 2,
      linger = index % 13 == 3;
  // 轨道半径（星盘半径的倍数）、初始角度。
  final double orbit;
  final double phase;
  // 0–1：越大颗越大（多数很小，少数是大光点）。
  final double grain;
  final double twinkle;
  final double delay;
  final double bend;
  final double spread;
  // 落进卡里的位置（按卡宽高的比例）；edge 的贴着卡边（along 是沿卡边的位置），linger 的留在卡外。
  final double across;
  final double down;
  final double along;
  final bool edge;
  final bool linger;

  double get size => grain > .97 ? 5 + grain * 3 : 1.4 + 2.8 * math.pow(grain, 3).toDouble();

  double glow(double time) => .62 + .38 * math.sin(time * (1.2 + twinkle * 2.4) + twinkle * 40);

  // 落点：卡里均匀铺开，贴边的在卡边往里一两像素，留在卡外的在卡边往外，落定后顺着流场慢慢飘。
  Offset target(Rect card, double time, double since) {
    if (!edge && !linger) return Offset(card.left + 16 + (card.width - 32) * across, card.top + 16 + (card.height - 32) * down);
    final (point, normal) = _onOutline(card, rewardCardRadius, along);
    if (!linger) return point - normal * (1 + 3 * spread);
    final drift = rewardCurl(point.dx / 120 + time * .05, point.dy / 120 - time * .04) * 14 * rewardSpan(since, .8, 3);
    return point + normal * (10 + 34 * spread) + drift;
  }
}

// 圆角矩形轮廓上的点与外法线：along 0–1 沿周长走一圈（从上边左端起顺时针）。
(Offset, Offset) _onOutline(Rect rect, double radius, double along) {
  final straightX = rect.width - 2 * radius, straightY = rect.height - 2 * radius, arc = math.pi * radius / 2;
  var left = along * (2 * straightX + 2 * straightY + 4 * arc);
  (Offset, Offset) corner(Offset center, double start) {
    final angle = start + left / radius;
    final normal = Offset(math.cos(angle), math.sin(angle));
    return (center + normal * radius, normal);
  }
  if (left < straightX) return (Offset(rect.left + radius + left, rect.top), const Offset(0, -1));
  if ((left -= straightX) < arc) return corner(Offset(rect.right - radius, rect.top + radius), -math.pi / 2);
  if ((left -= arc) < straightY) return (Offset(rect.right, rect.top + radius + left), const Offset(1, 0));
  if ((left -= straightY) < arc) return corner(Offset(rect.right - radius, rect.bottom - radius), 0);
  if ((left -= arc) < straightX) return (Offset(rect.right - radius - left, rect.bottom), const Offset(0, 1));
  if ((left -= straightX) < arc) return corner(Offset(rect.left + radius, rect.bottom - radius), math.pi / 2);
  if ((left -= arc) < straightY) return (Offset(rect.left, rect.bottom - radius - left), const Offset(-1, 0));
  left -= straightY;
  return corner(Offset(rect.left + radius, rect.top + radius), math.pi);
}

// 浮层的底：主题的「房间」色压暗下面的页面，中间一团很淡的光（东西在发光、照亮了房间），一层稀疏的远景星（慢慢闪，倾斜时错开一点）；
// 放开的那一下，一团光从中心溢出来再退去（不是闪白、没有冲击波）。
class RewardDustStage extends CustomPainter {
  RewardDustStage({required this.scene, required this.since, required this.opacity, this.glow = 1}) : super(repaint: Listenable.merge([scene.clock, scene.tilt]));
  final RewardScene scene;
  final double since;
  final double opacity;
  final double glow;

  static final _stars = List.generate(40, (index) {
    final random = math.Random(index * 5197 + 7);
    return (random.nextDouble(), random.nextDouble(), random.nextDouble());
  });

  @override
  void paint(Canvas canvas, Size size) {
    final palette = scene.palette;
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.night.withValues(alpha: rewardScrim * opacity));
    if (scene.reduced) return;
    final center = scene.center;
    final room = size.shortestSide * 1.05;
    canvas.drawCircle(center, room, Paint()..shader = RadialGradient(colors: [palette.light.withValues(alpha: .14 * glow * opacity), palette.light.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: center, radius: room)));
    final stars = RewardParticles();
    final time = scene.clock.value, tilt = scene.tilt.value;
    for (final (x, y, phase) in _stars) {
      final twinkle = .4 + .6 * (.5 + .5 * math.sin(time * (.5 + phase * 1.4) + phase * 50));
      stars.add(RewardSprites.dot, Offset(x * size.width, y * size.height) + tilt * 4, 1.6 + phase * 1.8, palette.dust.first.withValues(alpha: (.4 * twinkle * opacity).clamp(0.0, 1.0)));
    }
    stars.paint(canvas);
    if (since <= 0 || !scene.envelope) return;
    final bloom = Curves.easeOutCubic.transform(rewardSpan(since, 0, .8));
    final strength = math.sin(math.pi * rewardSpan(since, -.05, .95));
    if (strength <= 0) return;
    final reach = 60 + scene.size.height * .8 * bloom;
    canvas.drawCircle(center, reach, Paint()
      ..blendMode = BlendMode.plus
      ..shader = RadialGradient(colors: [palette.dust.last.withValues(alpha: .26 * strength * opacity), palette.light.withValues(alpha: .2 * strength * opacity), palette.light.withValues(alpha: 0)], stops: const [0, .35, 1]).createShader(Rect.fromCircle(center: center, radius: reach)));
  }

  @override
  bool shouldRepaint(RewardDustStage oldDelegate) => true;
}
