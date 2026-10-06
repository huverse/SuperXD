import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'package:superxd/theme/campus_glass_surface.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/glass_panel.dart';

class CampusMenuItem<T> {
  const CampusMenuItem({required this.value, required this.label, this.icon, this.destructive = false});
  final T value;
  final String label;
  final IconData? icon;
  // 破坏性操作（删除等）图标与文字用警示色，确认仍由调用方弹 showCampusConfirm。
  final bool destructive;
}

const _itemExtent = 48.0;
const _panelRadius = 20.0;
// 选中底色与面板同心：圆角 = 面板圆角 - 内边距。
const _panelInset = 6.0;
const _screenMargin = 12.0;
const _anchorGap = 4.0;
const _minMenuWidth = 200.0;

// 从 anchor 所在控件弹出玻璃菜单，返回点选的值；点空白或按返回键关闭时为 null。
// 用路由而不是库的 GlassMenu：GlassMenu 直接插 OverlayEntry，返回键会退出底下的页面，读屏也不是模态。
// matchWidth 为真时菜单与触发控件等宽（下拉字段），否则至少 200 并按内容伸展。
Future<T?> showCampusMenu<T>(BuildContext anchor, {required List<CampusMenuItem<T>> items, T? selected, bool matchWidth = false}) {
  final navigator = Navigator.of(anchor, rootNavigator: true);
  final box = anchor.findRenderObject()! as RenderBox;
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  return navigator.push(_CampusMenuRoute<T>(
    anchor: box.localToGlobal(Offset.zero, ancestor: overlay) & box.size,
    items: items,
    selected: selected,
    matchWidth: matchWidth,
    animate: !MediaQuery.disableAnimationsOf(anchor),
    capturedThemes: InheritedTheme.capture(from: anchor, to: navigator.context),
    barrierLabel: MaterialLocalizations.of(anchor).modalBarrierDismissLabel,
  ));
}

class _CampusMenuRoute<T> extends PopupRoute<T> with CampusOverlayDepthRoute<T> {
  _CampusMenuRoute({
    required this.anchor,
    required this.items,
    required this.selected,
    required this.matchWidth,
    required this.animate,
    required this.capturedThemes,
    required this.barrierLabel,
  });
  final Rect anchor;
  final List<CampusMenuItem<T>> items;
  final T? selected;
  final bool matchWidth;
  final bool animate;
  final CapturedThemes capturedThemes;
  @override
  final String barrierLabel;
  late final Animation<double> reveal = animation!.drive(CurveTween(curve: Curves.easeInOutCubic));

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  Duration get transitionDuration => animate ? campusOverlay.duration! : Duration.zero;
  @override
  Duration get reverseTransitionDuration => animate ? campusOverlay.reverseDuration! : Duration.zero;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      capturedThemes.wrap(_CampusMenu<T>(route: this));
}

class _CampusMenu<T> extends StatefulWidget {
  const _CampusMenu({super.key, required this.route});
  final _CampusMenuRoute<T> route;
  @override
  State<_CampusMenu<T>> createState() => _CampusMenuState<T>();
}

class _CampusMenuState<T> extends State<_CampusMenu<T>> with SingleTickerProviderStateMixin {
  // 展开按玻璃松手弹簧轻过冲一次；收回随路由淡出、不回弹。
  late final _bloom = AnimationController.unbounded(vsync: this, value: 0);
  final _selectedKey = GlobalKey();
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final spring = campusGlassSpring(context, release: true);
    if (spring == null || !widget.route.animate) {
      _bloom.value = 1;
    } else {
      _bloom.animateWith(SpringSimulation(spring, 0, 1, 0));
    }
    // 选中项可能在长列表下方，首帧后滚到中间可见。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final selected = _selectedKey.currentContext;
      if (selected != null && mounted) Scrollable.ensureVisible(selected, alignment: .5);
    });
  }

  @override
  void dispose() {
    _bloom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final media = MediaQuery.of(context);
    final size = media.size;
    final bounds = Rect.fromLTRB(
      media.padding.left + _screenMargin,
      media.padding.top + _screenMargin,
      size.width - media.padding.right - _screenMargin,
      size.height - math.max(media.padding.bottom, media.viewInsets.bottom) - _screenMargin,
    );
    final anchor = route.anchor;
    final spaceBelow = bounds.bottom - anchor.bottom - _anchorGap;
    final spaceAbove = anchor.top - _anchorGap - bounds.top;
    final estimated = route.items.length * media.textScaler.scale(_itemExtent) + _panelInset * 2;
    final below = spaceBelow >= estimated || spaceBelow >= spaceAbove;
    // 触发控件在屏幕右半时菜单右缘对齐控件右缘，向左展开，与系统菜单一致。
    final alignEnd = !route.matchWidth && anchor.center.dx > size.width / 2;
    final origin = route.matchWidth
        ? (below ? Alignment.topCenter : Alignment.bottomCenter)
        : below
        ? (alignEnd ? Alignment.topRight : Alignment.topLeft)
        : (alignEnd ? Alignment.bottomRight : Alignment.bottomLeft);
    final reveal = route.reveal;
    return CustomSingleChildLayout(
      delegate: _MenuLayout(anchor: anchor, bounds: bounds, below: below, alignEnd: alignEnd, matchWidth: route.matchWidth),
      // 显隐交给面板（CampusOverlayReveal），这里只管从触发处展开的缩放。
      child: CampusOverlayReveal(
        animation: reveal,
        child: AnimatedBuilder(
          animation: Listenable.merge([_bloom, reveal]),
          builder: (context, child) {
            final closing = route.animation!.status == AnimationStatus.reverse;
            final scale = (.88 + .12 * _bloom.value) * (closing ? .96 + .04 * reveal.value : 1);
            return Transform.scale(scale: scale, alignment: origin, child: child);
          },
          child: Semantics(
            scopesRoute: true,
            namesRoute: true,
            explicitChildNodes: true,
            label: MaterialLocalizations.of(context).popupMenuLabel,
            child: CampusOverlayGlass(
              radius: _panelRadius,
              floating: true,
              child: IntrinsicWidth(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(_panelInset),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (index, item) in route.items.indexed)
                        _MenuRow(
                          key: item.value == route.selected ? _selectedKey : null,
                          item: item,
                          selected: item.value == route.selected,
                          autofocus: route.selected == null ? index == 0 : item.value == route.selected,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout({required this.anchor, required this.bounds, required this.below, required this.alignEnd, required this.matchWidth});
  final Rect anchor;
  final Rect bounds;
  final bool below;
  final bool alignEnd;
  final bool matchWidth;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.min(anchor.width, bounds.width);
    final height = below ? bounds.bottom - anchor.bottom - _anchorGap : anchor.top - _anchorGap - bounds.top;
    return BoxConstraints(
      minWidth: matchWidth ? width : math.min(_minMenuWidth, bounds.width),
      maxWidth: matchWidth ? width : bounds.width,
      maxHeight: math.max(height, _itemExtent + _panelInset * 2),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = alignEnd ? anchor.right - childSize.width : anchor.left;
    final top = below ? anchor.bottom + _anchorGap : anchor.top - _anchorGap - childSize.height;
    return Offset(
      left.clamp(bounds.left, math.max(bounds.left, bounds.right - childSize.width)),
      top.clamp(bounds.top, math.max(bounds.top, bounds.bottom - childSize.height)),
    );
  }

  @override
  bool shouldRelayout(_MenuLayout oldDelegate) =>
      anchor != oldDelegate.anchor || bounds != oldDelegate.bounds || below != oldDelegate.below || alignEnd != oldDelegate.alignEnd || matchWidth != oldDelegate.matchWidth;
}

class _MenuRow<T> extends StatelessWidget {
  const _MenuRow({super.key, required this.item, required this.selected, required this.autofocus});
  final CampusMenuItem<T> item;
  final bool selected;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final radius = BorderRadius.circular(_panelRadius - _panelInset);
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        autofocus: autofocus,
        borderRadius: radius,
        onTap: () => Navigator.pop(context, item.value),
        child: Ink(
          decoration: BoxDecoration(color: selected ? palette.surfaceSelected : null, borderRadius: radius),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _itemExtent),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(children: [
                if (item.icon case final icon?) ...[
                  CampusIcon(icon, size: 20, color: item.destructive ? palette.danger : palette.primary),
                  const SizedBox(width: 12),
                ],
                Expanded(child: Text(item.label, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: item.destructive ? palette.danger : palette.onSurface))),
                if (selected) ...[
                  const SizedBox(width: 12),
                  CampusIcon(CampusIcons.check, size: 20, color: palette.primary),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// 下拉字段：外观沿用带浮动标签的输入框，点按弹出与字段等宽的玻璃菜单，选中项带勾。
// onChanged 为 null 时禁用；只在选了不同的值时回调。
class CampusMenuField<T> extends StatefulWidget {
  const CampusMenuField({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });
  final String label;
  final T value;
  final List<CampusMenuItem<T>> items;
  final ValueChanged<T>? onChanged;

  @override
  State<CampusMenuField<T>> createState() => _CampusMenuFieldState<T>();
}

class _CampusMenuFieldState<T> extends State<CampusMenuField<T>> {
  bool _focused = false;
  bool _open = false;

  Future<void> _pick() async {
    setState(() => _open = true);
    final value = await showCampusMenu<T>(context, items: widget.items, selected: widget.value, matchWidth: true);
    if (!mounted) return;
    setState(() => _open = false);
    if (value != null && value != widget.value) widget.onChanged?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    final current = widget.items.where((item) => item.value == widget.value).firstOrNull;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: enabled ? _pick : null,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: InputDecorator(
          isFocused: _focused || _open,
          isEmpty: current == null,
          decoration: InputDecoration(
            labelText: widget.label,
            enabled: enabled,
            suffixIcon: const CampusIcon(CampusIcons.expand),
          ),
          child: Text(
            current?.label ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ),
    );
  }
}
