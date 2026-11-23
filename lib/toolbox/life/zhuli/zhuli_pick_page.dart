import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
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

// 房间里一台设备的状态行：状态与有哪几路。
String zhuliDeviceState(ZhuliDevice device) => [device.status != 0 ? '维护中' : device.idle ? '空闲' : '使用中', device.modeLabel].join(' · ');

// 设备行的标题：设备号，设备名和房间不同才带上名字（这个学校的设备名就是房间号，同房间新旧设备同名）。
String zhuliDeviceTitle(ZhuliDevice device) => [?device.distinctName, '设备号 ${device.id}'].join(' · ');

// 按楼栋、楼层、房间一级级选设备（同原 App 的选择设备页）：每一级是一个推入的页面（同全应用的页面转场与跟手返回，11-23 用户指出原来同页硬切），返回回上一级。
// 选中后：给了 open 就把这几级选择页一起换成 open 的页面（首页进洗浴页），没给就几级一起收掉（常用设备的添加），返回设备号；中途退出为空。
// 中间几级不动画直接拿掉，只有最上面这一页走一次转场（11-23 用户视频：原来几级各自退回、几页叠着闪过去）。
Future<int?> zhuliPickDevice(BuildContext context, {required ZhuliService service, required String phone, Widget Function(int deviceId)? open}) {
  final flow = _PickFlow(open);
  unawaited(Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => ZhuliPickPage._(flow, service: service, phone: phone))).then((_) {
    if (!flow.picked) flow.done.complete(null);
  }));
  return flow.done.future;
}

// 一次选择：各级的页面（选中时拿掉）与结果。
class _PickFlow {
  _PickFlow(this.open);
  final Widget Function(int deviceId)? open;
  final routes = <Route<Object?>>[];
  final done = Completer<int?>();
  var picked = false;
}

class ZhuliPickPage extends StatefulWidget {
  const ZhuliPickPage._(this._flow, {required this.service, required this.phone, this.path = const []});
  final ZhuliService service;
  final String phone;
  final _PickFlow _flow;
  // 已经选到的楼栋、楼层、房间。
  final List<ZhuliPlace> path;
  @override
  State<ZhuliPickPage> createState() => _ZhuliPickPageState();
}

class _ZhuliPickPageState extends State<ZhuliPickPage> {
  late Future<List<Object>> _items = _read();
  Route<Object?>? _route;
  // 房间里的设备分页（从 1 起）：已读到的与还有没有下一页。
  final _devices = <ZhuliDevice>[];
  var _devicePage = 0;
  var _moreDevices = false;
  var _loadingMore = false;

  List<ZhuliPlace> get _path => widget.path;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_route != null) return;
    final route = ModalRoute.of(context);
    if (route != null) widget._flow.routes.add(_route = route);
  }

  @override
  void dispose() {
    widget._flow.routes.remove(_route);
    super.dispose();
  }

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

  void _open(ZhuliPlace place) => unawaited(Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => ZhuliPickPage._(widget._flow, service: widget.service, phone: widget.phone, path: [..._path, place]))));

  // 选中一台：下面几级直接拿掉，这一页换成要去的页面或退回去，都只走一次转场。
  Future<void> _picked(int deviceId) async {
    final flow = widget._flow;
    if (flow.picked) return;
    flow.picked = true;
    final navigator = Navigator.of(context);
    for (final route in [...flow.routes]) {
      if (route != _route && route.isActive) navigator.removeRoute(route);
    }
    final open = flow.open;
    if (open == null) {
      navigator.pop();
      flow.done.complete(deviceId);
      return;
    }
    await navigator.pushReplacement(CampusPageRoute<void>(builder: (_) => open(deviceId)));
    flow.done.complete(deviceId);
  }

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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
      title: Text(_path.isEmpty ? '选择设备' : [_path[0].name, if (_path.length > 1) '${_path[1].name}层', if (_path.length > 2) _path[2].name].join(' ')),
    ),
    body: CampusScrollFade(
      child: SafeArea(
        bottom: false,
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
              padding: campusScrollPadding(context, const EdgeInsets.all(16)),
              children: [
                // 同房间能走云端的排前面（人工决策见 zhuli_bath.dart 的 zhuliCloudFirst）。
                for (final item in _path.length == 3 ? zhuliCloudFirst(_devices) : items)
                  switch (item) {
                    ZhuliPlace(:final name, :final devices) => _row(
                      context,
                      title: _path.length == 1 ? '$name层' : name,
                      detail: devices == null ? null : '$devices 台',
                      onTap: () => _open(item),
                    ),
                    final ZhuliDevice device => _row(context, title: zhuliDeviceTitle(device), detail: zhuliDeviceState(device), onTap: () => unawaited(_picked(device.id))),
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
  );
}

// 常用设备（自己收藏的，最多 zhuliFavoriteLimit 台，按自己排的顺序）：点开去洗浴；⋯ 里置顶或移出；顶栏「+」里扫码、输设备号或按楼栋选来添加。
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
      showCampusToast(context, '已收藏设备号 ${device.id}');
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

  // 添加常用设备的三种办法收进一个菜单（顶栏「+」与没有常用设备时的「添加」都弹它）。
  Future<void> _addMenu(BuildContext anchor) async {
    final picked = await showCampusMenu<String>(anchor, items: [
      if (widget.runtime.scanQrCode != null) const CampusMenuItem(value: 'scan', label: '扫码添加', icon: CampusIcons.scan),
      const CampusMenuItem(value: 'number', label: '输设备号', icon: CampusIcons.deviceNumber),
      const CampusMenuItem(value: 'building', label: '按楼栋选', icon: CampusIcons.building),
    ]);
    if (picked == null || !mounted) return;
    await _add(switch (picked) {
      'scan' => () => zhuliScanDevice(context, runtime: widget.runtime, service: widget.service, phone: widget.phone),
      'number' => () => zhuliAskDeviceId(context),
      _ => () => zhuliPickDevice(context, service: widget.service, phone: widget.phone),
    });
  }

  @override
  Widget build(BuildContext context) {
    final favorites = _favorites;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('常用设备'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Builder(builder: (anchor) => CampusGlassCircleButton(label: '添加常用设备', size: 44, onPressed: _adding ? null : () => unawaited(_addMenu(anchor)), icon: const CampusIcon(CampusIcons.add))),
          ),
        ],
      ),
      body: CampusScrollFade(
        child: SafeArea(
          bottom: false,
          child: favorites == null
              ? const SizedBox.shrink()
              : favorites.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('还没有常用设备', style: TextStyle(color: CampusPalette.of(context).onSurfaceVariant)),
                      const SizedBox(height: CampusGap.medium),
                      Builder(builder: (anchor) => FilledButton.icon(onPressed: _adding ? null : () => unawaited(_addMenu(anchor)), icon: const CampusIcon(CampusIcons.add), label: const Text('添加'))),
                    ],
                  ),
                )
              : ListView(
                  padding: campusScrollPadding(context, const EdgeInsets.all(16)),
                  children: [
                    for (final (index, entry) in favorites.indexed)
                      KeyedSubtree(
                        key: ValueKey(entry.id),
                        child: _row(
                          context,
                          title: entry.place.isEmpty ? '设备号 ${entry.id}' : entry.place,
                          detail: entry.detail,
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
