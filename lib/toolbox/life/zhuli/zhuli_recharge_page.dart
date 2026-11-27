import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/toolbox/life/life_money.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_pay.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_service.dart';

// 自定义充值金额的范围（用户 11-22 选 0.01–500 元、最多两位小数；住理只拒负数，0 与 0.001 都能下单，必须客户端限住）。
const zhuliRechargeMin = 1;
const zhuliRechargeMax = 50000;

// 输入的金额换成分；不是 0.01–500 元、最多两位小数的为空。
int? zhuliRechargeCents(String text) {
  if (!RegExp(r'^\d{1,3}(\.\d{1,2})?$').hasMatch(text.trim())) return null;
  final cents = lifeCents(text.trim());
  return cents != null && cents >= zhuliRechargeMin && cents <= zhuliRechargeMax ? cents : null;
}

// 充值：住理给的几档额度点选，也能输其他金额（0.01–500 元）；用支付宝付，付完去住理查到账、刷新余额（结账见 zhuli_pay.dart）。
class ZhuliRechargePage extends StatefulWidget {
  const ZhuliRechargePage({super.key, required this.service, required this.phone});
  final ZhuliService service;
  final String phone;
  @override
  State<ZhuliRechargePage> createState() => _ZhuliRechargePageState();
}

class _ZhuliRechargePageState extends State<ZhuliRechargePage> {
  late Future<({ZhuliConfig config, List<ZhuliQuota> quotas, int balance})> _ready = _read();
  final _custom = TextEditingController();
  // 选中的额度（分）；为空是在输其他金额。
  int? _quota;
  var _typing = false;
  int? _balance;

  Future<({ZhuliConfig config, List<ZhuliQuota> quotas, int balance})> _read() => widget.service.run(widget.phone, (session) async {
    final values = await Future.wait<Object>([widget.service.client.config(session), widget.service.client.quotas(session), widget.service.client.profile(session)]);
    final quotas = values[1] as List<ZhuliQuota>;
    _quota ??= quotas.firstOrNull?.value;
    _typing = quotas.isEmpty;
    return (config: values[0] as ZhuliConfig, quotas: quotas, balance: (values[2] as ZhuliProfile).balance);
  });

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  int? get _cents => _typing ? zhuliRechargeCents(_custom.text) : _quota;

  Future<void> _refreshBalance() async {
    try {
      final profile = await widget.service.run(widget.phone, widget.service.client.profile);
      if (mounted) setState(() => _balance = profile.balance);
    } catch (error, stack) {
      campusLog('[Zhuli] action=recharge_balance errorType=${error.runtimeType}\n$stack');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
      title: const Text('充值'),
    ),
    body: CampusScrollFade(
      child: SafeArea(
        bottom: false,
        child: FutureBuilder(
          future: _ready,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              final error = snapshot.error;
              return CampusLoadError(message: error is ZhuliException ? error.message : '没读到充值信息', onRetry: () => setState(() {
                _ready = _read();
              }));
            }
            if (snapshot.connectionState != ConnectionState.done) return const Center(child: CampusLoading(label: '正在读取', network: true, remote: '住理生活'));
            final data = snapshot.data!;
            return ListView(padding: campusScrollPadding(context, const EdgeInsets.all(16)), children: [_balanceCard(context, _balance ?? data.balance), const SizedBox(height: CampusGap.large), _amountCard(context, data.config, data.quotas)]);
          },
        ),
      ),
    ),
  );

  Widget _balanceCard(BuildContext context, int balance) => CampusSurface(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('余额', style: TextStyle(color: CampusPalette.of(context).onSurfaceVariant)),
        Text('¥${lifeYuan(balance)}', style: const TextStyle(fontSize: CampusFontSize.headline, fontWeight: FontWeight.w600)),
      ],
    ),
  );

  Widget _amountCard(BuildContext context, ZhuliConfig config, List<ZhuliQuota> quotas) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    final closed = config.rechargeClosed ?? (config.alipay ? null : '这个学校没开支付宝付款');
    if (closed != null) return CampusSurface(padding: const EdgeInsets.all(20), child: Text(closed, style: secondary));
    final cents = _cents;
    final gift = _typing ? null : quotas.where((quota) => quota.value == _quota && quota.giftCount > 0).firstOrNull;
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('充多少', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: CampusGap.medium),
          Wrap(
            spacing: CampusGap.small,
            runSpacing: CampusGap.small,
            children: [
              for (final quota in quotas)
                CampusGlassChip(
                  key: ValueKey(quota.value),
                  label: '¥${lifeYuan(quota.value).replaceAll('.00', '')}',
                  selected: !_typing && _quota == quota.value,
                  onSelected: (_) => setState(() {
                    _typing = false;
                    _quota = quota.value;
                  }),
                ),
              CampusGlassChip(label: '其他金额', selected: _typing, onSelected: (_) => setState(() => _typing = true)),
            ],
          ),
          if (_typing) ...[
            SizedBox(height: campusFieldGap(context)),
            TextField(
              controller: _custom,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')), LengthLimitingTextInputFormatter(6)],
              decoration: InputDecoration(
                labelText: '金额（元）',
                errorText: _custom.text.isNotEmpty && cents == null ? '${lifeYuan(zhuliRechargeMin)} 到 ${lifeYuan(zhuliRechargeMax)} 元，最多两位小数' : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
          if (gift != null) Padding(padding: const EdgeInsets.only(top: CampusGap.small), child: Text('送 ${gift.giftCount} 张 ¥${lifeYuan(gift.giftMoney)} 的券', style: secondary)),
          const SizedBox(height: CampusGap.large),
          ZhuliCheckout(
            key: ValueKey(cents),
            service: widget.service,
            phone: widget.phone,
            label: cents == null ? '用支付宝付' : '用支付宝付 ¥${lifeYuan(cents)}',
            enabled: cents != null,
            order: (session) => widget.service.client.recharge(session, cents!),
            paid: (session, orderId) async => (await widget.service.client.rechargeOrder(session, orderId)).paid,
            pendingHint: '付款结果还在确认，稍后在订单的「充值」里看',
            onPaid: () => unawaited(_refreshBalance()),
          ),
        ],
      ),
    );
  }
}

// 买券：住理在卖的券（售价，面额、先用券还是先用余额与限购）；点「购买」在弹层里用支付宝付。
class ZhuliShopPage extends StatefulWidget {
  const ZhuliShopPage({super.key, required this.service, required this.phone});
  final ZhuliService service;
  final String phone;
  @override
  State<ZhuliShopPage> createState() => _ZhuliShopPageState();
}

class _ZhuliShopPageState extends State<ZhuliShopPage> {
  late Future<({ZhuliConfig config, List<ZhuliGoods> goods})> _ready = _read();

  Future<({ZhuliConfig config, List<ZhuliGoods> goods})> _read() => widget.service.run(widget.phone, (session) async {
    final values = await Future.wait<Object>([widget.service.client.config(session), widget.service.client.goods(session)]);
    return (config: values[0] as ZhuliConfig, goods: values[1] as List<ZhuliGoods>);
  });

  Future<void> _buy(ZhuliGoods goods) async {
    await showCampusSheet<void>(context: context, builder: (_) => _BuySheet(service: widget.service, phone: widget.phone, goods: goods));
    if (mounted) {
      setState(() {
        _ready = _read();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
      title: const Text('买券'),
    ),
    body: CampusScrollFade(
      child: SafeArea(
        bottom: false,
        child: FutureBuilder(
          future: _ready,
          builder: (context, snapshot) {
            final palette = CampusPalette.of(context);
            if (snapshot.hasError) {
              final error = snapshot.error;
              return CampusLoadError(message: error is ZhuliException ? error.message : '没读到在卖的券', onRetry: () => setState(() {
                _ready = _read();
              }));
            }
            // 买完回来重读时照旧显示上一份（FutureBuilder 换了 future 仍留着上一份数据），不清空再出现（11-23 用户：页面闪）；只有第一次读才出加载。
            final data = snapshot.data;
            if (data == null) return const Center(child: CampusLoading(label: '正在读取', network: true, remote: '住理生活'));
            if (!data.config.alipay) return Center(child: Text('这个学校没开支付宝付款', style: TextStyle(color: palette.onSurfaceVariant)));
            if (data.goods.isEmpty) return Center(child: Text('现在没有在卖的券', style: TextStyle(color: palette.onSurfaceVariant)));
            return ListView(
              padding: campusScrollPadding(context, const EdgeInsets.all(16)),
              children: [for (final goods in data.goods) Padding(key: ValueKey(goods.id), padding: const EdgeInsets.only(bottom: CampusGap.medium), child: _card(context, goods))],
            );
          },
        ),
      ),
    ),
  );

  Widget _card(BuildContext context, ZhuliGoods goods) {
    final secondary = TextStyle(color: CampusPalette.of(context).onSurfaceVariant);
    final unavailable = goods.unavailable;
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(goods.name.isEmpty ? '优惠券' : goods.name, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: CampusGap.tight),
          Text('¥${lifeYuan(goods.price)}', style: const TextStyle(fontSize: CampusFontSize.headline, fontWeight: FontWeight.w600)),
          DotSeparatedText(zhuliGoodsDetail(goods).join(' · '), style: secondary),
          const SizedBox(height: CampusGap.medium),
          FilledButton.icon(
            onPressed: unavailable == null ? () => unawaited(_buy(goods)) : null,
            icon: const CampusIcon(CampusIcons.shop),
            label: Text(unavailable ?? '购买'),
          ),
        ],
      ),
    );
  }
}

// [人工决策-2026-11-23 12:47:51] 券的说明只留面额、先用谁与限购（用户：买券页与购买弹层都只要这三项，适用范围、有效期、剩余张数与使用规则这些冗余描述不要）。
List<String> zhuliGoodsDetail(ZhuliGoods goods) => [
  '面额 ¥${lifeYuan(goods.money)}',
  goods.couponFirst ? '优先用券' : '优先用余额',
  if (goods.limit > 0) '限购 ${goods.limit} 张',
];

class _BuySheet extends StatelessWidget {
  const _BuySheet({required this.service, required this.phone, required this.goods});
  final ZhuliService service;
  final String phone;
  final ZhuliGoods goods;

  @override
  Widget build(BuildContext context) {
    final secondary = TextStyle(color: CampusPalette.of(context).onSurfaceVariant);
    return CampusSheetPanel(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('买 ${goods.name.isEmpty ? '优惠券' : goods.name}', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: CampusGap.small),
            DotSeparatedText(zhuliGoodsDetail(goods).join(' · '), style: secondary),
            const SizedBox(height: CampusGap.large),
            ZhuliCheckout(
              service: service,
              phone: phone,
              label: '用支付宝付 ¥${lifeYuan(goods.price)}',
              order: (session) => service.client.buyCoupon(session, goods.id),
              paid: (session, orderId) => service.client.couponPaid(session, orderId),
              pendingHint: '付款结果还在确认，稍后在「优惠券」里看',
              onPaid: () {},
            ),
          ],
        ),
      ),
    );
  }
}
