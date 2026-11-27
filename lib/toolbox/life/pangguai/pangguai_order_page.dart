import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_field_table.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/life/life_money.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_service.dart';

String _countdown(Duration left) {
  final seconds = left.inSeconds < 0 ? 0 : left.inSeconds;
  return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

enum _Pay { idle, ordering, paying, checking, pending }

// 一笔订单：待付款时付款或取消（创建 5 分钟内能付，过了只能删，同官方 App）；使用中倒计时到预计结束（付款后 3 分钟内可以重新启动）；完成后写已完成。
// 付款：问收银台能用哪些方式（这一版只有支付宝，PangguaiPayMethod）→ 拿支付串交给支付宝 → 支付宝返回、回到前台或点「我已付款」时去胖乖查（2 秒一次、最多 15 次），
// 订单变成使用中就是付好了、胖乖已经下发开机（开机由胖乖服务器做，客户端没有启动设备的接口）；支付宝报取消或失败时查一次没付就回到能再付的样子，都原地显示。
// autoPay：从设备页下完单换过来，打开就开始付。title 是设备名（订单详情里没有）。
class PangguaiOrderPage extends StatefulWidget {
  const PangguaiOrderPage({super.key, required this.service, required this.phone, required this.orderId, this.orgId, this.title = '', this.autoPay = false, this.onClose, this.clock});
  final PangguaiService service;
  final String phone;
  final String orderId;
  // 门店的数字编号（问收银台要它）；从首页进来的不知道时为空。
  final String? orgId;
  final String title;
  final bool autoPay;
  // 换页进来的（设备页下完单换成本页），来的那一页等不到返回，关掉时经它刷新。
  final VoidCallback? onClose;
  final DateTime Function()? clock;
  @override
  State<PangguaiOrderPage> createState() => _PangguaiOrderPageState();
}

class _PangguaiOrderPageState extends State<PangguaiOrderPage> with WidgetsBindingObserver {
  PangguaiOrder? _order;
  String? _loadError;
  var _pay = _Pay.idle;
  String? _payError;
  // 支付宝报的结果码（这一次的）。
  String? _status;
  var _busy = false;
  Timer? _tick;
  // 使用中到点后只自动再查一次。
  var _refreshedAtEnd = false;

  DateTime _now() => (widget.clock ?? DateTime.now)().toUtc();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    unawaited(_load(pay: widget.autoPay));
  }

  @override
  void dispose() {
    widget.onClose?.call();
    _tick?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 从支付宝回来：付没付都去胖乖查一次（SDK 的回调可能回不来）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _pay == _Pay.paying) unawaited(_check());
  }

  void _onTick() {
    final order = _order;
    if (!mounted || order == null) return;
    if (order.status == pangguaiInUse && order.endsAt != null && !_refreshedAtEnd && _now().isAfter(order.endsAt!.add(const Duration(seconds: 5)))) {
      _refreshedAtEnd = true;
      unawaited(_load());
    }
    if (order.status == pangguaiUnpaid || order.status == pangguaiInUse) setState(() {});
  }

  Future<void> _load({bool pay = false}) async {
    try {
      final order = await widget.service.run(widget.phone, (token) => widget.service.client.order(token, widget.orderId));
      if (!mounted) return;
      setState(() {
        _order = order;
        _loadError = null;
      });
      if (pay && order.payable(_now())) await _startPay();
    } on PangguaiException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=order_load errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _loadError = '没读到订单，稍后再试');
    }
  }

  Future<void> _startPay() async {
    final order = _order!;
    setState(() {
      _pay = _Pay.ordering;
      _payError = null;
      _status = null;
    });
    final String content;
    try {
      final methods = await widget.service.payMethods(widget.phone, order.orderNo, widget.orgId);
      if (!methods.contains(PangguaiPayMethod.alipay)) return _failPay('这单不能用支付宝付，去胖乖生活 App 里付');
      content = await widget.service.run(widget.phone, (token) => widget.service.client.alipayOrder(token, order.orderNo));
    } on PangguaiException catch (error) {
      if (mounted) _failPay(error.message);
      return;
    } catch (error, stack) {
      campusLog('[Pangguai] action=pay_order errorType=${error.runtimeType}\n$stack');
      if (mounted) _failPay('没拿到付款单，稍后再试');
      return;
    }
    if (!mounted) return;
    setState(() => _pay = _Pay.paying);
    campusLog('[Pangguai] action=pay_start');
    try {
      final status = await widget.service.alipay.pay(content);
      campusLog('[Pangguai] action=pay_returned status=$status');
      _status = status;
      if (!mounted || _pay != _Pay.paying) return;
      if (status == '6001') return _failPay('已取消付款');
      unawaited(_check());
    } catch (error, stack) {
      campusLog('[Pangguai] action=pay errorType=${error.runtimeType}\n$stack');
      if (mounted && _pay == _Pay.paying) unawaited(_check());
    }
  }

  void _failPay(String message) => setState(() {
    _pay = _Pay.idle;
    _payError = message;
  });

  // 去胖乖查付没付：订单不再是待付款就是付好了。
  Future<void> _check() async {
    if (_pay == _Pay.checking) return;
    setState(() => _pay = _Pay.checking);
    for (var attempt = 0; attempt < 15; attempt++) {
      try {
        final order = await widget.service.run(widget.phone, (token) => widget.service.client.order(token, widget.orderId));
        if (!mounted) return;
        if (order.status != pangguaiUnpaid) {
          campusLog('[Pangguai] action=pay_confirmed attempt=$attempt');
          setState(() {
            _order = order;
            _pay = _Pay.idle;
          });
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
    switch (_status) {
      case '6001':
        _failPay('已取消付款');
      case '4000':
        _failPay('付款没成功，可以再付一次');
      default:
        setState(() => _pay = _Pay.pending);
    }
  }

  Future<void> _act(Future<void> Function(String token) action, String done) async {
    setState(() => _busy = true);
    try {
      await widget.service.run(widget.phone, action);
      if (mounted) showCampusToast(context, done);
    } on PangguaiException catch (error) {
      if (mounted) showCampusToast(context, error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=order_act errorType=${error.runtimeType}\n$stack');
      if (mounted) showCampusToast(context, '没办成，稍后再试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel({required bool expired}) async {
    final agreed = await showCampusConfirm(
      context,
      title: expired ? '删除订单' : '取消订单',
      message: expired ? '这笔订单已失效，从胖乖生活的订单里删掉。' : '取消后这笔订单从胖乖生活的订单里删掉，设备也会放开。',
      action: expired ? '删除' : '取消订单',
      destructive: true,
    );
    if (!agreed || !mounted) return;
    await _act((token) => widget.service.client.cancel(token, widget.orderId), expired ? '订单已删除' : '订单已取消');
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final order = _order;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('订单'),
      ),
      body: CampusScrollFade(
        child: SafeArea(
          bottom: false,
          child: order == null
              ? Center(
                  child: switch (_loadError) {
                    final error? => CampusLoadError(message: error, onRetry: () => unawaited(_load(pay: widget.autoPay))),
                    null => const CampusLoading(label: '正在读取订单', network: true, remote: '胖乖生活'),
                  },
                )
              : ListView(
                  padding: campusScrollPadding(context, const EdgeInsets.all(16)),
                  children: [_summary(context, order), const SizedBox(height: CampusGap.large), _action(context, order)],
                ),
        ),
      ),
    );
  }

  Widget _summary(BuildContext context, PangguaiOrder order) {
    final palette = CampusPalette.of(context);
    final name = widget.title.isNotEmpty ? widget.title : order.device;
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (name.isNotEmpty) Text(name, style: Theme.of(context).textTheme.titleMedium),
          if (order.function.isNotEmpty) DotSeparatedText([order.function, if (order.minutes case final minutes?) '$minutes 分钟'].join(' · '), style: TextStyle(color: palette.onSurfaceVariant)),
          const SizedBox(height: CampusGap.medium),
          CampusFieldTable(rows: [
            (order.status == pangguaiUnpaid ? '应付' : '实付', '¥${lifeYuan(order.cents)}'),
            ('订单号', order.orderNo),
            if (order.createdAt case final created?) ('下单', formatCampusRelative(created.toIso8601String())),
          ]),
        ],
      ),
    );
  }

  Widget _action(BuildContext context, PangguaiOrder order) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    final now = _now();
    final big = const TextStyle(fontSize: CampusFontSize.headline, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()]);
    switch (order.status) {
      case pangguaiUnpaid when !order.payable(now) && _pay == _Pay.idle:
        return CampusSurface(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('超过 5 分钟没付，订单已失效', style: secondary),
              const SizedBox(height: CampusGap.large),
              OutlinedButton.icon(onPressed: _busy ? null : () => unawaited(_cancel(expired: true)), icon: const CampusIcon(CampusIcons.delete), label: const Text('删除订单')),
            ],
          ),
        );
      case pangguaiUnpaid:
        final error = _payError;
        return CampusSurface(
          padding: const EdgeInsets.all(20),
          child: CampusToastAnchor(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (order.createdAt case final created?) Text('${_countdown(created.add(pangguaiPayWindow).difference(now))} 内付款，过时订单失效', style: secondary),
                // 付款方式：这一版只有支付宝（以后接的方式按 PangguaiPayMethod 在这里列出来选）。
                CampusFieldTable(rows: [('付款方式', PangguaiPayMethod.alipay.label)]),
                const SizedBox(height: CampusGap.large),
                ...switch (_pay) {
                  _Pay.idle || _Pay.ordering => [
                    FilledButton(
                      style: campusProminent,
                      onPressed: _pay == _Pay.idle && !_busy ? () => unawaited(_startPay()) : null,
                      child: CampusBusyContent(busy: _pay == _Pay.ordering, label: '用支付宝付 ¥${lifeYuan(order.cents)}', busyLabel: '准备付款', icon: const CampusIcon(CampusIcons.wallet)),
                    ),
                    if (error != null) Padding(padding: const EdgeInsets.only(top: CampusGap.medium), child: Text(error, style: TextStyle(color: palette.danger))),
                    const SizedBox(height: CampusGap.small),
                    OutlinedButton.icon(onPressed: _pay == _Pay.idle && !_busy ? () => unawaited(_cancel(expired: false)) : null, icon: const CampusIcon(CampusIcons.close), label: const Text('取消订单')),
                  ],
                  _Pay.paying => [
                    Text('在支付宝里付款，付完回到这里', style: secondary),
                    const SizedBox(height: CampusGap.medium),
                    FilledButton.icon(onPressed: () => unawaited(_check()), icon: const CampusIcon(CampusIcons.check), label: const Text('我已付款，查结果')),
                  ],
                  _Pay.checking => [
                    const FilledButton(onPressed: null, child: CampusBusyContent(busy: true, label: '确认中', busyLabel: '确认中', icon: CampusIcon(CampusIcons.check))),
                  ],
                  _Pay.pending => [
                    Text('还没查到付款结果，付过了稍等再查', style: secondary),
                    const SizedBox(height: CampusGap.medium),
                    FilledButton.icon(onPressed: () => unawaited(_check()), icon: const CampusIcon(CampusIcons.sync), label: const Text('再查一次')),
                  ],
                },
              ],
            ),
          ),
        );
      case pangguaiInUse:
        final ends = order.endsAt;
        return CampusSurface(
          padding: const EdgeInsets.all(20),
          child: CampusToastAnchor(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(ends == null ? '已付款，等设备启动' : '使用中', style: Theme.of(context).textTheme.titleMedium),
                if (ends != null) ...[
                  const SizedBox(height: CampusGap.tight),
                  Text(_countdown(ends.difference(now)), style: big),
                  Text(now.isBefore(ends) ? '预计 ${formatCampusClock(ends)} 结束' : '快好了', style: secondary),
                ],
                if (order.restartable(now)) ...[
                  const SizedBox(height: CampusGap.large),
                  // 付款后 3 分钟内设备没动，可以让胖乖再下发一次启动。
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => unawaited(_act((token) => widget.service.client.restart(token, order.orderNo), '已让设备重新启动')),
                    icon: const CampusIcon(CampusIcons.restore),
                    label: CampusBusyContent(busy: _busy, label: '设备没启动？重新启动', busyLabel: '发送中'),
                  ),
                ],
              ],
            ),
          ),
        );
      default:
        return CampusSurface(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(order.status == pangguaiFinished ? '已完成' : '订单已结束', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: CampusGap.large),
              CampusToastAnchor(child: FilledButton.icon(onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.check), label: const Text('完成'))),
            ],
          ),
        );
    }
  }
}
