import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_bath.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_bath_page.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_client.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_devices.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_service.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 一行可点的条目：标题、说明与右侧箭头（选设备与常用设备共用）。
Widget _row(BuildContext context, {required String title, String? detail, required VoidCallback onTap, Widget? trailing}) {
  final palette = CampusPalette.of(context);
  return Padding(
    padding: const EdgeInsets.only(bottom: CampusGap.medium),
    child: CampusSurface(
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 14),
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: CampusFontSize.body)),
                if (detail != null) DotSeparatedText(detail, style: TextStyle(color: palette.onSurfaceVariant)),
              ],
            ),
          ),
          trailing ?? const Padding(padding: EdgeInsets.only(right: 12), child: CampusIcon(CampusIcons.next)),
        ],
      ),
    ),
  );
}

String zhuliDeviceState(ZhuliDevice device) => [device.status != 0 ? '维护中' : device.idle ? '空闲' : '使用中', device.bluetooth ? '蓝牙' : '云端'].join(' · ');

// 按楼栋、楼层、房间一级级选到设备（同原 App 的选择设备页），选中交回设备号；返回键回上一级。只列有设备的房间（台数按 total_room_device_count）。
class ZhuliPickPage extends StatefulWidget {
  const ZhuliPickPage({super.key, required this.service, required this.phone});
  final ZhuliService service;
  final String phone;
  @override
  State<ZhuliPickPage> createState() => _ZhuliPickPageState();
}

class _ZhuliPickPageState extends State<ZhuliPickPage> {
  final _path = <ZhuliPlace>[];
  late Future<List<Object>> _items = _read();
  // 房间里的设备分页（从 1 起）：已读到的与还有没有下一页。
  final _devices = <ZhuliDevice>[];
  var _devicePage = 0;
  var _moreDevices = false;
  var _loadingMore = false;

  ZhuliClient get _client => widget.service.client;

  Future<T> _run<T>(Future<T> Function(ZhuliSession session) action) => widget.service.run(widget.phone, action);

  Future<List<Object>> _read() async => switch (_path.length) {
    0 => await _run(_client.buildings),
    1 => await _run((session) => _client.floors(session, _path[0].id)),
    2 => [for (final room in await _run((session) => _client.rooms(session, _path[1].id))) if (room.devices != 0) room],
    _ => await _firstDevices(),
  };

  Future<List<Object>> _firstDevices() async {
    _devices.clear();
    _devicePage = 0;
    await _moreRoomDevices();
    return _devices;
  }

  Future<void> _moreRoomDevices() async {
    final page = await _run((session) => _client.roomDevices(session, buildingId: _path[0].id, floorId: _path[1].id, roomId: _path[2].id, page: _devicePage + 1));
    _devicePage++;
    _devices.addAll(page.where((device) => !_devices.any((known) => known.id == device.id)));
    _moreDevices = page.length >= ZhuliClient.roomDevicePage;
  }

  void _go(ZhuliPlace? place) => setState(() {
    if (place == null) {
      _path.removeLast();
    } else {
      _path.add(place);
    }
    _items = _read();
  });

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      await _moreRoomDevices();
    } on ZhuliException catch (error) {
      if (mounted) showCampusToast(context, error.message);
    } catch (error, stack) {
      campusLog('[Zhuli] action=room_devices errorType=${error.runtimeType}\n$stack');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _path.isEmpty,
    onPopInvokedWithResult: (popped, _) {
      if (!popped) _go(null);
    },
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => _path.isEmpty ? Navigator.pop(context) : _go(null), icon: const CampusIcon(CampusIcons.back)),
        title: Text(_path.isEmpty ? '选择设备' : [_path[0].name, if (_path.length > 1) '${_path[1].name}层', if (_path.length > 2) _path[2].name].join(' ')),
      ),
      body: CampusScrollFade(
        child: SafeArea(
          child: FutureBuilder<List<Object>>(
            future: _items,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                final error = snapshot.error;
                return CampusLoadError(message: error is ZhuliException ? error.message : '没读到，稍后再试', onRetry: () => setState(() {
                  _items = _read();
                }));
              }
              if (snapshot.connectionState != ConnectionState.done) return const Center(child: CampusLoading(label: '正在读取', network: true, remote: '住理生活'));
              final items = snapshot.data!;
              if (items.isEmpty) return Center(child: Text('这里没有设备', style: TextStyle(color: CampusPalette.of(context).onSurfaceVariant)));
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // 同房间能走云端的排前面（人工决策见 zhuli_bath.dart 的 zhuliCloudFirst）。
                  for (final item in _path.length == 3 ? zhuliCloudFirst(_devices) : items)
                    switch (item) {
                      ZhuliPlace(:final name, :final devices) => _row(
                        context,
                        title: _path.length == 1 ? '$name层' : name,
                        detail: devices == null ? null : '$devices 台',
                        onTap: () => _go(item),
                      ),
                      final ZhuliDevice device => _row(context, title: '设备 ${device.name.isEmpty ? device.id : device.name}', detail: zhuliDeviceState(device), onTap: () => Navigator.pop(context, device.id)),
                      _ => const SizedBox.shrink(),
                    },
                  if (_path.length == 3 && _moreDevices)
                    Center(
                      child: TextButton.icon(
                        onPressed: _loadingMore ? null : () => unawaited(_loadMore()),
                        icon: const CampusIcon(CampusIcons.expand),
                        label: CampusBusyContent(busy: _loadingMore, label: '加载更多', busyLabel: '读取中'),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

// 常用设备（自己收藏的，最多 zhuliFavoriteLimit 台，按自己排的顺序）：点开去洗浴；⋯ 里置顶或移出；可扫码、输设备号或按楼栋选来添加。
class ZhuliFavoritesPage extends StatefulWidget {
  const ZhuliFavoritesPage({super.key, required this.runtime, required this.service, required this.phone});
  final ToolboxRuntime runtime;
  final ZhuliService service;
  final String phone;
  @override
  State<ZhuliFavoritesPage> createState() => _ZhuliFavoritesPageState();
}

class _ZhuliFavoritesPageState extends State<ZhuliFavoritesPage> {
  List<ZhuliDeviceEntry>? _favorites;
  var _adding = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final lists = await widget.service.devices.load(widget.phone);
    if (mounted) setState(() => _favorites = lists.favorites);
  }

  // 添加：先向住理查这台设备（拿名字与位置），再收藏。
  Future<void> _add(Future<int?> Function() pick) async {
    if ((_favorites?.length ?? 0) >= zhuliFavoriteLimit) return showCampusToast(context, '常用设备最多 $zhuliFavoriteLimit 台，先移掉几台');
    try {
      final deviceId = await pick();
      if (deviceId == null || !mounted) return;
      setState(() => _adding = true);
      final device = await widget.service.run(widget.phone, (session) => widget.service.client.device(session, deviceId));
      final lists = await widget.service.devices.favor(widget.phone, ZhuliDeviceEntry.of(device));
      if (!mounted) return;
      setState(() => _favorites = lists.favorites);
      showCampusToast(context, '已收藏 ${device.place.isEmpty ? '设备 ${device.id}' : device.place}');
    } on ZhuliException catch (error) {
      if (mounted) showCampusToast(context, error.message);
    } catch (error, stack) {
      campusLog('[Zhuli] action=favor errorType=${error.runtimeType}\n$stack');
      if (mounted) showCampusToast(context, '没加上，稍后再试');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _menu(BuildContext anchor, ZhuliDeviceEntry entry, bool first) async {
    final picked = await showCampusMenu<String>(anchor, items: [
      if (!first) const CampusMenuItem(value: 'pin', label: '置顶', icon: CampusIcons.pin),
      const CampusMenuItem(value: 'remove', label: '移出常用设备', icon: CampusIcons.delete, destructive: true),
    ]);
    if (picked == null) return;
    final lists = picked == 'pin' ? await widget.service.devices.pin(widget.phone, entry.id) : await widget.service.devices.unfavor(widget.phone, entry.id);
    if (mounted) setState(() => _favorites = lists.favorites);
  }

  @override
  Widget build(BuildContext context) {
    final favorites = _favorites;
    final scan = widget.runtime.scanQrCode != null;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('常用设备'),
      ),
      body: CampusScrollFade(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Wrap(
                spacing: CampusGap.medium,
                runSpacing: CampusGap.medium,
                children: [
                  if (scan)
                    FilledButton.icon(
                      onPressed: _adding ? null : () => unawaited(_add(() => zhuliScanDevice(context, runtime: widget.runtime, service: widget.service, phone: widget.phone))),
                      icon: const CampusIcon(CampusIcons.scan),
                      label: const Text('扫码添加'),
                    ),
                  FilledButton.icon(onPressed: _adding ? null : () => unawaited(_add(() => zhuliAskDeviceId(context))), icon: const CampusIcon(CampusIcons.deviceNumber), label: const Text('输设备号')),
                  FilledButton.icon(
                    onPressed: _adding ? null : () => unawaited(_add(() => Navigator.of(context).push<int>(CampusPageRoute(builder: (_) => ZhuliPickPage(service: widget.service, phone: widget.phone))))),
                    icon: const CampusIcon(CampusIcons.building),
                    label: const Text('按楼栋选'),
                  ),
                ],
              ),
              const SizedBox(height: CampusGap.large),
              if (favorites == null)
                const SizedBox.shrink()
              else if (favorites.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: CampusGap.section),
                  child: Center(child: Text('还没有常用设备', style: TextStyle(color: CampusPalette.of(context).onSurfaceVariant))),
                )
              else
                for (final (index, entry) in favorites.indexed)
                  KeyedSubtree(
                    key: ValueKey(entry.id),
                    child: _row(
                      context,
                      title: entry.place.isEmpty ? '设备 ${entry.id}' : entry.place,
                      detail: '设备 ${entry.name.isEmpty ? entry.id : entry.name}',
                      onTap: () async {
                        await Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => ZhuliBathPage(service: widget.service, phone: widget.phone, deviceId: entry.id)));
                        if (mounted) unawaited(_reload());
                      },
                      trailing: Builder(builder: (anchor) => IconButton(tooltip: '更多', onPressed: () => unawaited(_menu(anchor, entry, index == 0)), icon: const CampusIcon(CampusIcons.manage))),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
