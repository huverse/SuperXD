import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tobias/tobias.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_service.dart';

// 支付宝付款的端口：把住理给的支付串交给支付宝，返回支付宝报的结果码（9000 成功、6001 取消…）。
// 结果码只作提示，到没到账只认住理（到账由住理收支付宝的回调写库，客户端只查）。
abstract interface class ZhuliPayer {
  Future<String> pay(String orderContent);
}

// 插件 tobias（支付宝 SDK 15.8，用户 11-22 选的）。安卓没装支付宝时 SDK 自己开网页收银台；
// iOS 付完经 Info.plist 里 CFBundleURLName 为 alipay 的 scheme 回来，自签证书配不了通用链接、应用又是场景模式，SDK 的回调不一定回得来，
// 所以结账不只等它：回到前台或点「我已付款」也去住理查（见 ZhuliCheckout）。
class TobiasZhuliPayer implements ZhuliPayer {
  final _tobias = Tobias();

  @override
  Future<String> pay(String orderContent) async => '${(await _tobias.pay(orderContent))['resultStatus'] ?? ''}';
}

enum _Step { idle, ordering, paying, checking, paid, pending }

// 结账（充值与买券共用）：下单 → 交给支付宝 → 支付宝返回、回到前台或点「我已付款」时去住理查到账（1 秒一次、最多 10 次，资料 5.5 的建议）
// → 付好了，或「还在确认」可再查一次；支付宝报取消或失败（6001、4000）时查一次没到账就回到能再付的样子（回到前台可能比结果码先到，所以查着时也认）。
// 都在按钮的位置原地显示。订单 5 分钟没付住理自己关掉。
class ZhuliCheckout extends StatefulWidget {
  const ZhuliCheckout({
    super.key,
    required this.service,
    required this.phone,
    required this.label,
    required this.order,
    required this.paid,
    required this.pendingHint,
    required this.onPaid,
    this.enabled = true,
  });
  final ZhuliService service;
  final String phone;
  // 付款按钮上的字（用支付宝付 ¥20.00）。
  final String label;
  final Future<ZhuliPayOrder> Function(ZhuliSession session) order;
  final Future<bool> Function(ZhuliSession session, String orderId) paid;
  // 查不到到账时告诉人去哪看。
  final String pendingHint;
  final VoidCallback onPaid;
  final bool enabled;
  @override
  State<ZhuliCheckout> createState() => _ZhuliCheckoutState();
}

class _ZhuliCheckoutState extends State<ZhuliCheckout> with WidgetsBindingObserver {
  var _step = _Step.idle;
  String? _orderId;
  String? _error;
  // 支付宝报的结果码（这一单的）。
  String? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 从支付宝回来：付没付都去住理查一次（SDK 的回调可能回不来）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _step == _Step.paying) unawaited(_check());
  }

  Future<void> _start() async {
    setState(() {
      _step = _Step.ordering;
      _error = null;
      _status = null;
    });
    final ZhuliPayOrder order;
    try {
      order = await widget.service.run(widget.phone, widget.order);
    } on ZhuliException catch (error) {
      if (mounted) _fail(error.message);
      return;
    } catch (error, stack) {
      campusLog('[Zhuli] action=pay_order errorType=${error.runtimeType}\n$stack');
      if (mounted) _fail('没下成单，稍后再试');
      return;
    }
    if (!mounted) return;
    setState(() {
      _orderId = order.orderId;
      _step = _Step.paying;
    });
    campusLog('[Zhuli] action=pay_start');
    try {
      final status = await widget.service.payer.pay(order.orderContent);
      campusLog('[Zhuli] action=pay_returned status=$status');
      _status = status;
      if (!mounted || _step != _Step.paying) return;
      if (status == '6001') return _fail('已取消付款');
      unawaited(_check());
    } catch (error, stack) {
      campusLog('[Zhuli] action=pay errorType=${error.runtimeType}\n$stack');
      if (mounted && _step == _Step.paying) unawaited(_check());
    }
  }

  void _fail(String message) => setState(() {
    _step = _Step.idle;
    _error = message;
  });

  Future<void> _check() async {
    final orderId = _orderId;
    if (orderId == null || _step == _Step.checking) return;
    setState(() => _step = _Step.checking);
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        if (await widget.service.run(widget.phone, (session) => widget.paid(session, orderId))) {
          campusLog('[Zhuli] action=pay_confirmed attempt=$attempt');
          if (!mounted) return;
          setState(() => _step = _Step.paid);
          widget.onPaid();
          return;
        }
      } catch (error) {
        campusLog('[Zhuli] action=pay_check reason=${error.runtimeType}');
      }
      if (_status case '6001' || '4000') break;
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted) return;
    }
    if (!mounted) return;
    campusLog('[Zhuli] action=pay_unconfirmed status=$_status');
    switch (_status) {
      case '6001':
        _fail('已取消付款');
      case '4000':
        _fail('付款没成功，可以再付一次');
      default:
        setState(() => _step = _Step.pending);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    final error = _error;
    return CampusToastAnchor(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: switch (_step) {
          _Step.idle || _Step.ordering => [
            FilledButton(
              style: campusProminent,
              onPressed: _step == _Step.idle && widget.enabled ? () => unawaited(_start()) : null,
              child: CampusBusyContent(busy: _step == _Step.ordering, label: widget.label, busyLabel: '下单中', icon: const CampusIcon(CampusIcons.wallet)),
            ),
            if (error != null) Padding(padding: const EdgeInsets.only(top: CampusGap.medium), child: Text(error, style: TextStyle(color: palette.danger))),
          ],
          _Step.paying => [
            Text('在支付宝里付款，付完回到这里', style: secondary),
            const SizedBox(height: CampusGap.medium),
            FilledButton.icon(onPressed: () => unawaited(_check()), icon: const CampusIcon(CampusIcons.check), label: const Text('我已付款，查结果')),
          ],
          _Step.checking => [
            FilledButton(onPressed: null, child: CampusBusyContent(busy: true, label: '确认中', busyLabel: '确认中', icon: const CampusIcon(CampusIcons.check))),
          ],
          _Step.paid => [
            Text('付款成功', style: Theme.of(context).textTheme.titleMedium),
          ],
          _Step.pending => [
            Text(widget.pendingHint, style: secondary),
            const SizedBox(height: CampusGap.medium),
            FilledButton.icon(onPressed: () => unawaited(_check()), icon: const CampusIcon(CampusIcons.sync), label: const Text('再查一次')),
          ],
        },
      ),
    );
  }
}
