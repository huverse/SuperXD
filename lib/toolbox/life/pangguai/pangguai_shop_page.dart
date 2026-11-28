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

// 距离写成人看的：一公里以内写米，再远写公里。
String pangguaiDistance(int meters) => meters < 0 ? '' : meters < 1000 ? '$meters 米' : '${(meters / 1000).toStringAsFixed(1)} 公里';

// 附近门店：打开时取一次位置（没权限弹系统授权，定位关着或没权限原地写明并给「去设置」），按距离列门店，一页 10 家、「加载更多」；
// 每家写距离、空闲几台与地址，点进门店。
class PangguaiNearbyPage extends StatefulWidget {
  const PangguaiNearbyPage({super.key, required this.service, required this.phone});
  final PangguaiService service;
  final String phone;
  @override
  State<PangguaiNearbyPage> createState() => _PangguaiNearbyPageState();
}

class _PangguaiNearbyPageState extends State<PangguaiNearbyPage> {
  PangguaiPosition? _position;
  PangguaiLocationProblem? _problem;
  final _shops = <PangguaiShop>[];
  var _page = 0;
  var _more = true;
  var _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    setState(() {
      _problem = null;
      _error = null;
      _loading = true;
      _shops.clear();
      _page = 0;
      _more = true;
    });
    try {
      _position = await widget.service.locator.current(ask: true);
    } on PangguaiLocationException catch (error) {
      if (mounted) {
        setState(() {
          _problem = error.problem;
          _loading = false;
        });
      }
      return;
    } catch (error, stack) {
      campusLog('[Pangguai] action=locate errorType=${error.runtimeType}\n$stack');
      if (mounted) {
        setState(() {
          _problem = PangguaiLocationProblem.unavailable;
          _loading = false;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _loading = false);
    await _next();
  }

  Future<void> _next() async {
    final position = _position;
    if (position == null || _loading || !_more) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = _page + 1;
      final shops = await widget.service.run(widget.phone, (token) => widget.service.client.shops(token, position, page: page));
      if (!mounted) return;
      setState(() {
        _page = page;
        _shops.addAll(shops.where((shop) => !_shops.any((known) => known.id == shop.id)));
        _more = shops.length >= PangguaiClient.shopPage;
      });
    } on PangguaiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=shops errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '没读到附近门店，稍后再试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    final problem = _problem;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('附近门店'),
      ),
      body: CampusScrollFade(
        child: SafeArea(
          bottom: false,
          child: problem != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(PangguaiLocationException(problem).message, textAlign: TextAlign.center, style: secondary),
                        const SizedBox(height: CampusGap.medium),
                        if (problem == PangguaiLocationProblem.unavailable)
                          OutlinedButton.icon(onPressed: () => unawaited(_start()), icon: const CampusIcon(CampusIcons.sync), label: const Text('重试'))
                        else
                          Wrap(
                            spacing: CampusGap.small,
                            runSpacing: CampusGap.small,
                            alignment: WrapAlignment.center,
                            children: [
                              OutlinedButton.icon(onPressed: () => unawaited(widget.service.locator.openSettings(problem)), icon: const CampusIcon(CampusIcons.settings), label: const Text('去设置')),
                              OutlinedButton.icon(onPressed: () => unawaited(_start()), icon: const CampusIcon(CampusIcons.sync), label: const Text('重试')),
                            ],
                          ),
                      ],
                    ),
                  ),
                )
              : _shops.isEmpty && _error != null
              ? CampusLoadError(message: _error!, onRetry: () => unawaited(_next()))
              : _shops.isEmpty && (_loading || _position == null)
              ? Center(child: CampusLoading(label: _position == null ? '正在取位置' : '正在找附近门店', network: _position != null, remote: '胖乖生活'))
              : ListView(
                  padding: campusScrollPadding(context, const EdgeInsets.all(16)),
                  children: [
                    if (_shops.isEmpty) Center(child: Text('附近没有胖乖的门店', style: secondary)),
                    if (_shops.isNotEmpty)
                      CampusSurface(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            for (final shop in _shops)
                              InkWell(
                                key: ValueKey(shop.id),
                                onTap: () => unawaited(Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => PangguaiShopPage(service: widget.service, phone: widget.phone, shop: shop, position: _position!)))),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: CampusGap.medium),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(shop.name, style: const TextStyle(fontSize: CampusFontSize.body)),
                                            DotSeparatedText([if (pangguaiDistance(shop.distance) case final distance when distance.isNotEmpty) distance, '空闲 ${shop.free}/${shop.total} 台'].join(' · '), style: secondary),
                                            if (shop.address.isNotEmpty) Text(shop.address, style: secondary),
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
                    if (_error != null && _shops.isNotEmpty) ...[const SizedBox(height: CampusGap.medium), Text(_error!, style: TextStyle(color: palette.danger))],
                    if (_more && _shops.isNotEmpty) ...[
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

// 一家门店：有几类设备时上面是机型的选择标签，下面是这一类的设备（一页 20 台、「加载更多」），每台写名字与状态（空闲、使用中还剩多久），点进设备页。
class PangguaiShopPage extends StatefulWidget {
  const PangguaiShopPage({super.key, required this.service, required this.phone, required this.shop, required this.position});
  final PangguaiService service;
  final String phone;
  final PangguaiShop shop;
  final PangguaiPosition position;
  @override
  State<PangguaiShopPage> createState() => _PangguaiShopPageState();
}

class _PangguaiShopPageState extends State<PangguaiShopPage> {
  List<PangguaiMachineType>? _types;
  String? _type;
  final _machines = <PangguaiMachine>[];
  var _page = 0;
  var _more = true;
  var _loading = false;
  String? _error;
  // 切机型后，旧机型晚回来的设备不再写界面。
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadTypes());
  }

  Future<void> _loadTypes() async {
    setState(() => _error = null);
    try {
      final types = await widget.service.run(widget.phone, (token) => widget.service.client.machineTypes(token, widget.shop.id, widget.position));
      if (!mounted) return;
      setState(() => _types = types);
      if (types.isNotEmpty) await _select(types.first.id);
    } on PangguaiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=machine_types errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '没读到这家门店，稍后再试');
    }
  }

  Future<void> _select(String type) async {
    setState(() {
      _generation++;
      _type = type;
      _machines.clear();
      _page = 0;
      _more = true;
      _loading = false;
    });
    await _next();
  }

  Future<void> _next() async {
    final type = _type;
    if (type == null || _loading || !_more) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = _page + 1;
      final machines = await widget.service.run(widget.phone, (token) => widget.service.client.machines(token, widget.shop.id, type, page: page));
      if (!mounted || generation != _generation) return;
      setState(() {
        _page = page;
        _machines.addAll(machines.where((machine) => !_machines.any((known) => known.goodsId == machine.goodsId)));
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
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    final types = _types;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: Text(widget.shop.name),
      ),
      body: CampusScrollFade(
        child: SafeArea(
          bottom: false,
          child: types == null
              ? (_error == null ? const Center(child: CampusLoading(label: '正在读取门店', network: true, remote: '胖乖生活')) : CampusLoadError(message: _error!, onRetry: () => unawaited(_loadTypes())))
              : ListView(
                  padding: campusScrollPadding(context, const EdgeInsets.all(16)),
                  children: [
                    if (types.isEmpty) Center(child: Text('这家门店没有设备', style: secondary)),
                    if (types.length > 1) ...[
                      Wrap(
                        spacing: CampusGap.small,
                        runSpacing: CampusGap.small,
                        children: [for (final type in types) CampusGlassChip(key: ValueKey(type.id), label: type.name, selected: type.id == _type, onSelected: (_) => unawaited(_select(type.id)))],
                      ),
                      const SizedBox(height: CampusGap.large),
                    ],
                    if (_machines.isEmpty && _loading) const CampusSurface(child: CampusLoading(label: '正在读取设备', inline: true, network: true, remote: '胖乖生活')),
                    if (_machines.isEmpty && !_loading && _error == null && types.isNotEmpty) Center(child: Text('这一类没有设备', style: secondary)),
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
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: CampusGap.medium),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(machine.name, style: const TextStyle(fontSize: CampusFontSize.body)),
                                            DotSeparatedText(machine.statusLabel, style: secondary),
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
                    if (_error != null) ...[
                      const SizedBox(height: CampusGap.medium),
                      Text(_error!, style: TextStyle(color: palette.danger)),
                      Align(child: OutlinedButton.icon(onPressed: () => unawaited(_next()), icon: const CampusIcon(CampusIcons.sync), label: const Text('重试'))),
                    ],
                    if (_more && _machines.isNotEmpty && _error == null) ...[
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
