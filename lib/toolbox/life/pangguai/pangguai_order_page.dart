import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_refresh.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/life/life_money.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_client.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_service.dart';

enum _Pay { idle, preparing, paying, checking }

// 订单页：待付款时「用支付宝付」（⋯ 里取消）；付款：重查订单与收银台 → 拿支付宝串 → 交给支付宝 → 支付宝返回、回到前台或点「我已付款」时去胖乖查
// （2 秒一次、最多 15 次，订单变成使用中或已完成就是付好了、变成已取消就停下；到账只认胖乖的订单，支付宝的结果码只作提示），支付宝报取消或失败时查一次没付就回到能再付的样子。
// 付好后胖乖下发开机（客户端没有启动设备的接口）：使用中写预计几点结束与还剩多久（按胖乖给的目标时刻算，不按时长自己倒数），前台时每 15 秒再查一次，到点照样以状态为准。
class PangguaiOrderPage extends StatefulWidget {
  const PangguaiOrderPage({super.key, required this.service, required this.phone, required this.orderId, this.autoPay = false, this.onClose});
  final PangguaiService service;
  final String phone;
  final String orderId;
  // 刚下好的单：打开就开始付。
  final bool autoPay;
  // 被换页进来的（下单后从设备页换过来）：关掉时让首页刷新。
  final VoidCallback? onClose;
  @override
  State<PangguaiOrderPage> createState() => _PangguaiOrderPageState();
}

class _PangguaiOrderPageState extends State<PangguaiOrderPage> with WidgetsBindingObserver {
  PangguaiOrder? _order;
  String? _error;
  String? _payError;
  var _pay = _Pay.idle;
  // 支付宝报的结果码（这一次付款的）。
  String? _status;
  var _autoPay = false;
  Timer? _poll;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _autoPay = widget.autoPay;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _tick?.cancel();
    widget.onClose?.call();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 从支付宝回来：付没付都去胖乖查一次（SDK 的回调可能回不来）。
      if (_pay == _Pay.paying) {
        unawaited(_check());
      } else if (_order?.running == true) {
        unawaited(_load());
      }
    } else if (state == AppLifecycleState.paused) {
      _poll?.cancel();
    }
  }

  Future<void> _load() async {
    try {
      final order = await widget.service.run(widget.phone, (token) => widget.service.client.order(token, widget.orderId));
      if (!mounted) return;
      setState(() {
        _order = order;
        _error = null;
      });
      _schedule();
      if (_autoPay && order.payable) {
        _autoPay = false;
        unawaited(_payNow());
      }
    } on PangguaiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=order_load errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '没读到订单，稍后再试');
    }
  }

  // 使用中：前台时每 15 秒再查一次，倒计时每 30 秒重画；别的状态不查。
  void _schedule() {
    _poll?.cancel();
    _tick?.cancel();
    if (_order?.running != true) return;
    if (WidgetsBinding.instance.lifecycleState == null || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _poll = Timer(const Duration(seconds: 15), () => unawaited(_load()));
    }
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _payNow() async {
    final order = _order;
    if (order == null || _pay != _Pay.idle) return;
    setState(() {
      _pay = _Pay.preparing;
      _payError = null;
      _status = null;
    });
    final String param;
    try {
      param = await widget.service.prepay(widget.phone, order.id, expected: order.price);
    } on PangguaiPriceChanged catch (changed) {
      if (!mounted) return;
      setState(() {
        _pay = _Pay.idle;
        _payError = '金额变成 ¥${lifeYuan(changed.price)} 了，确认后再付';
      });
      unawaited(_load());
      return;
    } on PangguaiException catch (error) {
      if (mounted) _fail(error.message);
      return;
    } catch (error, stack) {
      campusLog('[Pangguai] action=prepay errorType=${error.runtimeType}\n$stack');
      if (mounted) _fail('没拿到付款单，稍后再试');
      return;
    }
    if (!mounted) return;
    setState(() => _pay = _Pay.paying);
    campusLog('[Pangguai] action=pay_start');
    try {
      final status = await widget.service.alipay.pay(param);
      campusLog('[Pangguai] action=pay_returned status=$status');
      _status = status;
      if (!mounted || _pay != _Pay.paying) return;
      if (status == '6001') return _fail('已取消付款');
      unawaited(_check());
    } catch (error, stack) {
      campusLog('[Pangguai] action=pay errorType=${error.runtimeType}\n$stack');
      if (mounted && _pay == _Pay.paying) unawaited(_check());
    }
  }

  void _fail(String message) => setState(() {
    _pay = _Pay.idle;
    _payError = message;
  });

  Future<void> _check() async {
    if (_pay == _Pay.checking) return;
    setState(() => _pay = _Pay.checking);
    for (var attempt = 0; attempt < 15; attempt++) {
      try {
        final order = await widget.service.run(widget.phone, (token) => widget.service.client.order(token, widget.orderId));
        if (!order.payable) {
          // 已取消（等太久胖乖关掉了）不是付好了：同样原地换成「已取消」、付款区收起，不当成付款成功。
          campusLog('[Pangguai] action=${order.cancelled ? 'pay_closed' : 'pay_confirmed'} attempt=$attempt');
          if (!mounted) return;
          setState(() {
            _order = order;
            _pay = _Pay.idle;
          });
          // 状态原地变成使用中，就是看得见的结果，不另出提示条（付款区随之收起）。
          _schedule();
          return;
        }
      } catch (error) {
        campusLog('[Pangguai] action=pay_check reason=${error.runtimeType}');
      }
      if (_status case '6001' || '4000') break;
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
    }
    if (!mounted) return;
    campusLog('[Pangguai] action=pay_unconfirmed status=$_status');
    _fail(switch (_status) {
      '6001' => '已取消付款',
      '4000' => '付款没成功，可以再付一次',
      _ => '还没查到付款结果，付过了就下拉刷新看看',
    });
  }

  Future<void> _menu(BuildContext anchor) async {
    final picked = await showCampusMenu<String>(anchor, items: const [CampusMenuItem(value: 'cancel', label: '取消订单', icon: CampusIcons.delete, destructive: true)]);
    if (picked != 'cancel' || !mounted) return;
    final agreed = await showCampusConfirm(context, title: '取消订单', message: '这一单还没付，取消后从订单里拿掉。', action: '取消订单', cancel: '再想想', destructive: true);
    if (!agreed || !mounted) return;
    try {
      await widget.service.cancel(widget.phone, widget.orderId);
      if (!mounted) return;
      showCampusToast(context, '已取消');
      Navigator.pop(context);
    } on PangguaiException catch (error) {
      if (mounted) showCampusToast(context, error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=cancel errorType=${error.runtimeType}\n$stack');
      if (mounted) showCampusToast(context, '没取消成，稍后再试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = _order;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('订单'),
        actions: [
          if (order != null && order.payable && _pay == _Pay.idle)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Builder(builder: (anchor) => CampusGlassCircleButton(label: '更多', size: 44, onPressed: () => unawaited(_menu(anchor)), icon: const CampusIcon(CampusIcons.manage))),
            ),
        ],
      ),
      body: CampusScrollFade(
        child: SafeArea(
          bottom: false,
          child: order == null
              ? (_error == null ? const Center(child: CampusLoading(label: '正在读取订单', network: true, remote: '胖乖生活')) : CampusLoadError(message: _error!, onRetry: () => unawaited(_load())))
              : CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    CampusRefreshControl(onRefresh: _load),
                    SliverPadding(
                      padding: campusScrollPadding(context, const EdgeInsets.all(16)),
                      sliver: SliverList.list(children: [_summary(context, order), if (order.payable) ...[const SizedBox(height: CampusGap.large), _payment(context, order)]]),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _summary(BuildContext context, PangguaiOrder order) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    final endsAt = order.endsAt;
    final left = endsAt?.difference(DateTime.now().toUtc());
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(order.machine.isEmpty ? '设备订单' : order.machine, style: Theme.of(context).textTheme.titleMedium),
          if ([order.program, order.shop].any((part) => part.isNotEmpty)) DotSeparatedText([order.program, order.shop].where((part) => part.isNotEmpty).join(' · '), style: secondary),
          const SizedBox(height: CampusGap.large),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(child: Text(order.statusLabel, style: const TextStyle(fontSize: CampusFontSize.title, fontWeight: FontWeight.w600))),
              Text('¥${lifeYuan(order.price)}', style: const TextStyle(fontSize: CampusFontSize.title, fontWeight: FontWeight.w600)),
            ],
          ),
          if (order.running && endsAt != null && left != null) ...[
            const SizedBox(height: CampusGap.small),
            DotSeparatedText('预计 ${formatCampusClock(endsAt)} 结束 · ${left.inSeconds > 0 ? '还剩 ${(left.inSeconds / 60).ceil()} 分钟' : '快好了'}', style: secondary),
          ],
          if (order.paidAt case final paidAt?) ...[
            const SizedBox(height: CampusGap.small),
            Text('${formatCampusRelative(paidAt.toIso8601String())} 付款', style: secondary),
          ],
        ],
      ),
    );
  }

  // 付款区：按钮的位置原地显示准备、在支付宝里、确认中。
  Widget _payment(BuildContext context, PangguaiOrder order) {
    final palette = CampusPalette.of(context);
    final error = _payError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...switch (_pay) {
          _Pay.idle || _Pay.preparing => [
            FilledButton(
              style: campusProminent,
              onPressed: _pay == _Pay.idle ? () => unawaited(_payNow()) : null,
              child: CampusBusyContent(busy: _pay == _Pay.preparing, label: '用支付宝付 ¥${lifeYuan(order.price)}', busyLabel: '准备付款', icon: const CampusIcon(CampusIcons.wallet)),
            ),
          ],
          _Pay.paying => [
            Text('在支付宝里付款，付完回到这里', style: TextStyle(color: palette.onSurfaceVariant)),
            const SizedBox(height: CampusGap.medium),
            FilledButton.icon(onPressed: () => unawaited(_check()), icon: const CampusIcon(CampusIcons.check), label: const Text('我已付款，查结果')),
          ],
          _Pay.checking => [
            const FilledButton(onPressed: null, child: CampusBusyContent(busy: true, label: '确认中', busyLabel: '确认中', icon: CampusIcon(CampusIcons.check))),
          ],
        },
        if (error != null) ...[const SizedBox(height: CampusGap.medium), Text(error, style: TextStyle(color: palette.danger))],
      ],
    );
  }
}

// 订单列表：新的在前，一页 10 条，点「加载更多」往回翻；点进订单页。
class PangguaiOrdersPage extends StatefulWidget {
  const PangguaiOrdersPage({super.key, required this.service, required this.phone});
  final PangguaiService service;
  final String phone;
  @override
  State<PangguaiOrdersPage> createState() => _PangguaiOrdersPageState();
}

class _PangguaiOrdersPageState extends State<PangguaiOrdersPage> {
  final _orders = <PangguaiOrder>[];
  var _page = 0;
  var _more = true;
  var _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_next());
  }

  Future<void> _reload() async {
    setState(() {
      _orders.clear();
      _page = 0;
      _more = true;
    });
    await _next();
  }

  Future<void> _next() async {
    if (_loading || !_more) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = _page + 1;
      final result = await widget.service.run(widget.phone, (token) => widget.service.client.orders(token, page: page));
      if (!mounted) return;
      setState(() {
        _page = page;
        _orders.addAll(result.orders.where((order) => !_orders.any((known) => known.id == order.id)));
        _more = result.orders.length >= PangguaiClient.orderPage;
      });
    } on PangguaiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=orders errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '没读到订单，稍后再试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(PangguaiOrder order) async {
    await Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => PangguaiOrderPage(service: widget.service, phone: widget.phone, orderId: order.id)));
    if (mounted) unawaited(_reload());
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('订单'),
      ),
      body: CampusScrollFade(
        child: SafeArea(
          bottom: false,
          child: _orders.isEmpty && _error != null
              ? CampusLoadError(message: _error!, onRetry: () => unawaited(_next()))
              : _orders.isEmpty && _loading
              ? const Center(child: CampusLoading(label: '正在读取订单', network: true, remote: '胖乖生活'))
              : ListView(
                  padding: campusScrollPadding(context, const EdgeInsets.all(16)),
                  children: [
                    if (_orders.isEmpty) Center(child: Text('还没有订单', style: secondary)),
                    if (_orders.isNotEmpty)
                      CampusSurface(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            for (final order in _orders)
                              InkWell(
                                key: ValueKey(order.id),
                                onTap: () => unawaited(_open(order)),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: CampusGap.medium),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(order.machine.isEmpty ? '设备订单' : order.machine, style: const TextStyle(fontSize: CampusFontSize.body)),
                                            DotSeparatedText(
                                              [order.statusLabel, '¥${lifeYuan(order.price)}', if (order.createdAt case final at?) formatCampusRelative(at.toIso8601String())].join(' · '),
                                              style: secondary,
                                            ),
                                          ],
                                        ),
                                      ),
                                      const CampusIcon(CampusIcons.next),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (_error != null && _orders.isNotEmpty) ...[const SizedBox(height: CampusGap.medium), Text(_error!, style: TextStyle(color: palette.danger))],
                    if (_more && _orders.isNotEmpty) ...[
                      const SizedBox(height: CampusGap.medium),
                      Center(
                        child: OutlinedButton.icon(
                          onPressed: _loading ? null : () => unawaited(_next()),
                          icon: const CampusIcon(CampusIcons.expand),
                          label: CampusBusyContent(busy: _loading, label: '加载更多', busyLabel: '读取中'),
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}
