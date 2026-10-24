import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

// 礼花（同 canvas-confetti 与 iMessage「庆祝」的做法，参数按纸片的真实运动调）：每片纸是一个小长方形，正反两面不同色，
// 喷出后受线性空气阻力（速度按 e^-kt 衰减，竖直方向趋于终端速度 g/k）与重力，越慢越左右飘摆；绕自身一条斜轴翻转（看到的宽度按 cos 变窄、
// 翻到背面换背面色，迎光时提亮），同时在平面内慢慢转。位置都是时间的闭式解，不逐帧累积：与帧率无关、可以拿任意时刻画（测试与录屏一致）。
// 所有纸片合成一次 drawVertices。只画、不感知业务；什么时候放、放多少、什么颜色由调用方给。

// 一次喷发：从 origin（相对画布的 0–1 坐标）朝 angle（弧度，0 向右、-π/2 向上）方向、在 spread 张角内喷出 count 片，速度 speed 区间（逻辑像素每秒）。
class ConfettiBurst {
  const ConfettiBurst({required this.origin, required this.angle, this.spread = math.pi / 3, this.count = 60, this.speed = const (520.0, 980.0), this.delay = Duration.zero});
  final Offset origin;
  final double angle;
  final double spread;
  final int count;
  final (double, double) speed;
  final Duration delay;
}

// 一种纸的颜色：正面与背面（背面略暗，翻过来时看得出是纸的另一面）。
class ConfettiPaper {
  const ConfettiPaper(this.front, this.back);
  final Color front;
  final Color back;
}

class _Piece {
  _Piece({required this.origin, required this.velocity, required this.drag, required this.size, required this.paper, required this.tilt, required this.tiltSpeed, required this.spin, required this.spinSpeed, required this.sway, required this.swaySpeed, required this.swayPhase, required this.life, required this.delay});
  final Offset origin;
  final Offset velocity;
  final double drag;
  final Size size;
  final ConfettiPaper paper;
  final double tilt;
  final double tiltSpeed;
  final double spin;
  final double spinSpeed;
  final double sway;
  final double swaySpeed;
  final double swayPhase;
  final double life;
  final double delay;
}

// 一场礼花：按种子生成全部纸片，之后只按时间取位置。gravity 为逻辑像素每二次方秒。
class ConfettiShow {
  ConfettiShow({required List<ConfettiBurst> bursts, required List<ConfettiPaper> papers, int seed = 7, this.gravity = 1150}) {
    final random = math.Random(seed);
    double between(double low, double high) => low + random.nextDouble() * (high - low);
    for (final burst in bursts) {
      for (var index = 0; index < burst.count; index++) {
        final angle = burst.angle + between(-burst.spread / 2, burst.spread / 2);
        // 速度偏向区间低端（多数慢、少数冲得远），喷得更有层次。
        final speed = burst.speed.$1 + math.pow(random.nextDouble(), 1.6) * (burst.speed.$2 - burst.speed.$1);
        final long = between(9, 15);
        _pieces.add(_Piece(
          origin: burst.origin,
          velocity: Offset(math.cos(angle), math.sin(angle)) * speed,
          drag: between(2.1, 3.2),
          size: Size(long * between(.45, .62), long),
          paper: papers[random.nextInt(papers.length)],
          tilt: between(0, math.pi * 2),
          tiltSpeed: between(5, 13) * (random.nextBool() ? 1 : -1),
          spin: between(0, math.pi * 2),
          spinSpeed: between(-3.2, 3.2),
          sway: between(14, 34),
          swaySpeed: between(3.2, 6.4),
          swayPhase: between(0, math.pi * 2),
          life: between(2.4, 3.4),
          delay: burst.delay.inMicroseconds / 1e6,
        ));
      }
    }
  }

  final double gravity;
  final _pieces = <_Piece>[];

  // 全部纸片落完（含各自的延迟）要多久。
  Duration get length => Duration(microseconds: (_pieces.fold<double>(0, (longest, piece) => math.max(longest, piece.delay + piece.life)) * 1e6).round());

  void paint(Canvas canvas, Size size, double seconds) {
    final positions = <double>[], colors = <int>[];
    for (final piece in _pieces) {
      final t = seconds - piece.delay;
      if (t <= 0 || t >= piece.life) continue;
      final k = piece.drag, decay = math.exp(-k * t);
      // 线性阻力的闭式解：水平 x = v/k·(1−e^−kt)；竖直再加重力项 g/k·(t − (1−e^−kt)/k)。
      final reach = (1 - decay) / k;
      final x = piece.origin.dx * size.width + piece.velocity.dx * reach + piece.sway * math.sin(piece.swaySpeed * t + piece.swayPhase) * (1 - decay);
      final y = piece.origin.dy * size.height + piece.velocity.dy * reach + gravity / k * (t - reach);
      final turn = piece.tilt + piece.tiltSpeed * t;
      final face = math.cos(turn);
      final spin = piece.spin + piece.spinSpeed * t;
      // 看到的宽度随翻转变窄（最窄留一点，侧面也看得见一道线）；迎光时提亮。
      final half = Offset(piece.size.width / 2 * math.max(face.abs(), .08), piece.size.height / 2);
      final base = face >= 0 ? piece.paper.front : piece.paper.back;
      final light = .78 + .22 * face.abs();
      final fade = t > piece.life - .5 ? (piece.life - t) / .5 : math.min(1.0, t / .06);
      final color = Color.from(alpha: base.a * fade, red: base.r * light, green: base.g * light, blue: base.b * light).toARGB32();
      final cos = math.cos(spin), sin = math.sin(spin);
      Offset corner(double dx, double dy) => Offset(x + dx * cos - dy * sin, y + dx * sin + dy * cos);
      final a = corner(-half.dx, -half.dy), b = corner(half.dx, -half.dy), c = corner(half.dx, half.dy), d = corner(-half.dx, half.dy);
      for (final point in [a, b, c, a, c, d]) {
        positions
          ..add(point.dx)
          ..add(point.dy);
        colors.add(color);
      }
    }
    if (positions.isEmpty) return;
    final vertices = ui.Vertices.raw(ui.VertexMode.triangles, Float32List.fromList(positions), colors: Int32List.fromList(colors));
    canvas.drawVertices(vertices, BlendMode.dst, Paint());
    vertices.dispose();
  }
}

// 按给定的时间（秒）画一场礼花；时间由调用方的动画驱动。
class ConfettiPainter extends CustomPainter {
  ConfettiPainter({required this.show, required this.seconds}) : super(repaint: seconds);
  final ConfettiShow show;
  final ValueListenable<double> seconds;

  @override
  void paint(Canvas canvas, Size size) => show.paint(canvas, size, seconds.value);

  @override
  bool shouldRepaint(ConfettiPainter oldDelegate) => oldDelegate.show != show;
}
