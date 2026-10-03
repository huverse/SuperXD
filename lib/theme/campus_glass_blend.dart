import 'package:flutter/material.dart';

// 玻璃换档（满档、标准、磨砂、未就绪之间，以及与实色互换）的过渡。玻璃不能套 Opacity 淡入淡出，
// 所以由使用方在玻璃内容层最底下铺一块同形状的实色盖板（不透明度 cover）：盖板渐显到不透明，
// 在完全盖住的那一帧换档，再渐隐露出新档位；换到实色就停在盖满。中途目标再变时从当前不透明度继续，
// 不归零、不跳变（同 iOS、鸿蒙动画可打断续接的做法）。减少动画时直接换档。
// look 是使用方的外观状态，opaque 表示 look 为实色（盖满，不再画玻璃）。
class CampusGlassBlend<T> extends StatefulWidget {
  const CampusGlassBlend({
    super.key,
    required this.look,
    required this.opaque,
    required this.builder,
  });
  final T look;
  final bool Function(T look) opaque;
  final Widget Function(BuildContext context, T look, double cover) builder;

  @override
  State<CampusGlassBlend<T>> createState() => _CampusGlassBlendState<T>();
}

class _CampusGlassBlendState<T> extends State<CampusGlassBlend<T>> with SingleTickerProviderStateMixin {
  late T _shown = widget.look;
  late final _cover = AnimationController(
    vsync: this,
    // 盖板从透明到盖满（或反过来）的时长；换档要盖满再揭开，共两段。
    duration: const Duration(milliseconds: 240),
    value: widget.opaque(widget.look) ? 1 : 0,
  );

  @override
  void didUpdateWidget(CampusGlassBlend<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.look != widget.look) _advance();
  }

  // 每次目标变化或盖板到位时推进一步：已是目标就把盖板收到目标位置；当前为实色（盖满）直接换成目标再渐隐；
  // 否则先盖满，到位后再换。
  void _advance() {
    final target = widget.look;
    if (MediaQuery.disableAnimationsOf(context)) {
      _cover.stop();
      if (_shown != target) setState(() => _shown = target);
      _cover.value = widget.opaque(target) ? 1 : 0;
      return;
    }
    if (_shown != target && (widget.opaque(_shown) || _cover.value >= 1)) {
      setState(() => _shown = target);
    }
    if (_shown == target) {
      if (widget.opaque(target)) {
        _cover.forward();
      } else {
        _cover.reverse();
      }
      return;
    }
    _cover.forward().whenCompleteOrCancel(() {
      if (mounted && _cover.value >= 1 && _shown != widget.look) _advance();
    });
  }

  @override
  void dispose() {
    _cover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _cover,
    builder: (context, _) => widget.builder(context, _shown, Curves.easeInOutCubic.transform(_cover.value)),
  );
}
