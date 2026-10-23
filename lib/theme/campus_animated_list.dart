import 'package:flutter/widgets.dart';

// [人工决策-2026-10-19 17:55:48] 列表条目增删有过渡（用户选定，同 iOS 表格、Material 列表的增删）：新出现的条目展开并淡入，
// 去掉的条目原地收起并淡出，下面的内容顺着移动、不一下跳上去；约 200ms。第一次显示不动画（设计语言禁止逐项飞入），减少动画时直接换。
// 只用在没有玻璃的内容区列表上（淡入淡出的祖先图层下玻璃取不到背景）。
const campusListDuration = Duration(milliseconds: 200);

// 条目照旧铺满列表宽度：SizeTransition 内部是 Align，会把宽度放松成「最多这么宽」，按内容收窄的条目（会话卡片）就被居中了。
Widget _transition(Animation<double> animation, Widget child) {
  final curved = CurvedAnimation(parent: animation, curve: Curves.easeInOutCubic);
  return SizeTransition(sizeFactor: curved, alignment: Alignment.topCenter, child: FadeTransition(opacity: curved, child: SizedBox(width: double.infinity, child: child)));
}

// 按 key 比对前后两次的子项：新 key 展开，消失的 key 留在原位收起后再移除。子项必须各带唯一 key。
class CampusAnimatedColumn extends StatefulWidget {
  const CampusAnimatedColumn({super.key, required this.children});
  final List<Widget> children;

  @override
  State<CampusAnimatedColumn> createState() => _CampusAnimatedColumnState();
}

class _Entry {
  _Entry(this.child, this.controller);
  Widget child;
  final AnimationController controller;
  bool leaving = false;
  Key get key => child.key!;
}

class _CampusAnimatedColumnState extends State<CampusAnimatedColumn> with TickerProviderStateMixin {
  late List<_Entry> _entries = [for (final child in widget.children) _Entry(child, AnimationController(vsync: this, duration: campusListDuration, value: 1))];

  @override
  void didUpdateWidget(CampusAnimatedColumn oldWidget) {
    super.didUpdateWidget(oldWidget);
    final instant = MediaQuery.disableAnimationsOf(context);
    final old = {for (final entry in _entries) entry.key: entry};
    final next = <_Entry>[];
    for (final child in widget.children) {
      final entry = old.remove(child.key);
      if (entry == null) {
        next.add(_Entry(child, AnimationController(vsync: this, duration: campusListDuration, value: instant ? 1 : 0))..controller.forward());
      } else {
        entry
          ..child = child
          ..leaving = false;
        entry.controller.forward();
        next.add(entry);
      }
    }
    // 去掉的条目插回它原来前一个还在的条目后面，收起后再移除。
    final placed = Set<_Entry>.identity()..addAll(next);
    for (final (index, entry) in _entries.indexed) {
      if (!old.containsKey(entry.key)) continue;
      if (instant) {
        entry.controller.dispose();
        continue;
      }
      final before = _entries.take(index).lastWhere(placed.contains, orElse: () => entry);
      next.insert(identical(before, entry) ? 0 : next.indexOf(before) + 1, entry);
      placed.add(entry);
      if (!entry.leaving) {
        entry.leaving = true;
        entry.controller.reverse().whenComplete(() {
          if (!mounted || !entry.leaving) return;
          setState(() => _entries.remove(entry));
          entry.controller.dispose();
        });
      }
    }
    _entries = next;
  }

  @override
  void dispose() {
    for (final entry in _entries) {
      entry.controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [for (final entry in _entries) KeyedSubtree(key: entry.key, child: _transition(entry.controller, IgnorePointer(ignoring: entry.leaving, child: entry.child)))],
  );
}

// 按需建的长列表（ListView.builder）里新到的一项：第一次建出来时展开并淡入；animate 为假（第一屏、减少动画）时直接显示。
class CampusAppear extends StatefulWidget {
  const CampusAppear({super.key, required this.animate, required this.child});
  final bool animate;
  final Widget child;

  @override
  State<CampusAppear> createState() => _CampusAppearState();
}

class _CampusAppearState extends State<CampusAppear> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: campusListDuration, value: widget.animate ? 0 : 1)..forward();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _controller.value = 1;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _transition(_controller, widget.child);
}
