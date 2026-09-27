import 'package:flutter/material.dart';

// 保留每个分支Navigator实例，只对进出分支做转场，不用截图或重建页面伪装动画。
class AnimatedBranches extends StatefulWidget {
  const AnimatedBranches({super.key, required this.index, required this.children});
  final int index;
  final List<Widget> children;
  @override
  State<AnimatedBranches> createState() => _AnimatedBranchesState();
}

class _AnimatedBranchesState extends State<AnimatedBranches> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 300), value: 1);
  late final _curve = CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic);
  int? _previous;
  double _direction = 1;
  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) { if (status == AnimationStatus.completed && mounted) setState(() => _previous = null); });
  }
  @override
  void didUpdateWidget(AnimatedBranches oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    _previous = oldWidget.index;
    _direction = widget.index > oldWidget.index ? 1 : -1;
    if (MediaQuery.disableAnimationsOf(context)) { _controller.value = 1; _previous = null; }
    else { _controller.forward(from: 0); }
  }
  @override
  void dispose() { _curve.dispose(); _controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
    for (var index = 0; index < widget.children.length; index++)
      Offstage(offstage: index != widget.index && index != _previous, child: TickerMode(enabled: index == widget.index,
        child: ExcludeSemantics(excluding: index != widget.index, child: IgnorePointer(ignoring: index != widget.index,
          child: FadeTransition(
            opacity: index == widget.index ? _curve : index == _previous ? ReverseAnimation(_curve) : const AlwaysStoppedAnimation(0),
            child: AnimatedBuilder(animation: index == widget.index || index == _previous ? _curve : const AlwaysStoppedAnimation(1.0), child: widget.children[index], builder: (context, child) => Transform.translate(offset: Offset((index == widget.index ? (1 - _curve.value) : -_curve.value) * _direction * 12, 0), child: child)),
          ),
        )),
      )),
  ]);
}
