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
import 'package:superxd/toolbox/life/pangguai/pangguai_devices.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_location.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_order_page.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_service.dart';

// 品类的图标：洗衣机（含洗鞋、烘干）、吹风机、饮水机。
IconData pangguaiCategoryIcon(String category) => switch (category) {
  '03' => CampusIcons.dryer,
  '04' => CampusIcons.water,
  _ => CampusIcons.washer,
};

// 先付后用的设备页（给 goodsId；扫码进来的给 code，先问胖乖是哪台）：设备名、品类与门店；不能在这里下单的写原因。
// 洗衣机、洗鞋机选程序（名字、约几分钟、价），吹风机、烘干机选位置与时长（关着的时长不列，v2.3 契约「排除 status=false」）；只有一个档位、不分时长的直接选好（用户说的「没有档位的下一步」）。
// 被占用的程序与位置照样列出、标「暂不可用」（11-28 用户：被占用的属于暂时不可用，要一眼看得出；藏起来时只剩一个位置会直接选上、连位置那行都不显示，看不出付的是哪边）。
// 选好就试算，按钮上写服务端算的实付；点「下单并付款」时整串重发并核对实付，变了写明新价请人再点一次；下好单换成订单页并开始付。
class PangguaiDevicePage extends StatefulWidget {
  const PangguaiDevicePage({super.key, required this.service, required this.phone, this.goodsId, this.code, this.onClose}) : assert(goodsId != null || code != null);
  final PangguaiService service;
  final String phone;
  final String? goodsId;
  final PangguaiCode? code;
  final VoidCallback? onClose;
  @override
  State<PangguaiDevicePage> createState() => _PangguaiDevicePageState();
}

class _PangguaiDevicePageState extends State<PangguaiDevicePage> {
  PangguaiDevice? _device;
  List<PangguaiSku> _skus = const [];
  String? _error;
  String? _skuId;
  int? _minutes;
  // 当前选择的试算实付；为空是还没选好或在算。
  int? _price;
  var _quoting = false;
  // 试算的代次：选择改了，旧的试算结果不再写界面。
  var _quoteGeneration = 0;
  var _placing = false;
  String? _placeError;
  PangguaiLocationProblem? _location;
  var _unsure = false;
  // 下好单换成了订单页：首页的刷新交给订单页关掉时做，这一页不再通知。
  var _replaced = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    if (!_replaced) widget.onClose?.call();
    super.dispose();
  }

  PangguaiSku? get _sku => _skus.where((sku) => sku.id == _skuId).firstOrNull;

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final code = widget.code;
      final goodsId = widget.goodsId ?? await widget.service.run<String>(widget.phone, (token) => widget.service.client.scan(token, code!));
      final result = await widget.service.inspect(widget.phone, goodsId);
      if (!mounted) return;
      setState(() {
        _device = result.device;
        _skus = result.skus;
        // 能选的只有一个档位时直接选上（被占用的照样列出来、标暂不可用，不算在内）。
        final open = result.skus.where((sku) => sku.available).toList();
        _skuId = open.length == 1 ? open.single.id : null;
        _minutes = null;
      });
      _autoTier();
      unawaited(_quote());
    } on PangguaiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=device errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '没读到设备，稍后再试');
    }
  }

  // 只有一个能选的时长时直接选上。
  void _autoTier() {
    final sku = _sku, device = _device;
    if (sku == null || device == null || !device.timed) return;
    final enabled = sku.tiers.where((tier) => tier.enabled).toList();
    if (enabled.length == 1) _minutes = enabled.single.minutes;
  }

  bool get _ready {
    final device = _device, sku = _sku;
    return device != null && device.unusable == null && sku != null && (!device.timed || _minutes != null);
  }

  Future<void> _quote() async {
    final generation = ++_quoteGeneration;
    setState(() {
      _price = null;
      _placeError = null;
      _location = null;
      _unsure = false;
    });
    if (!_ready) return;
    setState(() => _quoting = true);
    try {
      final price = await widget.service.quote(widget.phone, _device!, _sku!, _minutes);
      if (mounted && generation == _quoteGeneration) setState(() => _price = price);
    } on PangguaiException catch (error) {
      if (mounted && generation == _quoteGeneration) setState(() => _placeError = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=quote errorType=${error.runtimeType}\n$stack');
      if (mounted && generation == _quoteGeneration) setState(() => _placeError = '没算出价格，稍后再试');
    } finally {
      if (mounted && generation == _quoteGeneration) setState(() => _quoting = false);
    }
  }

  void _choose({String? skuId, int? minutes}) {
    setState(() {
      if (skuId != null && skuId != _skuId) {
        _skuId = skuId;
        _minutes = null;
        _autoTier();
      }
      if (minutes != null) _minutes = minutes;
    });
    unawaited(_quote());
  }

  Future<void> _place() async {
    final price = _price, sku = _sku, device = _device;
    if (price == null || sku == null || device == null) return;
    setState(() {
      _placing = true;
      _placeError = null;
      _location = null;
      _unsure = false;
    });
    try {
      final orderId = await widget.service.place(widget.phone, goodsId: device.goodsId, skuId: sku.id, minutes: _minutes, expected: price);
      if (!mounted) return;
      // 换成订单页（返回回到来的那一页），打开就开始付。
      _replaced = true;
      unawaited(Navigator.of(context).pushReplacement(CampusPageRoute(builder: (_) => PangguaiOrderPage(service: widget.service, phone: widget.phone, orderId: orderId, autoPay: true, onClose: widget.onClose))));
    } on PangguaiPriceChanged catch (changed) {
      if (mounted) {
        setState(() {
          _price = changed.price;
          _placeError = '价格变成 ¥${lifeYuan(changed.price)} 了，确认后再点一次';
        });
      }
    } on PangguaiLocationException catch (error) {
      if (mounted) {
        setState(() {
          _location = error.problem;
          _placeError = '下单要用手机位置：${error.message}';
        });
      }
    } on PangguaiException catch (error) {
      if (mounted) {
        setState(() {
          _placeError = error.message;
          _unsure = error.failure == PangguaiFailure.unsure;
        });
      }
    } catch (error, stack) {
      campusLog('[Pangguai] action=place errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _placeError = '没下成单，稍后再试');
    } finally {
      if (mounted) setState(() => _placing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = _device;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: Text(device?.kind ?? '设备'),
      ),
      body: CampusScrollFade(
        child: SafeArea(
          bottom: false,
          child: device == null
              ? (_error == null ? const Center(child: CampusLoading(label: '正在读取设备', network: true, remote: '胖乖生活')) : CampusLoadError(message: _error!, onRetry: () => unawaited(_load())))
              : ListView(
                  padding: campusScrollPadding(context, const EdgeInsets.all(16)),
                  children: [
                    _header(context, device),
                    if (device.unusable == null) ...[
                      const SizedBox(height: CampusGap.large),
                      if (_skus.isEmpty)
                        CampusSurface(padding: const EdgeInsets.all(20), child: Text('这台设备现在没有能选的档位', style: TextStyle(color: CampusPalette.of(context).onSurfaceVariant)))
                      else if (device.timed)
                        _timedChoices(context)
                      else
                        _programs(context),
                      const SizedBox(height: CampusGap.section),
                      _action(context),
                    ],
                  ],
                ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, PangguaiDevice device) {
    final palette = CampusPalette.of(context);
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CampusIcon(pangguaiCategoryIcon(device.category), size: 28, color: palette.primary),
              const SizedBox(width: CampusGap.large),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(device.name, style: Theme.of(context).textTheme.titleMedium),
                    DotSeparatedText([device.kind, if (device.orgName.isNotEmpty) device.orgName].join(' · '), style: TextStyle(color: palette.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
          if (device.unusable case final reason?) ...[const SizedBox(height: CampusGap.large), Text(reason, style: TextStyle(color: palette.danger))],
        ],
      ),
    );
  }

  // 洗衣机、洗鞋机：程序列表，选中的着色；暂不可用的点不了、整行次要色并写明。
  Widget _programs(BuildContext context) {
    final palette = CampusPalette.of(context);
    return CampusSurface(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (final sku in _skus)
            Material(
              key: ValueKey(sku.id),
              color: sku.id == _skuId ? palette.selectedFill : Colors.transparent,
              child: InkWell(
                onTap: _placing || !sku.available ? null : () => _choose(skuId: sku.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: CampusGap.medium),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(sku.name, style: TextStyle(fontSize: CampusFontSize.body, color: sku.available ? null : palette.onSurfaceVariant)),
                            DotSeparatedText([if (!sku.available) '暂不可用', if (sku.minutes case final minutes? when minutes > 0) '约 $minutes 分钟', '¥${lifeYuan(sku.price)}', if (sku.feature.isNotEmpty) sku.feature].join(' · '), style: TextStyle(color: palette.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      if (sku.id == _skuId) CampusIcon(CampusIcons.check, color: palette.primary),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // 吹风机、烘干机：先选位置（只有一个位置时不显示，被占用的也算一个），再选时长。
  Widget _timedChoices(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    final sku = _sku;
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_skus.length > 1) ...[
            Text('位置', style: secondary),
            const SizedBox(height: CampusGap.small),
            Wrap(
              spacing: CampusGap.small,
              runSpacing: CampusGap.small,
              children: [
                for (final each in _skus)
                  CampusGlassChip(
                    key: ValueKey(each.id),
                    label: each.available ? each.name : '${each.name} 暂不可用',
                    selected: each.id == _skuId,
                    unavailable: !each.available,
                    onSelected: _placing ? null : (_) => _choose(skuId: each.id),
                  ),
              ],
            ),
            const SizedBox(height: CampusGap.large),
          ],
          Text('时长', style: secondary),
          const SizedBox(height: CampusGap.small),
          if (sku == null)
            Text('先选位置', style: secondary)
          else if (!sku.tiers.any((tier) => tier.enabled))
            Text('这个位置没有能选的时长', style: secondary)
          else
            Wrap(
              spacing: CampusGap.small,
              runSpacing: CampusGap.small,
              children: [
                for (final tier in sku.tiers.where((tier) => tier.enabled))
                  CampusGlassChip(
                    key: ValueKey('${sku.id}-${tier.minutes}'),
                    label: '${tier.minutes} 分钟 ¥${lifeYuan(tier.price)}',
                    selected: tier.minutes == _minutes,
                    onSelected: _placing ? null : (_) => _choose(minutes: tier.minutes),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  // 下单按钮与它下面原地的结果：价变了、要位置、结果不确定。
  Widget _action(BuildContext context) {
    final palette = CampusPalette.of(context);
    final price = _price, location = _location, error = _placeError;
    final label = price == null ? (_quoting ? '正在算价' : '选好再下单') : '下单并付款 ¥${lifeYuan(price)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          style: campusProminent,
          onPressed: price != null && !_placing && !_quoting ? () => unawaited(_place()) : null,
          child: CampusBusyContent(busy: _placing || _quoting, label: label, busyLabel: _placing ? '下单中' : '正在算价', icon: const CampusIcon(CampusIcons.wallet)),
        ),
        if (error != null) ...[const SizedBox(height: CampusGap.medium), Text(error, style: TextStyle(color: palette.danger))],
        if (location == PangguaiLocationProblem.denied || location == PangguaiLocationProblem.disabled) ...[
          const SizedBox(height: CampusGap.small),
          Align(child: OutlinedButton.icon(onPressed: () => unawaited(widget.service.locator.openSettings(location!)), icon: const CampusIcon(CampusIcons.settings), label: const Text('去设置'))),
        ],
        if (_unsure) ...[
          const SizedBox(height: CampusGap.small),
          Align(
            child: OutlinedButton.icon(
              onPressed: () => unawaited(Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => PangguaiOrdersPage(service: widget.service, phone: widget.phone)))),
              icon: const CampusIcon(CampusIcons.orders),
              label: const Text('看订单'),
            ),
          ),
        ],
      ],
    );
  }
}
