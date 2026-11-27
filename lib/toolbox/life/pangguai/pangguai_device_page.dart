import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/life/life_money.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_client.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_order_page.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_service.dart';

// 一台设备（先付后用的洗衣机、洗鞋机、烘干机、吹风机）：设备名、品类与门店、能不能用；有档位的先选（洗衣机选程序，吹风机、烘干机先选功能位再选时长），
// 只有一个档位且不分时长的不用选、直接下一步；点「下单并付款」由服务按顺序重发四步下单（价变了先停下请人确认），下好单换成订单页、接着用支付宝付。
// 先用后付的饮水机与淋浴这一版不接（原生的以后再说），写明去胖乖生活 App 用。
// 扫码进来的给 code（打开时先问胖乖是哪台），其余给 goodsId；扫码页直接换成本页，来的那一页等不到返回，关掉时经 onClose 让它刷新。
class PangguaiDevicePage extends StatefulWidget {
  const PangguaiDevicePage({super.key, required this.service, required this.phone, this.goodsId, this.code, this.onClose, this.clock}) : assert(goodsId != null || code != null);
  final PangguaiService service;
  final String phone;
  final String? goodsId;
  final PangguaiGoodsCode? code;
  final VoidCallback? onClose;
  // 测试注入时钟（交给订单页）。
  final DateTime Function()? clock;
  @override
  State<PangguaiDevicePage> createState() => _PangguaiDevicePageState();
}

class _PangguaiDevicePageState extends State<PangguaiDevicePage> {
  PangguaiDeviceInfo? _info;
  String? _loadError;
  String? _skuId;
  int? _minutes;
  // 胖乖试算出的新价（和标价不一样时，用户再点一次就按它下单）。
  int? _confirmed;
  var _placing = false;
  String? _placeError;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.onClose?.call();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final code = widget.code;
      final goodsId = widget.goodsId ?? (await widget.service.run(widget.phone, (token) => widget.service.client.scan(token, code!))).goodsId;
      final info = await widget.service.inspect(widget.phone, goodsId);
      if (!mounted) return;
      setState(() {
        _info = info;
        final first = info.skus.firstOrNull;
        _skuId = first?.skuId;
        _minutes = first?.tiers.where((tier) => tier.available).firstOrNull?.minutes;
      });
    } on PangguaiException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=device_load errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _loadError = '没读到设备，稍后再试');
    }
  }

  PangguaiSku? get _sku => _info?.skus.where((sku) => sku.skuId == _skuId).firstOrNull;
  PangguaiTier? get _tier => _sku?.tiers.where((tier) => tier.minutes == _minutes && tier.available).firstOrNull;
  // 要不要先让人选：不止一个档位，或这个档位还分时长。
  bool get _choosing => (_info?.skus.length ?? 0) > 1 || (_sku?.tiers.isNotEmpty ?? false);
  // 选好了时的标价（分）；分时长的还没选时长为空。
  int? get _price => switch (_sku) {
    null => null,
    final sku when sku.tiers.isEmpty => sku.cents,
    _ => _tier?.cents,
  };

  void _pick({String? skuId, int? minutes}) => setState(() {
    if (skuId != null && skuId != _skuId) {
      _skuId = skuId;
      _minutes = _sku?.tiers.where((tier) => tier.available).firstOrNull?.minutes;
    }
    if (minutes != null) _minutes = minutes;
    _confirmed = null;
    _placeError = null;
  });

  Future<void> _place() async {
    final sku = _sku!, price = _price!, device = _info!.device;
    setState(() {
      _placing = true;
      _placeError = null;
    });
    try {
      final result = await widget.service.place(
        widget.phone,
        goodsId: device.goodsId,
        item: PangguaiItem(goodsId: device.goodsId, skuId: sku.skuId, amount: _tier?.minutes ?? 1),
        expected: _confirmed ?? price,
      );
      if (!mounted) return;
      switch (result) {
        case PangguaiPriceChanged(:final cents):
          setState(() {
            _confirmed = cents;
            _placeError = '胖乖算出来要付 ¥${lifeYuan(cents)}，确认后再点一次';
          });
        case PangguaiPlaced(:final order, :final orgId):
          await Navigator.of(context).pushReplacement<void, void>(
            CampusPageRoute(
              builder: (_) => PangguaiOrderPage(service: widget.service, phone: widget.phone, orderId: order.orderId, orgId: orgId, title: device.name, autoPay: true, onClose: widget.onClose, clock: widget.clock),
            ),
          );
      }
    } on PangguaiException catch (error) {
      if (mounted) setState(() => _placeError = error.failure == PangguaiFailure.unpaid ? '${error.message}（回首页找到它）' : error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=place errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _placeError = '没下成单，稍后再试');
    } finally {
      if (mounted) setState(() => _placing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: Text(info?.device.categoryName ?? '设备'),
      ),
      body: CampusScrollFade(
        child: SafeArea(
          bottom: false,
          child: info == null
              ? Center(
                  child: switch (_loadError) {
                    final error? => CampusLoadError(message: error, onRetry: () => unawaited(_load())),
                    null => const CampusLoading(label: '正在读取设备', network: true, remote: '胖乖生活'),
                  },
                )
              : ListView(
                  padding: campusScrollPadding(context, const EdgeInsets.all(16)),
                  children: [
                    _deviceCard(context, info),
                    const SizedBox(height: CampusGap.large),
                    ..._body(context, info),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _deviceCard(BuildContext context, PangguaiDeviceInfo info) {
    final palette = CampusPalette.of(context);
    final device = info.device;
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(device.name.isEmpty ? device.categoryName : device.name, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: CampusGap.tight),
          DotSeparatedText([device.categoryName, if (device.orgName.isNotEmpty) device.orgName].join(' · '), style: TextStyle(color: palette.onSurfaceVariant)),
        ],
      ),
    );
  }

  List<Widget> _body(BuildContext context, PangguaiDeviceInfo info) {
    final secondary = TextStyle(color: CampusPalette.of(context).onSurfaceVariant);
    final device = info.device;
    final blocked = device.payment != 'before'
        ? '这台${device.categoryName}是先用后付，暂时只能在胖乖生活 App 里用'
        : device.unusable ?? info.fault ?? (info.skus.isEmpty ? '这台设备没有可选的档位' : null);
    if (blocked != null) return [CampusSurface(padding: const EdgeInsets.all(20), child: Text(blocked, style: secondary))];
    return [
      if (_choosing) ...[_choiceCard(context, info), const SizedBox(height: CampusGap.large)],
      _checkoutCard(context),
    ];
  }

  // 选档：洗衣机这类是程序列表（名字、大约几分钟、价、说明）；吹风机、烘干机是功能位与时长两排选择标签（不能选的时长灰掉）。
  Widget _choiceCard(BuildContext context, PangguaiDeviceInfo info) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    final sku = _sku;
    final timed = info.skus.any((item) => item.tiers.isNotEmpty);
    Widget label(String text) => Padding(padding: const EdgeInsets.only(bottom: CampusGap.small), child: Text(text, style: secondary));
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: timed
            ? [
                if (info.skus.length > 1) ...[
                  label('选位置'),
                  Wrap(
                    spacing: CampusGap.small,
                    runSpacing: CampusGap.small,
                    children: [for (final item in info.skus) CampusGlassChip(label: item.name, selected: item.skuId == _skuId, onSelected: _placing ? null : (_) => _pick(skuId: item.skuId))],
                  ),
                  const SizedBox(height: CampusGap.large),
                ],
                label('选时长'),
                Wrap(
                  spacing: CampusGap.small,
                  runSpacing: CampusGap.small,
                  children: [
                    for (final tier in sku?.tiers ?? const <PangguaiTier>[])
                      CampusGlassChip(
                        label: '${tier.minutes} 分钟 · ¥${lifeYuan(tier.cents)}',
                        selected: tier.minutes == _minutes,
                        onSelected: _placing || !tier.available ? null : (_) => _pick(minutes: tier.minutes),
                      ),
                  ],
                ),
              ]
            : [
                label('选程序'),
                for (final item in info.skus)
                  InkWell(
                    key: ValueKey(item.skuId),
                    onTap: _placing ? null : () => _pick(skuId: item.skuId),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: CampusGap.small),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item.name, style: const TextStyle(fontSize: CampusFontSize.body, fontWeight: FontWeight.w600)),
                                DotSeparatedText([if (item.minutes case final minutes?) '约 $minutes 分钟', '¥${lifeYuan(item.cents)}', if (item.feature.isNotEmpty) item.feature].join(' · '), style: secondary),
                              ],
                            ),
                          ),
                          if (item.skuId == _skuId) CampusIcon(CampusIcons.check, color: palette.primary),
                        ],
                      ),
                    ),
                  ),
              ],
      ),
    );
  }

  Widget _checkoutCard(BuildContext context) {
    final palette = CampusPalette.of(context);
    final sku = _sku!, price = _confirmed ?? _price;
    final error = _placeError;
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      child: CampusToastAnchor(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_choosing) ...[
              DotSeparatedText([sku.name, if (sku.minutes case final minutes?) '约 $minutes 分钟'].join(' · '), style: TextStyle(color: palette.onSurfaceVariant)),
              const SizedBox(height: CampusGap.large),
            ],
            FilledButton(
              style: campusProminent,
              onPressed: price == null || _placing ? null : () => unawaited(_place()),
              child: CampusBusyContent(busy: _placing, label: price == null ? '先选时长' : '下单并付款 ¥${lifeYuan(price)}', busyLabel: '下单中', icon: const CampusIcon(CampusIcons.wallet)),
            ),
            if (error != null) Padding(padding: const EdgeInsets.only(top: CampusGap.medium), child: Text(error, style: TextStyle(color: palette.danger))),
          ],
        ),
      ),
    );
  }
}
