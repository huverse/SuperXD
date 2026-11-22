import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_field_table.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
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

// 扫设备上的码：认出设备号直接用，认出蓝牙地址先向住理换成设备号；扫到别的码原地提示。没有扫码能力（测试）或取消为空。
Future<int?> zhuliScanDevice(BuildContext context, {required ToolboxRuntime runtime, required ZhuliService service, required String phone}) async {
  final scan = runtime.scanQrCode;
  if (scan == null) return null;
  final raw = await scan(context, '扫洗浴设备上的二维码', (raw) => zhuliParseCode(raw) == null ? '不是住理生活的设备码' : null);
  if (raw == null) return null;
  final code = zhuliParseCode(raw)!;
  if (code.deviceId case final id?) return id;
  return (await service.run(phone, (session) => service.client.deviceByMac(session, code.mac!))).id;
}

String _clockText(int minutes) => '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

String _elapsed(Duration duration) {
  final seconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

enum _Stage { checking, ready, starting, running, ending, done }

// 一台洗浴设备：开水前查一遍（ZhuliBath.prepare），给人看设备、余额与券余额、预扣与单价，点「开水」；
// 水开着时计时（云端的另每 3 秒查一次用了多少），点「关水」结算后原地显示这一单的账。自己在这台上没结束的单，打开就接着显示「关水」。
// 打开即记进最近使用；右上角星标收藏到常用设备。
class ZhuliBathPage extends StatefulWidget {
  const ZhuliBathPage({super.key, required this.service, required this.phone, required this.deviceId, this.link, this.clock});
  final ZhuliService service;
  final String phone;
  final int deviceId;
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
  String? _loadError;
  String? _error;
  String? _orderId;
  DateTime? _startedAt;
  int? _balanceAfter;
  ZhuliBill? _bill;
  var _favorite = false;
  Timer? _ticker;
  Timer? _poll;

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
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _stage = _Stage.checking;
      _loadError = null;
    });
    try {
      final plan = await _bath.prepare(widget.deviceId);
      final lists = await widget.service.devices.used(widget.phone, ZhuliDeviceEntry.of(plan.device));
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _favorite = lists.favorites.any((entry) => entry.id == plan.device.id);
        _stage = _Stage.ready;
      });
      if (plan.running case final running?) _running(running.orderId, DateTime.tryParse(zhuliMoment(running.createAt) ?? '')?.toLocal() ?? _now());
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
    if (!_plan!.device.bluetooth) {
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

  Future<void> _start() async {
    final plan = _plan!;
    if (plan.confirm case final question?) {
      final agreed = await showCampusConfirm(context, title: '开水', message: question, action: '仍要开');
      if (!agreed || !mounted) return;
    }
    setState(() {
      _stage = _Stage.starting;
      _error = null;
    });
    try {
      final order = await _bath.start(plan.device);
      if (!mounted) return;
      _balanceAfter = order.balance;
      _running(order.orderId, _now());
    } on ZhuliException catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.ready;
        _error = error.message;
      });
    } catch (error, stack) {
      campusLog('[Zhuli] action=bath_start errorType=${error.runtimeType}\n$stack');
      if (!mounted) return;
      setState(() {
        _stage = _Stage.ready;
        _error = '没开成，稍后再试';
      });
    }
  }

  Future<void> _end() async {
    final plan = _plan!, orderId = _orderId!;
    final agreed = await showCampusConfirm(context, title: '关水', message: plan.device.bluetooth ? '手机放在设备旁，现在关水并结算？' : '现在关水并结算？', action: '关水');
    if (!agreed || !mounted) return;
    _poll?.cancel();
    setState(() {
      _stage = _Stage.ending;
      _error = null;
    });
    try {
      final bill = await _bath.end(plan.device, orderId);
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
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (plan == null)
                if (_loadError case final error?) CampusLoadError(message: error, onRetry: () => unawaited(_check())) else const CampusLoading(label: '正在查设备', inline: true, network: true, remote: '住理生活')
              else ...[
                _deviceCard(context, plan.device),
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

  Widget _deviceCard(BuildContext context, ZhuliDevice device) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    final state = device.status != 0 ? '维护中' : device.idle ? '空闲' : '使用中';
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
                DotSeparatedText(['设备 ${device.name.isEmpty ? device.id : device.name}', if (_stage == _Stage.ready || _stage == _Stage.checking) state, device.bluetooth ? '蓝牙' : '云端'].join(' · '), style: secondary),
                if (device.supply.isNotEmpty) Text('供水 ${device.supply.map((window) => '${_clockText(window.start)}–${_clockText(window.end)}').join('、')}', style: secondary),
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
          Text('¥${zhuliYuan(cents)}', style: const TextStyle(fontSize: CampusFontSize.title, fontWeight: FontWeight.w600)),
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
                _stage == _Stage.running || _stage == _Stage.ending ? '已预扣 ¥${zhuliYuan(rule.prepaid)}' : '开水先预扣 ¥${zhuliYuan(rule.prepaid)}',
                '关水后按用量多退少补',
                if (rule.price case final price? when rule.metering) '¥${zhuliYuan(price)}/升',
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
    final bluetooth = plan.device.bluetooth;
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
              if (bluetooth) Padding(padding: const EdgeInsets.only(bottom: CampusGap.medium), child: Text('蓝牙开水：手机靠近设备，打开蓝牙', style: secondary)),
              CampusToastAnchor(
                child: FilledButton(
                  style: campusProminent,
                  onPressed: _stage == _Stage.ready ? () => unawaited(_start()) : null,
                  child: CampusBusyContent(busy: _stage == _Stage.starting, label: '开水', busyLabel: bluetooth ? '连接设备' : '开水中', icon: const CampusIcon(CampusIcons.bath)),
                ),
              ),
              errorLine(),
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
                Text('${bill.liters.toStringAsFixed(2)} 升 · ¥${zhuliYuan(bill.money)}', style: secondary)
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
        final from = [if (bill.fromCoupon > 0) '券 ¥${zhuliYuan(bill.fromCoupon)}', if (bill.fromBalance > 0) '余额 ¥${zhuliYuan(bill.fromBalance)}', if (bill.fromPay > 0) '${zhuliPayChannel(bill.payChannel)} ¥${zhuliYuan(bill.fromPay)}'];
        return CampusSurface(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(bill.status == 'finished' || bill.status == 'refund' ? '已关水' : '已关水，住理还在结算', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: CampusGap.medium),
              CampusFieldTable(rows: [
                ('用水', '${bill.liters.toStringAsFixed(2)} 升 · ${bill.seconds} 秒'),
                ('实扣', '¥${zhuliYuan(bill.money)}'),
                if (bill.prepaid > 0) ('预扣', '¥${zhuliYuan(bill.prepaid)}'),
                if (bill.refund > 0) ('退回', '¥${zhuliYuan(bill.refund)}'),
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
