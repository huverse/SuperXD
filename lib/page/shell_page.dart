import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_icons.dart';
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
    // [人工决策-2026-09-25 16:24:31] 四项底栏悬浮于安全区之上，内容明确避让；拖动仍仅预览，松手提交一次。
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(bottom: reserved),
              child: navigationShell,
            ),
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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
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
  int? _pointer;
  bool _dragging = false;
  bool _rtl = false;
  bool _initialized = false;
  Offset? _lastGlobal;

  double _slotFor(int index) => (_rtl ? 3 - index : index).toDouble();
  int _indexAt(double slot) => _rtl ? 3 - slot.round() : slot.round();
  double _slotAt(Offset global) {
    final box = _barKey.currentContext!.findRenderObject()! as RenderBox;
    final x = box.globalToLocal(global).dx;
    return (x / (box.size.width / 4) - .5).clamp(0.0, 3.0);
  }

  void _settle(int index) {
    final target = _slotFor(index);
    if (!mounted || MediaQuery.disableAnimationsOf(context)) {
      _position.value = target;
    } else {
      _position.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _cancel() {
    _pointer = null;
    _dragging = false;
    _lastGlobal = null;
    _settle(widget.selected);
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
    if (!TickerMode.valuesOf(context).enabled) {
      _pointer = null;
      _dragging = false;
      _position.stop();
      _position.value = _slotFor(widget.selected);
    }
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
    if (state != AppLifecycleState.resumed) {
      _pointer = null;
      _dragging = false;
      _position.stop();
      _position.value = _slotFor(widget.selected);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _position.dispose();
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
                _position.stop();
              },
              onPointerMove: (event) {
                if (event.pointer != _pointer) return;
                _lastGlobal = event.position;
                if (_dragging) _position.value = _slotAt(event.position);
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
                  animation: _position,
                  builder: (context, _) {
                    final preview = _indexAt(_position.value);
                    return Stack(
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
