import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_glass_material.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/glass_panel.dart';

class ShellPage extends StatelessWidget {
  const ShellPage({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom > 0;
    final barHeight = 72.0 * media.textScaler.scale(14) / 14 + 8;
    final bottom = media.padding.bottom + 12;
    final reserved = keyboard ? 0.0 : barHeight + bottom + 12;
    // [人工决策-2026-09-29 04:01:38] 四项底栏悬浮于安全区之上；内容层延伸到玻璃下方透出，底栏占位作为底部安全区交给各页，末项滚到底仍停在底栏上方；拖动仍仅预览，松手提交一次。
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // 结构固定只换数据，键盘弹出时不重建分支导航状态。
          Positioned.fill(
            child: Builder(builder: (context) {
              final body = MediaQuery.of(context);
              return MediaQuery(
                data: keyboard ? body : body.copyWith(padding: body.padding.copyWith(bottom: reserved), viewPadding: body.viewPadding.copyWith(bottom: reserved)),
                child: navigationShell,
              );
            }),
          ),
          if (!keyboard)
            Positioned(
              left: 16,
              right: 16,
              bottom: bottom,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: GlassPanel(
                    edge: GlassEdge.top,
                    floating: true,
                    child: DragNavigationBar(
                      selected: navigationShell.currentIndex,
                      onSelected: (index) {
                        if (index != navigationShell.currentIndex) {
                          navigationShell.goBranch(index);
                        }
                      },
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class DragNavigationBar extends StatefulWidget {
  const DragNavigationBar({
    super.key,
    required this.selected,
    required this.onSelected,
  });
  final int selected;
  final ValueChanged<int> onSelected;
  @override
  State<DragNavigationBar> createState() => _DragNavigationBarState();
}

// [人工决策-2026-09-27 16:30:11] 栏内起拖后即使离栏仍跟随横坐标；正常松手吸附最近模块且只提交一次，系统取消/后台不提交。
class _DragNavigationBarState extends State<DragNavigationBar>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const labels = ['今天', '服务', '消息', '我的'];
  static const icons = [
    CampusIcons.today,
    CampusIcons.services,
    CampusIcons.messages,
    CampusIcons.account,
  ];
  static const selectedIcons = [
    CampusIcons.todaySelected,
    CampusIcons.servicesSelected,
    CampusIcons.messagesSelected,
    CampusIcons.accountSelected,
  ];
  final _barKey = GlobalKey();
  late final _position = AnimationController(
    vsync: this,
    lowerBound: 0,
    upperBound: 3,
    value: widget.selected.toDouble(),
  );
  // 透镜升起进度：按下升起为玻璃透镜，回位完成后落回静态胶囊。
  late final _lift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
    reverseDuration: const Duration(milliseconds: 260),
  );
  int? _pointer;
  bool _dragging = false;
  bool _rtl = false;
  bool _initialized = false;
  Offset? _lastGlobal;
  Duration? _lastMove;
  // 拖动速度，单位为每秒多少槽；松手时作为回位弹簧的初速。
  double _velocity = 0;

  double _slotFor(int index) => (_rtl ? 3 - index : index).toDouble();
  int _indexAt(double slot) => _rtl ? 3 - slot.round() : slot.round();
  double _slotAt(Offset global) {
    final box = _barKey.currentContext!.findRenderObject()! as RenderBox;
    final x = box.globalToLocal(global).dx;
    return (x / (box.size.width / 4) - .5).clamp(0.0, 3.0);
  }

  void _settle(int index) {
    final target = _slotFor(index);
    final spring = mounted ? campusGlassTravelSpring(context) : null;
    final velocity = _velocity;
    _velocity = 0;
    if (spring == null) {
      _position.value = target;
      _lift.value = 0;
      return;
    }
    _position
        .animateWith(
          SpringSimulation(spring, _position.value, target, velocity),
        )
        .whenCompleteOrCancel(() {
          if (mounted && _pointer == null) _lift.reverse();
        });
  }

  void _cancel() {
    _pointer = null;
    _dragging = false;
    _lastGlobal = null;
    _settle(widget.selected);
  }

  void _rest() {
    _pointer = null;
    _dragging = false;
    _velocity = 0;
    _position.stop();
    _position.value = _slotFor(widget.selected);
    _lift.value = 0;
  }

  void _commit(int index) {
    _settle(index);
    if (index != widget.selected) widget.onSelected(index);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final rtl = Directionality.of(context) == TextDirection.rtl;
    if (!_initialized || rtl != _rtl) {
      _rtl = rtl;
      _initialized = true;
      _pointer = null;
      _dragging = false;
      _position.value = _slotFor(widget.selected);
    }
    if (!TickerMode.valuesOf(context).enabled) _rest();
  }

  @override
  void didUpdateWidget(DragNavigationBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      _pointer = null;
      _dragging = false;
      _lastGlobal = null;
      _settle(widget.selected);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _rest();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _position.dispose();
    _lift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = 72.0 * MediaQuery.textScalerOf(context).scale(14) / 14;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final slotWidth = constraints.maxWidth / 4;
            return Listener(
              onPointerDown: (event) {
                if (_pointer != null) return;
                _pointer = event.pointer;
                _lastGlobal = event.position;
                _lastMove = event.timeStamp;
                _velocity = 0;
                _position.stop();
                _lift.forward();
              },
              onPointerMove: (event) {
                if (event.pointer != _pointer) return;
                _lastGlobal = event.position;
                if (!_dragging) return;
                final slot = _slotAt(event.position);
                final seconds = (event.timeStamp - _lastMove!).inMicroseconds / 1e6;
                if (seconds > 0) {
                  _velocity = _velocity * .5 + (slot - _position.value) / seconds * .5;
                }
                _lastMove = event.timeStamp;
                _position.value = slot;
              },
              onPointerUp: (event) {
                if (event.pointer != _pointer) return;
                final dragging = _dragging;
                final slot = _slotAt(event.position);
                _pointer = null;
                _dragging = false;
                _lastGlobal = null;
                if (dragging) _commit(_indexAt(slot));
              },
              onPointerCancel: (event) {
                if (event.pointer == _pointer) _cancel();
              },
              child: GestureDetector(
                key: _barKey,
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) {
                  if (_pointer == null) return;
                  _dragging = true;
                  _position.value = _slotAt(_lastGlobal!);
                },
                onPanUpdate: (_) {},
                // PointerUp/Cancel是提交边界，不把识别器的onEnd当成正常松手。
                onPanCancel: () {
                  if (_pointer != null) _cancel();
                },
                child: AnimatedBuilder(
                  animation: Listenable.merge([_position, _lift, campusGlassReady]),
                  builder: (context, _) {
                    final preview = _indexAt(_position.value);
                    final tier = CampusGlassScope.tierOf(context, ready: campusGlassReady.value);
                    // 拖动和回位期间升起玻璃透镜（与 iOS 底栏一致），静止后落回着色胶囊；磨砂、实色档不升起。
                    final lens =
                        _lift.value > .01 &&
                        GlassPanelScope.maybeOf(context)?.opaque != true &&
                        (tier == CampusGlassTier.full || tier == CampusGlassTier.standard);                    return Stack(
                      children: [
                        Positioned(
                          left: _position.value * slotWidth + 4,
                          top: 4,
                          bottom: 4,
                          width: slotWidth - 8,
                          child: DecoratedBox(
                            key: const ValueKey('navigation-capsule'),
                            decoration: BoxDecoration(
                              color: CampusPalette.of(context).surfaceSelected,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: CampusPalette.of(context).outlineSubtle,
                              ),
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            for (var index = 0; index < labels.length; index++)
                              Expanded(
                                child: Semantics(
                                  button: true,
                                  selected: index == widget.selected,
                                  label: labels[index],
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(24),
                                    onTap: () { if (_pointer == null && !_dragging) _commit(index); },
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        CampusMorphIcon(
                                          from: icons[index],
                                          to: selectedIcons[index],
                                          selected: widget.selected == index,
                                          size: 24,
                                          color: preview == index
                                              ? CampusPalette.of(context)
                                                    .primary
                                              : CampusPalette.of(context)
                                                    .onSurfaceVariant,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          labels[index],
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: preview == index
                                                ? CampusPalette.of(context)
                                                      .primary
                                                : CampusPalette.of(context)
                                                      .onSurfaceVariant,
                                            fontWeight: preview == index
                                                ? FontWeight.w600
                                                : FontWeight.w400,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        // 指示器自带 Positioned.fill，须直接放在 Stack 里，所以外层再包一层 Stack 来忽略点击。
                        if (lens)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: Stack(
                                children: [
                                  liquid.AnimatedGlassIndicator(
                                    velocity: (_position.isAnimating ? _position.velocity : _velocity) * 2 / 3,
                                    itemCount: labels.length,
                                    alignment: Alignment(_position.value / 3 * 2 - 1, 0),
                                    thickness: _lift.value,
                                    quality: campusGlassQuality(tier),
                                    indicatorColor: CampusPalette.of(context).surfaceSelected,
                                    isBackgroundIndicator: false,
                                    paintBackground: false,
                                    paintGlass: true,
                                    padding: const EdgeInsets.all(4),
                                    exactOffset: _position.value * slotWidth,
                                    exactWidth: slotWidth - 8,
                                    borderRadius: 24,
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
