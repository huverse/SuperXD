import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'package:superxd/theme/campus_motion.dart';

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

// 按需建的长列表的增删过渡（11-18 性能审查 P2-4：好友列表最多 500 行，一次建满、收一条信就整列重建）：同 CampusAnimatedColumn 按 key 比对，
// 新的展开淡入、去掉的原地收起后再移除，第一次显示不动画、减少动画时直接换；只是条目按需建（SliverList.builder），只有正在进出的条目才有动画控制器。
// 去掉的条目收起时用它最后的数据再画一遍（itemBuilder 拿到的是旧的那一项）。index 与 count 含正在收起的条目，给卡片的首尾行用。
class CampusAnimatedSliverList<T> extends StatefulWidget {
  const CampusAnimatedSliverList({super.key, required this.items, required this.keyOf, required this.itemBuilder});
  final List<T> items;
  final Key Function(T item) keyOf;
  final Widget Function(BuildContext context, T item, int index, int count) itemBuilder;

  @override
  State<CampusAnimatedSliverList<T>> createState() => _CampusAnimatedSliverListState<T>();
}

class _SliverEntry<T> {
  _SliverEntry(this.item, this.key);
  T item;
  final Key key;
  // 只在展开或收起时才有；停稳的条目没有控制器（画成满的）。
  AnimationController? controller;
  bool leaving = false;
}

const _settled = AlwaysStoppedAnimation<double>(1);

class _CampusAnimatedSliverListState<T> extends State<CampusAnimatedSliverList<T>> with TickerProviderStateMixin {
  late List<_SliverEntry<T>> _entries = [for (final item in widget.items) _SliverEntry(item, widget.keyOf(item))];

  void _settle(_SliverEntry<T> entry, AnimationController controller) {
    if (!identical(entry.controller, controller) || entry.leaving) return;
    entry.controller = null;
    controller.dispose();
  }

  @override
  void didUpdateWidget(CampusAnimatedSliverList<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final instant = MediaQuery.disableAnimationsOf(context);
    final old = {for (final entry in _entries) entry.key: entry};
    final next = <_SliverEntry<T>>[];
    for (final item in widget.items) {
      final key = widget.keyOf(item);
      final existing = old.remove(key);
      final entry = existing ?? _SliverEntry(item, key);
      entry.item = item;
      final returning = entry.leaving;
      entry.leaving = false;
      if (!instant && (returning || existing == null)) {
        final controller = entry.controller ??= AnimationController(vsync: this, duration: campusListDuration, value: 0);
        controller.forward().whenCompleteOrCancel(() => _settle(entry, controller));
      }
      next.add(entry);
    }
    // 去掉的条目插回它原来前一个还在的条目后面，收起后再移除。
    final placed = Set<_SliverEntry<T>>.identity()..addAll(next);
    for (final (index, entry) in _entries.indexed) {
      if (!old.containsKey(entry.key)) continue;
      if (instant) {
        entry.controller?.dispose();
        continue;
      }
      final before = _entries.take(index).lastWhere(placed.contains, orElse: () => entry);
      next.insert(identical(before, entry) ? 0 : next.indexOf(before) + 1, entry);
      placed.add(entry);
      if (!entry.leaving) {
        entry.leaving = true;
        final controller = entry.controller ??= AnimationController(vsync: this, duration: campusListDuration, value: 1);
        controller.reverse().whenComplete(() {
          if (!mounted || !entry.leaving) return;
          setState(() => _entries.remove(entry));
          entry.controller = null;
          controller.dispose();
        });
      }
    }
    _entries = next;
  }

  @override
  void dispose() {
    for (final entry in _entries) {
      entry.controller?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final indexOf = {for (final (index, entry) in _entries.indexed) entry.key: index};
    return SliverList.builder(
      itemCount: _entries.length,
      findChildIndexCallback: (key) => indexOf[key],
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return KeyedSubtree(key: entry.key, child: _transition(entry.controller ?? _settled, IgnorePointer(ignoring: entry.leaving, child: widget.itemBuilder(context, entry.item, index, _entries.length))));
      },
    );
  }
}

// 条目换位置的过渡（11-23 用户录屏：编辑常用时勾上、取消的那一行一下子跳到别处）：同 iOS 表格的 moveRow、Android RecyclerView 的移动动画。
// 调用方经 move 改数据：改之前记下每一项此刻看上去在滚动内容里的位置与透明度，排版换了之后各项从那里滑到新位置（换了地方的那一行穿过去，
// 中间的顺着让开或补上），新出现的淡入；present 为假的（空了的分组标题）留在树里、不占位置、淡出，再出现时从那里淡入。
// 只在 move 之后动，滚动与第一次显示不动，过渡中途再 move 从当时看上去的样子接着走，减少动画时直接换。位置按滚动内容算（加上滚动距离），
// 中途滚动也不跑偏；滑到别处的条目由滚动区裁剪。不在 CampusMoveScope 里（拖动排序时浮在 Overlay 里的那一份）就原样画。
// present 为假时高度记成零，只给竖向列表；淡出用 FadeTransition，只用在没有玻璃的内容区。
const campusMoveDuration = Duration(milliseconds: 300);

class CampusMoveScope extends StatefulWidget {
  const CampusMoveScope({super.key, required this.child});
  final Widget child;

  @override
  State<CampusMoveScope> createState() => CampusMoveScopeState();
}

class CampusMoveScopeState extends State<CampusMoveScope> with SingleTickerProviderStateMixin {
  // 改完数据的第一帧要建新条目，计时从它画完后开始，同页面转场。
  late final _controller = AnimationController(vsync: CampusFirstFrameVsync(this), duration: campusMoveDuration, value: 1);
  late final _progress = CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic);
  final _members = <Object, _RenderCampusMove>{};
  var _from = <Object, ({Offset offset, double opacity})>{};

  // 在 change 里改数据（调用方的 setState），各项从现在看上去的样子过渡到改完后的样子。
  void move(VoidCallback change) {
    _from = {for (final member in _members.values) if (member.hasSize) member.id: (offset: member.layoutOffset + member.delta, opacity: _opacity(member.id, member.present))};
    change();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  // 过渡中新建出来、没记过的从透明淡入。
  double _opacity(Object id, bool present) {
    final from = _from[id]?.opacity ?? 0, to = present ? 1.0 : 0.0;
    return from + (to - from) * _progress.value;
  }

  @override
  void dispose() {
    _progress.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class CampusMove extends StatelessWidget {
  const CampusMove({super.key, required this.id, this.present = true, required this.child});
  // 同一项前后用同一个 id（换到另一个列表里也一样）。
  final Object id;
  final bool present;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = context.findAncestorStateOfType<CampusMoveScopeState>();
    if (scope == null) return child;
    return FadeTransition(
      opacity: _MoveOpacity(scope, id, present),
      child: _CampusMoveBox(scope: scope, id: id, present: present, child: ExcludeSemantics(excluding: !present, child: child)),
    );
  }
}

class _MoveOpacity extends Animation<double> with AnimationWithParentMixin<double> {
  _MoveOpacity(this.scope, this.id, this.present);
  final CampusMoveScopeState scope;
  final Object id;
  final bool present;

  @override
  Animation<double> get parent => scope._progress;

  @override
  double get value => scope._opacity(id, present);
}

class _CampusMoveBox extends SingleChildRenderObjectWidget {
  const _CampusMoveBox({required this.scope, required this.id, required this.present, super.child});
  final CampusMoveScopeState scope;
  final Object id;
  final bool present;

  @override
  _RenderCampusMove createRenderObject(BuildContext context) => _RenderCampusMove(scope, id, present);

  @override
  void updateRenderObject(BuildContext context, _RenderCampusMove renderObject) => renderObject
    ..id = id
    ..present = present;
}

class _RenderCampusMove extends RenderProxyBox {
  _RenderCampusMove(this.scope, this._id, this._present);
  final CampusMoveScopeState scope;

  Object _id;
  Object get id => _id;
  set id(Object value) {
    if (value == _id) return;
    _leave();
    _id = value;
    if (attached) scope._members[_id] = this;
  }

  bool _present;
  bool get present => _present;
  set present(bool value) {
    if (value == _present) return;
    _present = value;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    scope._members[_id] = this;
    scope._progress.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    scope._progress.removeListener(markNeedsPaint);
    _leave();
    super.detach();
  }

  // 换到另一个列表时新的那份可能先登记上，不能把它删了。
  void _leave() {
    if (identical(scope._members[_id], this)) scope._members.remove(_id);
  }

  @override
  void performLayout() {
    final child = this.child!..layout(constraints, parentUsesSize: true);
    size = _present ? child.size : constraints.constrain(Size(child.size.width, 0));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final size = super.computeDryLayout(constraints);
    return _present ? size : constraints.constrain(Size(size.width, 0));
  }

  @override
  double computeMinIntrinsicHeight(double width) => _present ? super.computeMinIntrinsicHeight(width) : 0;

  @override
  double computeMaxIntrinsicHeight(double width) => _present ? super.computeMaxIntrinsicHeight(width) : 0;

  // 在滚动内容里的位置（滚动不改变它）；不在滚动区里就是屏幕位置。
  Offset get layoutOffset {
    final viewport = RenderAbstractViewport.maybeOf(this);
    if (viewport is! RenderViewportBase || !viewport.offset.hasPixels) return localToGlobal(Offset.zero);
    final pixels = viewport.offset.pixels;
    return localToGlobal(Offset.zero, ancestor: viewport) + switch (viewport.axisDirection) {
      AxisDirection.down => Offset(0, pixels),
      AxisDirection.up => Offset(0, -pixels),
      AxisDirection.right => Offset(pixels, 0),
      AxisDirection.left => Offset(-pixels, 0),
    };
  }

  // 此刻画在离排版位置多远的地方。
  Offset get delta {
    final from = scope._from[_id], remaining = 1 - scope._progress.value;
    return from == null || remaining <= 0 ? Offset.zero : (from.offset - layoutOffset) * remaining;
  }

  @override
  void paint(PaintingContext context, Offset offset) => context.paintChild(child!, offset + delta);

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final delta = this.delta;
    transform.multiply(Matrix4.translationValues(delta.dx, delta.dy, 0));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintOffset(offset: delta, position: position, hitTest: (result, position) => child!.hitTest(result, position: position));
}
