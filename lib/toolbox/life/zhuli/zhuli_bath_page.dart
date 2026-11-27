import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/toolbox/life/life_money.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_field_table.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_bath.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_ble.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_client.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_devices.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_service.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 输设备号（设备上印的编号）：只收数字，确认后交回。
Future<int?> zhuliAskDeviceId(BuildContext context) => showCampusSheet<int>(context: context, builder: (_) => const _DeviceIdSheet());

const _scanHint = '扫洗浴设备上的二维码';

String? _rejectCode(String raw) => zhuliParseCode(raw) == null ? '不是住理生活的设备码' : null;

// 扫设备上的码：认出设备号直接用，认出蓝牙地址先向住理换成设备号；扫到别的码原地提示。没有扫码能力（测试）或取消为空。
Future<int?> zhuliScanDevice(BuildContext context, {required ToolboxRuntime runtime, required ZhuliService service, required String phone}) async {
  final scan = runtime.scanQrCode;
  if (scan == null) return null;
  final raw = await scan(context, _scanHint, _rejectCode);
  if (raw == null) return null;
  final code = zhuliParseCode(raw)!;
  if (code.deviceId case final id?) return id;
  return (await service.run(phone, (session) => service.client.deviceByMac(session, code.mac!))).id;
}

// 扫码直接去洗浴页（首页与「扫码洗浴」快捷入口）：扫码页直接换成这台设备的洗浴页（一次转场，不先回首页再推，11-23 用户视频里的闪），
// 蓝牙地址的码在洗浴页里换成设备号；洗浴页关掉时 onClose（首页刷新）。
Future<void> zhuliScanToBath(BuildContext context, {required ToolboxRuntime runtime, required ZhuliService service, required String phone, VoidCallback? onClose}) async {
  final scan = runtime.scanQrCode;
  if (scan == null) return;
  await scan(context, _scanHint, _rejectCode, then: (raw) {
    final code = zhuliParseCode(raw)!;
    return ZhuliBathPage(service: service, phone: phone, deviceId: code.deviceId, mac: code.mac, onClose: onClose);
  });
}

String _clockText(int minutes) => '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

String _elapsed(Duration duration) {
  final seconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

enum _Stage { checking, ready, starting, running, ending, done }

// 一台洗浴设备：开水前查一遍（ZhuliBath.prepare），给人看设备（设备号、状态、走哪一路）、余额与券余额、预扣与单价，点「开水」；
// 两用设备可以选走云端还是蓝牙（默认照学校设定，选过的下次照旧）。水开着时计时（云端的另每 3 秒查一次用了多少），点「关水」结算后原地显示这一单的账。
// 自己在这台上没结束的单，打开就接着显示「关水」。打开即记进最近使用；右上角星标收藏到常用设备。
class ZhuliBathPage extends StatefulWidget {
  const ZhuliBathPage({super.key, required this.service, required this.phone, this.deviceId, this.mac, this.link, this.clock, this.onClose}) : assert(deviceId != null || mac != null);
  final ZhuliService service;
  final String phone;
  // 设备号；扫到的是蓝牙地址时给 mac，打开时先向住理换成设备号。
  final int? deviceId;
  final String? mac;
  // 页面关掉时（换页进来的，来的那一页等不到返回值，靠它刷新）。
  final VoidCallback? onClose;
  // 测试注入蓝牙与时钟。
  final ZhuliBleLink Function()? link;
  final DateTime Function()? clock;
  @override
  State<ZhuliBathPage> createState() => _ZhuliBathPageState();
}

class _ZhuliBathPageState extends State<ZhuliBathPage> {
  late final _bath = ZhuliBath(service: widget.service, phone: widget.phone, link: widget.link, clock: widget.clock);
  var _stage = _Stage.checking;
  ZhuliBathPlan? _plan;
  // 这一次走哪一路的设备（plan.device 按选的通道 using 过）。
  ZhuliDevice? _device;
  String? _loadError;
  String? _error;
  String? _orderId;
  DateTime? _startedAt;
  int? _balanceAfter;
  ZhuliBill? _bill;
  // 蓝牙设备找不到或连不上时同房间的其他设备（换一台用，人工决策见 zhuli_bath.dart 的 zhuliCloudFirst）。
  List<ZhuliDevice> _mates = const [];
  var _favorite = false;
  Timer? _ticker;
  Timer? _poll;
  // 预先连好的蓝牙（见 _warmUp）与到点放开它的计时。
  Future<ZhuliBleLink>? _warm;
  Timer? _warmExpiry;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _poll?.cancel();
    _dropWarm();
    widget.onClose?.call();
    super.dispose();
  }

  // 走蓝牙、能开水时先在后台连上设备（同共享单车、充电宝的做法：点下去只剩命令帧的来回）；没给过蓝牙权限不弹框、不连。
  // 20 秒没用就断开（不一直占着设备，共用浴室里别人还能连）；点开水时没连上或已经断了照常当场连。
  void _warmUp() {
    final plan = _plan, device = _device;
    if (plan == null || device == null || !device.bluetooth || plan.blocked != null || _stage != _Stage.ready || _warm != null) return;
    final warm = _bath.link(device, ask: false);
    unawaited(warm.then<void>((_) => campusLog('[Zhuli] action=ble_warm result=ok'), onError: (Object error) => campusLog('[Zhuli] action=ble_warm result=failed reason=${error.runtimeType}')));
    _warm = warm;
    _warmExpiry = Timer(const Duration(seconds: 20), _dropWarm);
  }

  // 交出预先连的（开水时用），不再由页面断开。
  Future<ZhuliBleLink>? _takeWarm() {
    final warm = _warm;
    _warm = null;
    _warmExpiry?.cancel();
    return warm;
  }

  void _dropWarm() {
    if (_takeWarm() case final warm?) _release(warm);
  }

  void _release(Future<ZhuliBleLink> warm) => unawaited(warm.then((link) => link.disconnect(), onError: (Object _) {}));

  Future<void> _check() async {
    setState(() {
      _stage = _Stage.checking;
      _loadError = null;
    });
    try {
      final deviceId = widget.deviceId ?? (await widget.service.run(widget.phone, (session) => widget.service.client.deviceByMac(session, widget.mac!))).id;
      final plan = await _bath.prepare(deviceId);
      final lists = await widget.service.devices.used(widget.phone, ZhuliDeviceEntry.of(plan.device));
      if (!mounted) return;
      final chosen = lists.recent.where((entry) => entry.id == plan.device.id).firstOrNull?.channel;
      setState(() {
        _plan = plan;
        _device = chosen != null && plan.channels.contains(chosen) ? plan.device.using(chosen) : plan.device;
        _favorite = lists.favorites.any((entry) => entry.id == plan.device.id);
        _stage = _Stage.ready;
      });
      if (plan.running case final running?) {
        _running(running.orderId, DateTime.tryParse(zhuliMoment(running.createAt) ?? '')?.toLocal() ?? _now());
      } else {
        _warmUp();
      }
    } on ZhuliException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    } catch (error, stack) {
      campusLog('[Zhuli] action=bath_prepare errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _loadError = '没读到设备，稍后再试');
    }
  }

  void _running(String orderId, DateTime startedAt) {
    setState(() {
      _stage = _Stage.running;
      _orderId = orderId;
      _startedAt = startedAt;
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    // 云端的水开没开、用了多少看订单；蓝牙的用量要等关水时设备交回来，不查。
    if (!_device!.bluetooth) {
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(_refresh()));
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    final orderId = _orderId;
    if (orderId == null || _stage != _Stage.running) return;
    try {
      final bill = await _bath.bill(orderId);
      if (!mounted || _stage != _Stage.running) return;
      setState(() => _bill = bill);
      // 在设备上关了水或住理自己结算了：直接显示这一单的账。
      if (bill.status == 'finished' || bill.status == 'refund') _finished(bill);
    } catch (error) {
      campusLog('[Zhuli] action=bath_poll reason=${error.runtimeType}');
    }
  }

  void _finished(ZhuliBill bill) {
    _ticker?.cancel();
    _poll?.cancel();
    setState(() {
      _bill = bill;
      _stage = _Stage.done;
    });
  }

  // [人工决策-2026-11-23 12:47:51] 两用设备在洗浴页可选「云端 | 蓝牙」（用户选的方案 1：默认照原 App 的选路与学校设定 network_selection，用户可改）：
  // 11-22 真机上同一台两用设备强制走蓝牙三轮都通，用户要能用蓝牙；没选「默认蓝牙连不上自动改云端」与「只照学校设定不给选」。选了记进本机设备列表，下次默认用它。
  void _choose(int channel) {
    final plan = _plan!;
    _dropWarm();
    setState(() {
      _device = plan.device.using(channel);
      _error = null;
      _mates = const [];
    });
    _warmUp();
    unawaited(widget.service.devices.prefer(widget.phone, plan.device.id, channel).catchError((Object error, StackTrace stack) {
      campusLog('[Zhuli] action=prefer_channel errorType=${error.runtimeType}\n$stack');
      return (recent: <ZhuliDeviceEntry>[], favorites: <ZhuliDeviceEntry>[]);
    }));
  }

  Future<void> _start() async {
    final plan = _plan!, device = _device!;
    if (plan.confirm case final question?) {
      final agreed = await showCampusConfirm(context, title: '开水', message: question, action: '仍要开');
      if (!agreed || !mounted) return;
    }
    final warm = _takeWarm();
    setState(() {
      _stage = _Stage.starting;
      _error = null;
      _mates = const [];
    });
    try {
      final order = await _bath.start(device, warm: warm);
      if (!mounted) return;
      _balanceAfter = order.balance;
      _running(order.orderId, _now());
    } on ZhuliException catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.ready;
        _error = error.message;
      });
      if (error.failure == ZhuliFailure.unreachable) unawaited(_findMates(device));
    } catch (error, stack) {
      campusLog('[Zhuli] action=bath_start errorType=${error.runtimeType}\n$stack');
      if (!mounted) return;
      setState(() {
        _stage = _Stage.ready;
        _error = '没开成，稍后再试';
      });
    }
  }

  Future<void> _findMates(ZhuliDevice device) async {
    try {
      final mates = await _bath.roomMates(device);
      if (mounted && _stage == _Stage.ready) setState(() => _mates = mates);
    } catch (error, stack) {
      campusLog('[Zhuli] action=room_mates errorType=${error.runtimeType}\n$stack');
    }
  }

  void _switchTo(ZhuliDevice mate) => unawaited(Navigator.of(context).pushReplacement(CampusPageRoute<void>(builder: (_) => ZhuliBathPage(service: widget.service, phone: widget.phone, deviceId: mate.id, link: widget.link, clock: widget.clock, onClose: widget.onClose))));

  Future<void> _end() async {
    final device = _device!, orderId = _orderId!;
    // 蓝牙的弹确认时就在后台连设备，点「关水」时多半已经连好；取消就断开。
    final warm = device.bluetooth ? _bath.link(device) : null;
    if (warm != null) unawaited(warm.then<void>((_) {}, onError: (Object _) {}));
    final agreed = await showCampusConfirm(context, title: '关水', message: device.bluetooth ? '手机放在设备旁，现在关水并结算？' : '现在关水并结算？', action: '关水');
    if (!agreed || !mounted) {
      if (warm != null) _release(warm);
      return;
    }
    _poll?.cancel();
    setState(() {
      _stage = _Stage.ending;
      _error = null;
    });
    try {
      final bill = await _bath.end(device, orderId, warm: warm);
      if (mounted) _finished(bill);
    } on ZhuliException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
      _running(orderId, _startedAt!);
    } catch (error, stack) {
      campusLog('[Zhuli] action=bath_end errorType=${error.runtimeType}\n$stack');
      if (!mounted) return;
      setState(() => _error = '没关成，再试一次');
      _running(orderId, _startedAt!);
    }
  }

  Future<void> _toggleFavorite() async {
    final device = _plan!.device;
    try {
      final lists = _favorite ? await widget.service.devices.unfavor(widget.phone, device.id) : await widget.service.devices.favor(widget.phone, ZhuliDeviceEntry.of(device));
      if (!mounted) return;
      final favorite = lists.favorites.any((entry) => entry.id == device.id);
      setState(() => _favorite = favorite);
      showCampusToast(context, favorite ? '已收藏到常用设备' : '已移出常用设备');
    } on StateError {
      if (mounted) showCampusToast(context, '常用设备最多 $zhuliFavoriteLimit 台，先移掉几台');
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('洗浴'),
        actions: [
          if (plan != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: CampusGlassCircleButton(
                label: _favorite ? '移出常用设备' : '收藏到常用设备',
                size: 44,
                onPressed: () => unawaited(_toggleFavorite()),
                icon: CampusIcon(_favorite ? CampusIcons.unfavorite : CampusIcons.favorite),
              ),
            ),
        ],
      ),
      body: CampusScrollFade(
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: campusScrollPadding(context, const EdgeInsets.all(16)),
            children: [
              if (plan == null)
                if (_loadError case final error?) CampusLoadError(message: error, onRetry: () => unawaited(_check())) else const CampusLoading(label: '正在查设备', inline: true, network: true, remote: '住理生活')
              else ...[
                _deviceCard(context, plan),
                const SizedBox(height: CampusGap.large),
                if (_stage != _Stage.done) ...[_walletCard(context, plan), const SizedBox(height: CampusGap.large)],
                _actionCard(context, plan),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // 设备：位置、设备号与状态；两用设备开水前选走云端还是蓝牙，开着水时写这一单走的是哪一路。
  Widget _deviceCard(BuildContext context, ZhuliBathPlan plan) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    final device = _device!;
    final state = device.status != 0 ? '维护中' : device.idle ? '空闲' : '使用中';
    final choosing = plan.channels.length > 1 && (_stage == _Stage.ready || _stage == _Stage.starting) && plan.blocked == null;
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CampusIcon(CampusIcons.bath, size: 28, color: palette.primary),
          const SizedBox(width: CampusGap.large),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device.place.isEmpty ? '设备 ${device.id}' : device.place, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: CampusGap.tight),
                DotSeparatedText(
                  ['设备号 ${device.id}', ?device.distinctName, if (_stage == _Stage.ready || _stage == _Stage.checking) state, if (!choosing) device.bluetooth ? '蓝牙' : '云端'].join(' · '),
                  style: secondary,
                ),
                if (device.supply.isNotEmpty) Text('供水 ${device.supply.map((window) => '${_clockText(window.start)}–${_clockText(window.end)}').join('、')}', style: secondary),
                if (choosing) ...[
                  const SizedBox(height: CampusGap.medium),
                  CampusSegmented<int>(
                    values: plan.channels,
                    label: (channel) => channel == 4 ? '蓝牙' : '云端',
                    selected: device.channel,
                    onSelected: _stage == _Stage.ready ? _choose : null,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 余额、券余额、预扣与单价：只读，不用主色。
  Widget _walletCard(BuildContext context, ZhuliBathPlan plan) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    final rule = plan.rule;
    Widget amount(String label, int cents) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: secondary),
          Text('¥${lifeYuan(cents)}', style: const TextStyle(fontSize: CampusFontSize.title, fontWeight: FontWeight.w600)),
        ],
      ),
    );
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [amount('余额', _balanceAfter ?? plan.profile.balance), const SizedBox(width: CampusGap.large), amount('券余额', plan.coupons.balance)]),
          if (rule != null) ...[
            const SizedBox(height: CampusGap.medium),
            DotSeparatedText(
              [
                _stage == _Stage.running || _stage == _Stage.ending ? '已预扣 ¥${lifeYuan(rule.prepaid)}' : '开水先预扣 ¥${lifeYuan(rule.prepaid)}',
                '关水后按用量多退少补',
                if (rule.price case final price? when rule.metering) '¥${lifeYuan(price)}/升',
              ].join(' · '),
              style: secondary,
            ),
          ],
        ],
      ),
    );
  }

  Widget _actionCard(BuildContext context, ZhuliBathPlan plan) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    final error = _error;
    final bluetooth = _device!.bluetooth;
    Widget errorLine() => error == null ? const SizedBox.shrink() : Padding(padding: const EdgeInsets.only(top: CampusGap.medium), child: Text(error, style: TextStyle(color: palette.danger)));
    switch (_stage) {
      case _Stage.checking:
        return const SizedBox.shrink();
      case _Stage.ready || _Stage.starting:
        if (plan.blocked case final reason?) return CampusSurface(padding: const EdgeInsets.all(20), child: Text(reason, style: secondary));
        return CampusSurface(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (bluetooth) Padding(padding: const EdgeInsets.only(bottom: CampusGap.medium), child: Text('手机靠近设备、打开蓝牙', style: secondary)),
              CampusToastAnchor(
                child: FilledButton(
                  style: campusProminent,
                  onPressed: _stage == _Stage.ready ? () => unawaited(_start()) : null,
                  child: CampusBusyContent(busy: _stage == _Stage.starting, label: '开水', busyLabel: bluetooth ? '连接设备' : '开水中', icon: const CampusIcon(CampusIcons.bath)),
                ),
              ),
              errorLine(),
              for (final mate in _mates)
                Padding(
                  padding: const EdgeInsets.only(top: CampusGap.medium),
                  child: FilledButton.icon(
                    key: ValueKey(mate.id),
                    onPressed: () => _switchTo(mate),
                    icon: const CampusIcon(CampusIcons.swapDevice),
                    label: DotSeparatedText('换到设备号 ${mate.id} · ${mate.modeLabel}'),
                  ),
                ),
            ],
          ),
        );
      case _Stage.running || _Stage.ending:
        final bill = _bill;
        final waiting = !bluetooth && (bill == null || bill.status == 'created');
        return CampusSurface(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(waiting ? '等设备开水' : '水已开', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: CampusGap.tight),
              Text(_elapsed(_now().difference(_startedAt!)), style: const TextStyle(fontSize: CampusFontSize.headline, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
              // 住理给了用量才写；11-22 真机上云端设备开着水时住理一直不更新、关水才回来，没有数时同蓝牙一样写「用量在关水时结算」。
              if (!bluetooth && bill != null && bill.status == 'consuming' && (bill.liters > 0 || bill.money > 0))
                DotSeparatedText('${bill.liters.toStringAsFixed(2)} 升 · ¥${lifeYuan(bill.money)}', style: secondary)
              else if (!waiting)
                Text('用量在关水时结算', style: secondary),
              const SizedBox(height: CampusGap.large),
              CampusToastAnchor(
                child: FilledButton(
                  style: campusProminent,
                  onPressed: _stage == _Stage.running ? () => unawaited(_end()) : null,
                  child: CampusBusyContent(busy: _stage == _Stage.ending, label: '关水', busyLabel: '关水中', icon: const CampusIcon(CampusIcons.stop)),
                ),
              ),
              errorLine(),
            ],
          ),
        );
      case _Stage.done:
        final bill = _bill!;
        final from = [if (bill.fromCoupon > 0) '券 ¥${lifeYuan(bill.fromCoupon)}', if (bill.fromBalance > 0) '余额 ¥${lifeYuan(bill.fromBalance)}', if (bill.fromPay > 0) '${zhuliPayChannel(bill.payChannel)} ¥${lifeYuan(bill.fromPay)}'];
        return CampusSurface(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(bill.status == 'finished' || bill.status == 'refund' ? '已关水' : '已关水，住理还在结算', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: CampusGap.medium),
              CampusFieldTable(rows: [
                ('用水', '${bill.liters.toStringAsFixed(2)} 升 · ${bill.seconds} 秒'),
                ('实扣', '¥${lifeYuan(bill.money)}'),
                if (bill.prepaid > 0) ('预扣', '¥${lifeYuan(bill.prepaid)}'),
                if (bill.refund > 0) ('退回', '¥${lifeYuan(bill.refund)}'),
                if (from.isNotEmpty) ('扣款', from.join('、')),
                ('订单号', bill.orderId),
              ]),
              const SizedBox(height: CampusGap.large),
              CampusToastAnchor(
                child: FilledButton.icon(onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.check), label: const Text('完成')),
              ),
            ],
          ),
        );
    }
  }
}

class _DeviceIdSheet extends StatefulWidget {
  const _DeviceIdSheet();
  @override
  State<_DeviceIdSheet> createState() => _DeviceIdSheetState();
}

class _DeviceIdSheetState extends State<_DeviceIdSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final id = int.tryParse(_controller.text.trim());
    if (id != null && id > 0) Navigator.pop(context, id);
  }

  @override
  Widget build(BuildContext context) => CampusSheetPanel(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('输入设备号', style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: campusFieldGap(context)),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 12,
            decoration: const InputDecoration(labelText: '设备上印的编号', counterText: ''),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: CampusGap.large),
          ValueListenableBuilder(
            valueListenable: _controller,
            builder: (context, value, _) => FilledButton.icon(
              style: campusProminent,
              onPressed: int.tryParse(value.text.trim()) == null ? null : _submit,
              icon: const CampusIcon(CampusIcons.next),
              label: const Text('打开'),
            ),
          ),
        ],
      ),
    ),
  );
}
