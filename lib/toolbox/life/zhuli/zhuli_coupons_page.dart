import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
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
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_service.dart';

// 住理时间串按校园时区的远近写法显示（今天 13:39、10月28日 00:34）。
String zhuliShownTime(String text) => switch (zhuliMoment(text)) {
  final instant? => formatCampusRelative(instant),
  null => text,
};

class _CouponList {
  final items = <ZhuliCoupon>[];
  var total = 0;
  var page = 0;
  var loading = false;
  var loaded = false;
  String? error;
}

// 我的优惠券：未使用、已用完、已失效三栏（同原 App），每栏一页 20 张、点「加载更多」接着读；点一张看它按月的抵扣记录。
// 券是储值式的（带余额、可多次抵扣），抵扣由住理在消费时自动做，这里只看不选。
class ZhuliCouponsPage extends StatefulWidget {
  const ZhuliCouponsPage({super.key, required this.service, required this.phone});
  final ZhuliService service;
  final String phone;
  @override
  State<ZhuliCouponsPage> createState() => _ZhuliCouponsPageState();
}

class _ZhuliCouponsPageState extends State<ZhuliCouponsPage> {
  var _tab = ZhuliCouponTab.unused;
  final _lists = {for (final tab in ZhuliCouponTab.values) tab: _CouponList()};

  @override
  void initState() {
    super.initState();
    unawaited(_load(_tab));
  }

  Future<void> _load(ZhuliCouponTab tab) async {
    final list = _lists[tab]!;
    if (list.loading) return;
    setState(() {
      list.loading = true;
      list.error = null;
    });
    try {
      final page = await widget.service.run(widget.phone, (session) => widget.service.client.coupons(session, tab, page: list.page));
      if (!mounted) return;
      setState(() {
        list.items.addAll(page.coupons.where((coupon) => !list.items.any((known) => known.id == coupon.id)));
        list.total = page.total;
        list.page++;
        list.loaded = true;
      });
    } on ZhuliException catch (error) {
      if (mounted) setState(() => list.error = error.message);
    } catch (error, stack) {
      campusLog('[Zhuli] action=coupons errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => list.error = '没读到优惠券，稍后再试');
    } finally {
      if (mounted) setState(() => list.loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _lists[_tab]!;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('优惠券'),
      ),
      body: CampusScrollFade(
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: campusScrollPadding(context, const EdgeInsets.all(16)),
            children: [
              CampusSegmented<ZhuliCouponTab>(
                values: ZhuliCouponTab.values,
                label: (tab) => tab.label,
                selected: _tab,
                onSelected: (tab) {
                  setState(() => _tab = tab);
                  if (!_lists[tab]!.loaded) unawaited(_load(tab));
                },
              ),
              const SizedBox(height: CampusGap.large),
              if (!list.loaded && list.error != null)
                CampusLoadError(message: list.error!, onRetry: () => unawaited(_load(_tab)))
              else if (!list.loaded)
                const CampusLoading(label: '正在读取优惠券', inline: true, network: true, remote: '住理生活')
              else if (list.items.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: CampusGap.section),
                  child: Center(child: Text('没有${_tab.label}的券', style: TextStyle(color: CampusPalette.of(context).onSurfaceVariant))),
                )
              else ...[
                for (final coupon in list.items) Padding(padding: const EdgeInsets.only(bottom: CampusGap.medium), child: _card(context, coupon)),
                if (list.items.length < list.total)
                  Center(
                    child: TextButton.icon(
                      onPressed: list.loading ? null : () => unawaited(_load(_tab)),
                      icon: const CampusIcon(CampusIcons.expand),
                      label: CampusBusyContent(busy: list.loading, label: '加载更多', busyLabel: '读取中'),
                    ),
                  ),
                if (list.error case final error?) Text(error, style: TextStyle(color: CampusPalette.of(context).danger)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, ZhuliCoupon coupon) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    return CampusSurface(
      key: ValueKey(coupon.id),
      padding: const EdgeInsets.all(20),
      onTap: () => unawaited(showCampusSheet<void>(context: context, builder: (_) => _CouponRecordsSheet(service: widget.service, phone: widget.phone, coupon: coupon))),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(coupon.name.isEmpty ? '优惠券' : coupon.name, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: CampusGap.tight),
                Text('¥${lifeYuan(coupon.balance)}', style: const TextStyle(fontSize: CampusFontSize.headline, fontWeight: FontWeight.w600)),
                const SizedBox(height: CampusGap.tight),
                DotSeparatedText(
                  [
                    '面额 ¥${lifeYuan(coupon.total)}',
                    if (coupon.useLimit.isNotEmpty) '适用${coupon.useLimit.map(zhuliConsumeType).join('、')}',
                    coupon.couponFirst ? '优先用券' : '优先用余额',
                  ].join(' · '),
                  style: secondary,
                ),
                Text(coupon.permanent ? '长期有效' : '${zhuliShownTime(coupon.expireAt)} 到期', style: secondary),
              ],
            ),
          ),
          const CampusIcon(CampusIcons.next),
        ],
      ),
    );
  }
}

// 一张券的抵扣记录：按月看（住理只认 2026-11 这种月份），默认本月，可往前翻到券生效的那个月。
class _CouponRecordsSheet extends StatefulWidget {
  const _CouponRecordsSheet({required this.service, required this.phone, required this.coupon});
  final ZhuliService service;
  final String phone;
  final ZhuliCoupon coupon;
  @override
  State<_CouponRecordsSheet> createState() => _CouponRecordsSheetState();
}

class _CouponRecordsSheetState extends State<_CouponRecordsSheet> {
  late final String _latest = zhuliClock(DateTime.now()).substring(0, 7);
  late final String _earliest = widget.coupon.startAt.length >= 7 ? widget.coupon.startAt.substring(0, 7) : _latest;
  late String _month = _latest;
  late Future<List<ZhuliCouponRecord>> _records = _read();

  Future<List<ZhuliCouponRecord>> _read() => widget.service.run(widget.phone, (session) => widget.service.client.couponRecords(session, widget.coupon.id, _month));

  // 月份加减：2026-01 往前是 2025-12。
  String _shift(int delta) {
    final year = int.parse(_month.substring(0, 4)), month = int.parse(_month.substring(5, 7)) - 1 + delta;
    final shifted = year * 12 + month;
    return '${shifted ~/ 12}-${(shifted % 12 + 1).toString().padLeft(2, '0')}';
  }

  void _go(int delta) => setState(() {
    _month = _shift(delta);
    _records = _read();
  });

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return CampusSheetPanel(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.coupon.name.isEmpty ? '抵扣记录' : '${widget.coupon.name}的抵扣记录', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: CampusGap.small),
            Row(
              children: [
                IconButton(tooltip: '上个月', onPressed: _month.compareTo(_earliest) > 0 ? () => _go(-1) : null, icon: const CampusIcon(CampusIcons.previous)),
                Expanded(child: Text('${_month.substring(0, 4)}年${int.parse(_month.substring(5, 7))}月', textAlign: TextAlign.center)),
                IconButton(tooltip: '下个月', onPressed: _month.compareTo(_latest) < 0 ? () => _go(1) : null, icon: const CampusIcon(CampusIcons.next)),
              ],
            ),
            Flexible(
              child: FutureBuilder<List<ZhuliCouponRecord>>(
                future: _records,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    final error = snapshot.error;
                    return CampusLoadError(message: error is ZhuliException ? error.message : '没读到记录', onRetry: () => setState(() {
                      _records = _read();
                    }));
                  }
                  if (snapshot.connectionState != ConnectionState.done) return const CampusLoading(label: '正在读取', inline: true);
                  final records = snapshot.data!;
                  if (records.isEmpty) return Padding(padding: const EdgeInsets.all(CampusGap.section), child: Center(child: Text('这个月没有抵扣', style: TextStyle(color: palette.onSurfaceVariant))));
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: records.length,
                    separatorBuilder: (_, _) => const Divider(height: CampusGap.large),
                    itemBuilder: (context, index) {
                      final record = records[index];
                      return Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(zhuliConsumeType(record.consumeType)),
                                Text(zhuliShownTime(record.createAt), style: TextStyle(color: palette.onSurfaceVariant)),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(lifeYuan(record.value)),
                              Text('余 ${lifeYuan(record.couponBalance)}', style: TextStyle(color: palette.onSurfaceVariant)),
                            ],
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
