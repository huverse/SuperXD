import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_field_table.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/life/life_money.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_client.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_coupons_page.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_service.dart';

enum _OrderTab { consume, recharge }

// 消费订单默认往回查多少天（项目配置限制了天数时按配置）。
const zhuliConsumeDays = 365;

// 订单：消费（洗浴等用水的单）与充值两栏，都是点「加载更多」往回翻：消费单一次最多 20 条、用上一页最后一条的时刻当新的截止；
// 充值单按页（从 1 起，回来不满 20 条就到底了）。点一条看详情（现查，不在本机存）。
class ZhuliOrdersPage extends StatefulWidget {
  const ZhuliOrdersPage({super.key, required this.service, required this.phone});
  final ZhuliService service;
  final String phone;
  @override
  State<ZhuliOrdersPage> createState() => _ZhuliOrdersPageState();
}

class _ZhuliOrdersPageState extends State<ZhuliOrdersPage> {
  var _tab = _OrderTab.consume;
  final _consume = <ZhuliConsumeRecord>[];
  final _recharge = <ZhuliRechargeOrder>[];
  // 消费单的查询起点（按项目配置定一次）与下一页的截止时刻；为空表示到底了。
  DateTime? _since;
  DateTime? _consumeEnd = DateTime.now();
  int? _rechargePage = 1;
  final _loading = <_OrderTab>{};
  final _loaded = <_OrderTab>{};
  final _errors = <_OrderTab, String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load(_tab));
  }

  Future<void> _load(_OrderTab tab) async {
    if (_loading.contains(tab)) return;
    setState(() {
      _loading.add(tab);
      _errors.remove(tab);
    });
    try {
      await widget.service.run(widget.phone, (session) => tab == _OrderTab.consume ? _moreConsume(session) : _moreRecharge(session));
      if (mounted) setState(() => _loaded.add(tab));
    } on ZhuliException catch (error) {
      if (mounted) setState(() => _errors[tab] = error.message);
    } catch (error, stack) {
      campusLog('[Zhuli] action=orders errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _errors[tab] = '没读到订单，稍后再试');
    } finally {
      if (mounted) setState(() => _loading.remove(tab));
    }
  }

  Future<void> _moreConsume(ZhuliSession session) async {
    final end = _consumeEnd;
    if (end == null) return;
    final since = _since ??= end.subtract(Duration(days: (await widget.service.client.config(session)).consumeOrderDays ?? zhuliConsumeDays));
    final page = await widget.service.client.consumeRecords(session, start: since, end: end);
    if (!mounted) return;
    final last = page.isEmpty ? null : zhuliMoment(page.last.createAt);
    setState(() {
      _consume.addAll(page.where((record) => !_consume.any((known) => known.orderId == record.orderId)));
      _consumeEnd = page.length < ZhuliClient.consumePage || last == null ? null : DateTime.parse(last);
    });
  }

  Future<void> _moreRecharge(ZhuliSession session) async {
    final page = _rechargePage;
    if (page == null) return;
    final rows = await widget.service.client.rechargeOrders(session, page: page);
    if (!mounted) return;
    setState(() {
      _recharge.addAll(rows.where((order) => !_recharge.any((known) => known.outTradeNo == order.outTradeNo)));
      _rechargePage = rows.length < ZhuliClient.rechargePage ? null : page + 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final loaded = _loaded.contains(_tab), loading = _loading.contains(_tab), error = _errors[_tab];
    final more = _tab == _OrderTab.consume ? _consumeEnd != null : _rechargePage != null;
    final empty = _tab == _OrderTab.consume ? _consume.isEmpty : _recharge.isEmpty;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('订单'),
      ),
      body: CampusScrollFade(
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: campusScrollPadding(context, const EdgeInsets.all(16)),
            children: [
              CampusSegmented<_OrderTab>(
                values: _OrderTab.values,
                label: (tab) => tab == _OrderTab.consume ? '消费' : '充值',
                selected: _tab,
                onSelected: (tab) {
                  setState(() => _tab = tab);
                  if (!_loaded.contains(tab)) unawaited(_load(tab));
                },
              ),
              const SizedBox(height: CampusGap.large),
              if (!loaded && error != null)
                CampusLoadError(message: error, onRetry: () => unawaited(_load(_tab)))
              else if (!loaded)
                const CampusLoading(label: '正在读取订单', inline: true, network: true, remote: '住理生活')
              else if (empty)
                Padding(
                  padding: const EdgeInsets.only(top: CampusGap.section),
                  child: Center(child: Text(_tab == _OrderTab.consume ? '没有消费订单' : '没有充值订单', style: TextStyle(color: palette.onSurfaceVariant))),
                )
              else ...[
                if (_tab == _OrderTab.consume)
                  for (final record in _consume) _row(context, key: record.orderId, title: [zhuliConsumeType(record.consumeType), if (zhuliOrderDevice(record.orderId) case final device?) '设备号 $device' else if (record.deviceName.isNotEmpty) record.deviceName].join(' · '), time: record.createAt, status: zhuliConsumeStatus(record.status), money: record.money, sheet: () => _BillSheet(service: widget.service, phone: widget.phone, orderId: record.orderId))
                else
                  for (final order in _recharge) _row(context, key: order.outTradeNo, title: '充值', time: order.createAt, status: zhuliRechargeStatus(order.status), money: order.value, sheet: () => _RechargeSheet(service: widget.service, phone: widget.phone, outTradeNo: order.outTradeNo)),
                if (more)
                  Center(
                    child: TextButton.icon(
                      onPressed: loading ? null : () => unawaited(_load(_tab)),
                      icon: const CampusIcon(CampusIcons.expand),
                      label: CampusBusyContent(busy: loading, label: '加载更多', busyLabel: '读取中'),
                    ),
                  ),
                if (error != null) Text(error, style: TextStyle(color: palette.danger)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, {required String key, required String title, required String time, required String status, required int money, required Widget Function() sheet}) {
    final secondary = TextStyle(color: CampusPalette.of(context).onSurfaceVariant);
    return Padding(
      key: ValueKey(key),
      padding: const EdgeInsets.only(bottom: CampusGap.small),
      child: CampusSurface(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        onTap: () => unawaited(showCampusSheet<void>(context: context, builder: (_) => sheet())),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DotSeparatedText(title),
                  DotSeparatedText('${zhuliShownTime(time)} · $status', style: secondary),
                ],
              ),
            ),
            Text('¥${lifeYuan(money)}', style: const TextStyle(fontSize: CampusFontSize.cardTitle, fontWeight: FontWeight.w600)),
            const SizedBox(width: CampusGap.small),
            const CampusIcon(CampusIcons.next),
          ],
        ),
      ),
    );
  }
}

// 详情弹层的公共壳：标题、加载、读不到时重试。
class _DetailSheet<T> extends StatefulWidget {
  const _DetailSheet({required this.title, required this.read, required this.rows});
  final String title;
  final Future<T> Function() read;
  final List<(String, String)> Function(T value) rows;
  @override
  State<_DetailSheet<T>> createState() => _DetailSheetState<T>();
}

class _DetailSheetState<T> extends State<_DetailSheet<T>> {
  late Future<T> _value = widget.read();

  @override
  Widget build(BuildContext context) => CampusSheetPanel(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: CampusGap.medium),
          FutureBuilder<T>(
            future: _value,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                final error = snapshot.error;
                return CampusLoadError(message: error is ZhuliException ? error.message : '没读到详情', onRetry: () => setState(() {
                  _value = widget.read();
                }));
              }
              if (snapshot.connectionState != ConnectionState.done) return const CampusLoading(label: '正在读取', inline: true);
              return CampusFieldTable(rows: widget.rows(snapshot.data as T));
            },
          ),
        ],
      ),
    ),
  );
}

// 消费订单详情：用水、预扣与实扣、各渠道扣了多少（券、余额、支付），都是住理给的结算结果。
class _BillSheet extends StatelessWidget {
  const _BillSheet({required this.service, required this.phone, required this.orderId});
  final ZhuliService service;
  final String phone;
  final String orderId;

  @override
  Widget build(BuildContext context) => _DetailSheet<ZhuliBill>(
    title: '消费详情',
    read: () => service.run(phone, (session) => service.client.bill(session, orderId)),
    rows: (bill) => [
      ('类型', zhuliConsumeType(bill.consumeType)),
      ('设备', [if (bill.deviceName.isNotEmpty) bill.deviceName, if ((bill.deviceId > 0 ? bill.deviceId : zhuliOrderDevice(bill.orderId)) case final device?) '设备号 $device'].join(' · ')),
      ('位置', bill.place),
      ('开始', zhuliShownTime(bill.createAt)),
      if (bill.consumeType == 'bath') ('用水', '${bill.liters.toStringAsFixed(2)} 升 · ${bill.seconds} 秒'),
      if (bill.prepaid > 0) ('预扣', '¥${lifeYuan(bill.prepaid)}'),
      ('实扣', '¥${lifeYuan(bill.money)}'),
      if (bill.refund > 0) ('退回', '¥${lifeYuan(bill.refund)}'),
      ('扣款', [if (bill.fromCoupon != 0) '券 ¥${lifeYuan(bill.fromCoupon)}', if (bill.fromBalance != 0) '余额 ¥${lifeYuan(bill.fromBalance)}', if (bill.fromPay != 0) '支付 ¥${lifeYuan(bill.fromPay)}'].join('、')),
      ('状态', zhuliConsumeStatus(bill.status)),
      ('订单号', bill.orderId),
    ],
  );
}

class _RechargeSheet extends StatelessWidget {
  const _RechargeSheet({required this.service, required this.phone, required this.outTradeNo});
  final ZhuliService service;
  final String phone;
  final String outTradeNo;

  @override
  Widget build(BuildContext context) => _DetailSheet<ZhuliRechargeOrder>(
    title: '充值详情',
    read: () => service.run(phone, (session) => service.client.rechargeOrder(session, outTradeNo)),
    rows: (order) => [
      ('金额', '¥${lifeYuan(order.value)}'),
      ('状态', zhuliRechargeStatus(order.status)),
      if (order.rechargeType != null) ('支付方式', zhuliPayChannel(order.rechargeType)),
      ('下单', zhuliShownTime(order.createAt)),
      if (order.paid && zhuliMoment(order.payTime) != null) ('到账', zhuliShownTime(order.payTime)),
      if (order.paid && order.balance != null) ('到账后余额', '¥${lifeYuan(order.balance!)}'),
      ('订单号', order.outTradeNo),
      if (order.tradeNo.isNotEmpty) ('交易号', order.tradeNo),
    ],
  );
}
