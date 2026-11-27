import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_client.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_device_page.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_location.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_service.dart';

String _distance(int meters) => meters < 1000 ? '$meters 米' : '${(meters / 1000).toStringAsFixed(1)} 公里';

// 附近的门店：打开时取一次手机位置（没给过权限弹系统授权，仅使用期间），按位置问胖乖，一页 20 家；定位没开或没权限时原地写明并给「去设置」。
class PangguaiNearbyPage extends StatefulWidget {
  const PangguaiNearbyPage({super.key, required this.service, required this.phone});
  final PangguaiService service;
  final String phone;
  @override
  State<PangguaiNearbyPage> createState() => _PangguaiNearbyPageState();
}

class _PangguaiNearbyPageState extends State<PangguaiNearbyPage> {
  List<PangguaiShop>? _shops;
  PangguaiPosition? _position;
  PangguaiLocateFailure? _locate;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _shops = null;
      _locate = null;
      _error = null;
    });
    try {
      final position = await widget.service.locator.locate(ask: true);
      final shops = await widget.service.run(widget.phone, (token) => widget.service.client.nearbyShops(token, position));
      if (mounted) {
        setState(() {
          _position = position;
          _shops = shops;
        });
      }
    } on PangguaiLocateException catch (error) {
      if (mounted) setState(() => _locate = error.failure);
    } on PangguaiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=nearby errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '没找到附近的门店，稍后再试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final shops = _shops;
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('附近门店'),
      ),
      body: CampusScrollFade(
        child: SafeArea(
          bottom: false,
          child: switch ((shops, _locate, _error)) {
            (_, final failure?, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(PangguaiLocateException(failure).message, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: CampusGap.large),
                    if (failure != PangguaiLocateFailure.unavailable)
                      FilledButton.icon(onPressed: () => unawaited(widget.service.locator.openSettings(failure)), icon: const CampusIcon(CampusIcons.settings), label: const Text('去设置')),
                    const SizedBox(height: CampusGap.small),
                    OutlinedButton.icon(onPressed: () => unawaited(_load()), icon: const CampusIcon(CampusIcons.sync), label: const Text('重试')),
                  ],
                ),
              ),
            ),
            (_, _, final error?) => Center(child: CampusLoadError(message: error, onRetry: () => unawaited(_load()))),
            (null, _, _) => const Center(child: CampusLoading(label: '正在找附近的门店', network: true, remote: '胖乖生活')),
            (final shops?, _, _) when shops.isEmpty => Center(child: Text('附近没有胖乖生活的门店', style: secondary)),
            (final shops?, _, _) => ListView(
              padding: campusScrollPadding(context, const EdgeInsets.all(16)),
              children: [
                CampusSurface(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final shop in shops)
                        InkWell(
                          key: ValueKey(shop.shopId),
                          onTap: () => unawaited(Navigator.of(context).push<void>(
                            CampusPageRoute(builder: (_) => PangguaiShopPage(service: widget.service, phone: widget.phone, shopId: shop.shopId, name: shop.name, position: _position)),
                          )),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: CampusGap.medium),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(shop.name, style: const TextStyle(fontSize: CampusFontSize.body, fontWeight: FontWeight.w600)),
                                      DotSeparatedText([if (shop.meters case final meters?) _distance(meters), if (shop.machines case final count?) '$count 台', if (shop.address.isNotEmpty) shop.address].join(' · '), style: secondary),
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
              ],
            ),
          },
        ),
      ),
    );
  }
}

// 一家门店：上面按机型（洗衣、吹风…）选，下面是这个机型的设备，一页 20 台、「加载更多」接着读；点设备进设备页。
class PangguaiShopPage extends StatefulWidget {
  const PangguaiShopPage({super.key, required this.service, required this.phone, required this.shopId, required this.name, this.position});
  final PangguaiService service;
  final String phone;
  final String shopId;
  final String name;
  final PangguaiPosition? position;
  @override
  State<PangguaiShopPage> createState() => _PangguaiShopPageState();
}

class _PangguaiShopPageState extends State<PangguaiShopPage> {
  List<({String id, String name})>? _types;
  String? _type;
  final _machines = <({String goodsId, String name})>[];
  var _page = 0;
  var _more = false;
  var _loading = false;
  String? _error;
  // 换机型后，旧机型晚回来的结果不写界面。
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadTypes());
  }

  Future<void> _loadTypes() async {
    setState(() => _error = null);
    try {
      final types = await widget.service.run(widget.phone, (token) => widget.service.client.machineTypes(token, widget.shopId, widget.position));
      if (!mounted) return;
      setState(() => _types = types);
      if (types.isNotEmpty) await _choose(types.first.id);
    } on PangguaiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=machine_types errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '没读到门店的设备，稍后再试');
    }
  }

  Future<void> _choose(String type) async {
    setState(() {
      _type = type;
      _machines.clear();
      _page = 0;
      _more = false;
    });
    await _next();
  }

  Future<void> _next() async {
    final type = _type!, generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = _page + 1;
      final machines = await widget.service.run(widget.phone, (token) => widget.service.client.machines(token, widget.shopId, type, page: page));
      if (!mounted || generation != _generation) return;
      setState(() {
        _page = page;
        _machines.addAll(machines.where((machine) => _machines.every((known) => known.goodsId != machine.goodsId)));
        _more = machines.length >= PangguaiClient.machinePage;
      });
    } on PangguaiException catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=machines errorType=${error.runtimeType}\n$stack');
      if (mounted && generation == _generation) setState(() => _error = '没读到设备，稍后再试');
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final types = _types;
    final secondary = TextStyle(color: CampusPalette.of(context).onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: Text(widget.name.isEmpty ? '门店' : widget.name),
      ),
      body: CampusScrollFade(
        child: SafeArea(
          bottom: false,
          child: types == null
              ? Center(
                  child: switch (_error) {
                    final error? => CampusLoadError(message: error, onRetry: () => unawaited(_loadTypes())),
                    null => const CampusLoading(label: '正在读取门店', network: true, remote: '胖乖生活'),
                  },
                )
              : ListView(
                  padding: campusScrollPadding(context, const EdgeInsets.all(16)),
                  children: [
                    if (types.isEmpty) Text('这家门店没有设备', style: secondary),
                    if (types.isNotEmpty)
                      Wrap(
                        spacing: CampusGap.small,
                        runSpacing: CampusGap.small,
                        children: [for (final type in types) CampusGlassChip(label: type.name.isEmpty ? (pangguaiCategories[type.id] ?? type.id) : type.name, selected: type.id == _type, onSelected: (_) => unawaited(_choose(type.id)))],
                      ),
                    const SizedBox(height: CampusGap.large),
                    if (_machines.isNotEmpty)
                      CampusSurface(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            for (final machine in _machines)
                              InkWell(
                                key: ValueKey(machine.goodsId),
                                onTap: () => unawaited(Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => PangguaiDevicePage(service: widget.service, phone: widget.phone, goodsId: machine.goodsId)))),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: CampusGap.large),
                                  child: Row(
                                    children: [
                                      Expanded(child: Text(machine.name.isEmpty ? machine.goodsId : machine.name, style: const TextStyle(fontSize: CampusFontSize.body))),
                                      const CampusIcon(CampusIcons.next),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (_error case final error?) ...[
                      const SizedBox(height: CampusGap.medium),
                      CampusLoadError(message: error, onRetry: () => unawaited(_next())),
                    ] else if (_loading)
                      const Padding(padding: EdgeInsets.all(CampusGap.large), child: CampusLoading(label: '正在读取设备', inline: true, network: true, remote: '胖乖生活'))
                    else if (_more)
                      Padding(
                        padding: const EdgeInsets.only(top: CampusGap.medium),
                        child: OutlinedButton.icon(onPressed: () => unawaited(_next()), icon: const CampusIcon(CampusIcons.expand), label: const Text('加载更多')),
                      )
                    else if (_machines.isEmpty && _type != null)
                      Text('这个机型下没有设备', style: secondary),
                  ],
                ),
        ),
      ),
    );
  }
}
