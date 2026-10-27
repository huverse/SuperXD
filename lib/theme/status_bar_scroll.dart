import 'package:flutter/widgets.dart';

// iOS 点状态栏回到顶部（同系统的滚动视图）：系统把点按交给 WidgetsBindingObserver.handleStatusBarTap。
// 页面的滚动区各自挂在自己路由的 PrimaryScrollController 上，外层底栏壳的 Scaffold 收不到，
// 所以在应用根部记住用户最近拖过的那个竖向滚动区，点状态栏时把它滚回开头（倒序列表是视觉上的顶端）；
// 它已经不在了、不在最上层的路由里或所在分支不可见时什么也不做。动画同 Scaffold 自带的那一份。组合根套在 MaterialApp.builder 里。
class CampusStatusBarScroll extends StatefulWidget {
  const CampusStatusBarScroll({super.key, required this.child});
  final Widget child;

  // 同点状态栏：把最近拖过的竖向滚动区滚回开头（iOS 再点当前底栏项、已在这一栏首页时也用它）。
  static void scrollToTop() => _CampusStatusBarScrollState._active?._scrollToTop();

  @override
  State<CampusStatusBarScroll> createState() => _CampusStatusBarScrollState();
}

class _CampusStatusBarScrollState extends State<CampusStatusBarScroll> with WidgetsBindingObserver {
  static _CampusStatusBarScrollState? _active;
  ScrollPosition? _last;

  @override
  void initState() {
    super.initState();
    _active = this;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    if (_active == this) _active = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void handleStatusBarTap() => _scrollToTop();

  void _scrollToTop() {
    final position = _last;
    final context = position?.context.notificationContext;
    if (position == null || context == null || !context.mounted || !position.hasPixels) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? true) || !TickerMode.valuesOf(context).enabled) return;
    position.animateTo(
      position.axisDirection == AxisDirection.up ? position.maxScrollExtent : position.minScrollExtent,
      duration: const Duration(milliseconds: 1000),
      curve: Curves.easeOutCirc,
    );
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollStartNotification>(
    onNotification: (notification) {
      final scrolled = notification.context;
      if (notification.dragDetails != null && notification.metrics.axis == Axis.vertical && scrolled != null) {
        _last = Scrollable.maybeOf(scrolled)?.position;
      }
      return false;
    },
    child: widget.child,
  );
}
