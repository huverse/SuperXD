import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_refresh.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/life/life_money.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_service.dart';

// 饮水机页（apwork.cn 码，扣水卡的钱，不走支付宝下单）：设备名与位置、选水种（每升多少钱，出不了的写「暂不可用」、虚线空心）、共享水卡时选哪张、所选水卡的余额；
// 「开始取水」锁机后人在机器上按闪着灯的按钮出水、再按停止（App 没有远程停止），页面前台时每 4 秒查一次状态（最多 15 次）；
// 结束不等于扣了费，过一会儿重读余额与用水记录（订单与余额都会晚一点才出来，一次查不到别急着再锁）。
// 余额不够时「充值」：选档后跳支付宝小程序（同官方网页），回来重读余额；余额涨了也不当成这一笔到账的凭据。
class PangguaiWaterPage extends StatefulWidget {
  const PangguaiWaterPage({super.key, required this.service, required this.phone, required this.hash, this.onClose});
  final PangguaiService service;
  final String phone;
  final String hash;
  final VoidCallback? onClose;
  @override
  State<PangguaiWaterPage> createState() => _PangguaiWaterPageState();
}

class _PangguaiWaterPageState extends State<PangguaiWaterPage> with WidgetsBindingObserver {
  PangguaiWater? _water;
  String? _error;
  String? _choiceId;
  String? _areaId;
  var _locking = false;
  String? _actionError;
  var _unsure = false;
  // 这一次取水：锁上之后才有；状态 0 等按键、2 出水中、3 与 5 结束了。
  ({PangguaiWater water, PangguaiWaterChoice choice, String? workingId})? _run;
  int? _state;
  var _polls = 0;
  Timer? _poll;
  List<PangguaiWaterRecord>? _records;
  // 充值：点了「充值」才读档位。
  var _rechargeOpen = false;
  List<PangguaiRechargeTier>? _tiers;
  String? _tierId;
  var _recharging = false;
  var _awayForRecharge = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    widget.onClose?.call();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _poll?.cancel();
    } else if (state == AppLifecycleState.resumed) {
      if (_awayForRecharge) {
        _awayForRecharge = false;
        unawaited(_load());
      } else if (_run != null && !_ended) {
        _schedule();
      }
    }
  }

  bool get _ended => _state == 3 || _state == 5;

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final water = await widget.service.water(widget.phone, widget.hash);
      if (!mounted) return;
      setState(() {
        _water = water;
        final available = water.choices.where((choice) => choice.available);
        if (!available.any((choice) => choice.id == _choiceId)) _choiceId = (available.where((choice) => choice.name.contains('常温')).firstOrNull ?? available.firstOrNull)?.id;
        if (!water.cards.any((card) => card.areaId == _areaId)) _areaId = water.cards.firstOrNull?.areaId;
      });
      unawaited(_loadRecords());
    } on PangguaiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=water errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '没读到这台饮水机，稍后再试');
    }
  }

  Future<void> _loadRecords() async {
    try {
      final records = await widget.service.run(widget.phone, (token) => widget.service.client.waterRecords(token));
      if (mounted) setState(() => _records = records);
    } catch (error, stack) {
      campusLog('[Pangguai] action=water_records errorType=${error.runtimeType}\n$stack');
    }
  }

  Future<void> _unlock() async {
    final choiceId = _choiceId, areaId = _areaId;
    if (choiceId == null || areaId == null) return;
    setState(() {
      _locking = true;
      _actionError = null;
      _unsure = false;
    });
    try {
      final run = await widget.service.unlock(widget.phone, widget.hash, choiceId: choiceId, areaId: areaId);
      if (!mounted) return;
      setState(() {
        _run = run;
        _water = run.water;
        _state = 0;
        _polls = 0;
      });
      if (run.workingId != null) _schedule();
    } on PangguaiException catch (error) {
      if (mounted) {
        setState(() {
          _actionError = error.message;
          _unsure = error.failure == PangguaiFailure.unsure;
        });
      }
    } catch (error, stack) {
      campusLog('[Pangguai] action=unlock errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _actionError = '没锁上饮水机，稍后再试');
    } finally {
      if (mounted) setState(() => _locking = false);
    }
  }

  void _schedule() {
    _poll?.cancel();
    final run = _run, workingId = run?.workingId;
    if (run == null || workingId == null || _ended || _polls >= 15) return;
    _poll = Timer(const Duration(seconds: 4), () async {
      try {
        final state = await widget.service.run(widget.phone, (token) => widget.service.client.waterStatus(token, run.water, run.choice, workingId));
        if (!mounted) return;
        setState(() {
          _state = state;
          _polls++;
        });
        if (_ended) {
          // 结束了：费用与余额晚一点才出来，过一会儿再读。
          _poll = Timer(const Duration(seconds: 8), () => unawaited(_load()));
        } else {
          _schedule();
        }
      } catch (error, stack) {
        campusLog('[Pangguai] action=water_status errorType=${error.runtimeType}\n$stack');
        if (mounted) setState(() => _polls = 15);
      }
    });
  }

  // 结束这一次（机器已经停了）：回到能再取水的样子，重读余额。
  void _finish() {
    _poll?.cancel();
    setState(() {
      _run = null;
      _state = null;
    });
    unawaited(_load());
  }

  Future<void> _openRecharge() async {
    final water = _water;
    if (water == null) return;
    setState(() {
      _rechargeOpen = true;
      _tiers = null;
      _actionError = null;
    });
    try {
      final tiers = await widget.service.client.rechargeTiers(water);
      if (mounted) {
        setState(() {
          _tiers = tiers;
          _tierId = tiers.firstOrNull?.id;
        });
      }
    } on PangguaiException catch (error) {
      if (mounted) {
        setState(() {
          _rechargeOpen = false;
          _actionError = error.message;
        });
      }
    } catch (error, stack) {
      campusLog('[Pangguai] action=recharge_tiers errorType=${error.runtimeType}\n$stack');
      if (mounted) {
        setState(() {
          _rechargeOpen = false;
          _actionError = '没读到充值档位，稍后再试';
        });
      }
    }
  }

  // 重新扫一次拿新的会话，核对档位还在，再跳支付宝小程序。
  Future<void> _recharge() async {
    final tierId = _tierId;
    if (tierId == null) return;
    setState(() {
      _recharging = true;
      _actionError = null;
    });
    try {
      final water = await widget.service.water(widget.phone, widget.hash);
      final merchantId = water.merchantId, merchantAreaId = water.merchantAreaId;
      final tiers = await widget.service.client.rechargeTiers(water);
      if (merchantId == null || merchantAreaId == null || !tiers.any((tier) => tier.id == tierId)) throw const PangguaiException(PangguaiFailure.rejected, '充值档位变了，重新选一个');
      final uri = pangguaiRechargeUri(session: water.session, merchantId: merchantId, merchantAreaId: merchantAreaId, tierId: tierId, phone: widget.phone);
      _awayForRecharge = true;
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      campusLog('[Pangguai] action=recharge_open opened=$opened');
      if (!opened) {
        _awayForRecharge = false;
        throw const PangguaiException(PangguaiFailure.rejected, '没打开支付宝，装好支付宝再试');
      }
      if (mounted) setState(() => _rechargeOpen = false);
    } on PangguaiException catch (error) {
      if (mounted) setState(() => _actionError = error.message);
    } catch (error, stack) {
      _awayForRecharge = false;
      campusLog('[Pangguai] action=recharge errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _actionError = '没打开支付宝，稍后再试');
    } finally {
      if (mounted) setState(() => _recharging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final water = _water;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('饮水机'),
      ),
      body: CampusScrollFade(
        child: SafeArea(
          bottom: false,
          child: water == null
              ? (_error == null ? const Center(child: CampusLoading(label: '正在读取饮水机', network: true, remote: '胖乖生活')) : CampusLoadError(message: _error!, onRetry: () => unawaited(_load())))
              : CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    CampusRefreshControl(onRefresh: _load),
                    SliverPadding(
                      padding: campusScrollPadding(context, const EdgeInsets.all(16)),
                      sliver: SliverList.list(
                        children: [
                          _header(context, water),
                          const SizedBox(height: CampusGap.large),
                          if (_run != null) _running(context) else _choices(context, water),
                          if (_records case final records? when records.isNotEmpty) ...[const SizedBox(height: CampusGap.large), _recordList(context, records)],
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, PangguaiWater water) {
    final palette = CampusPalette.of(context);
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CampusIcon(CampusIcons.water, size: 28, color: palette.primary),
              const SizedBox(width: CampusGap.large),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(water.name.isEmpty ? '饮水机' : water.name, style: Theme.of(context).textTheme.titleMedium),
                    if (water.place.isNotEmpty) Text(water.place, style: TextStyle(color: palette.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
          if (water.unusable case final reason?) ...[const SizedBox(height: CampusGap.large), Text(reason, style: TextStyle(color: palette.danger))],
        ],
      ),
    );
  }

  Widget _choices(BuildContext context, PangguaiWater water) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    final card = water.cards.where((each) => each.areaId == _areaId).firstOrNull;
    final short = card != null && card.balance < water.minimum;
    final error = _actionError;
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('水', style: secondary),
          const SizedBox(height: CampusGap.small),
          Wrap(
            spacing: CampusGap.small,
            runSpacing: CampusGap.small,
            children: [
              for (final choice in water.choices)
                CampusGlassChip(
                  key: ValueKey(choice.id),
                  label: choice.available ? '${choice.name} ¥${lifeYuan(choice.rate)}/升' : '${choice.name} 暂不可用',
                  selected: choice.id == _choiceId,
                  unavailable: !choice.available,
                  onSelected: _locking ? null : (_) => setState(() => _choiceId = choice.id),
                ),
            ],
          ),
          if (water.cards.length > 1) ...[
            const SizedBox(height: CampusGap.large),
            Text('水卡', style: secondary),
            const SizedBox(height: CampusGap.small),
            Wrap(
              spacing: CampusGap.small,
              runSpacing: CampusGap.small,
              children: [
                for (final each in water.cards)
                  CampusGlassChip(key: ValueKey(each.areaId), label: each.name.isEmpty ? '水卡' : each.name, selected: each.areaId == _areaId, onSelected: _locking ? null : (_) => setState(() => _areaId = each.areaId)),
              ],
            ),
          ],
          if (card != null) ...[
            const SizedBox(height: CampusGap.large),
            Text('水卡余额', style: secondary),
            Text('¥${lifeYuan(card.balance)}', style: const TextStyle(fontSize: CampusFontSize.headline, fontWeight: FontWeight.w600)),
            if (short) Text('不到 ¥${lifeYuan(water.minimum)}，先充值', style: secondary),
          ],
          const SizedBox(height: CampusGap.large),
          FilledButton(
            style: campusProminent,
            onPressed: water.unusable == null && !short && _choiceId != null && card != null && !_locking && !_recharging ? () => unawaited(_unlock()) : null,
            child: CampusBusyContent(busy: _locking, label: '开始取水', busyLabel: '正在锁机', icon: const CampusIcon(CampusIcons.water)),
          ),
          if (error != null) ...[const SizedBox(height: CampusGap.medium), Text(error, style: TextStyle(color: palette.danger))],
          if (_unsure) ...[
            const SizedBox(height: CampusGap.small),
            Align(child: OutlinedButton.icon(onPressed: () => unawaited(_loadRecords()), icon: const CampusIcon(CampusIcons.orders), label: const Text('看用水记录'))),
          ],
          if (water.merchantId != null && water.merchantAreaId != null) ...[
            const SizedBox(height: CampusGap.small),
            if (!_rechargeOpen)
              OutlinedButton.icon(onPressed: _locking ? null : () => unawaited(_openRecharge()), icon: const CampusIcon(CampusIcons.wallet), label: const Text('充值'))
            else
              _rechargePanel(context),
          ],
        ],
      ),
    );
  }

  Widget _rechargePanel(BuildContext context) {
    final tiers = _tiers;
    if (tiers == null) return const CampusLoading(label: '正在读取充值档位', inline: true, network: true, remote: 'apwork');
    final secondary = TextStyle(color: CampusPalette.of(context).onSurfaceVariant);
    if (tiers.isEmpty) return Text('这台饮水机不能在这里充值，请在胖乖生活 App 里充', style: secondary);
    final tier = tiers.where((each) => each.id == _tierId).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: CampusGap.small),
        Text('充值', style: secondary),
        const SizedBox(height: CampusGap.small),
        Wrap(
          spacing: CampusGap.small,
          runSpacing: CampusGap.small,
          children: [
            for (final each in tiers)
              CampusGlassChip(
                key: ValueKey(each.id),
                label: each.gift > 0 ? '¥${lifeYuan(each.amount)} 送 ¥${lifeYuan(each.gift)}' : '¥${lifeYuan(each.amount)}',
                selected: each.id == _tierId,
                onSelected: _recharging ? null : (_) => setState(() => _tierId = each.id),
              ),
          ],
        ),
        const SizedBox(height: CampusGap.medium),
        FilledButton(
          onPressed: tier == null || _recharging ? null : () => unawaited(_recharge()),
          child: CampusBusyContent(busy: _recharging, label: tier == null ? '去支付宝充值' : '去支付宝充 ¥${lifeYuan(tier.amount)}', busyLabel: '正在打开支付宝', icon: const CampusIcon(CampusIcons.wallet)),
        ),
      ],
    );
  }

  // 锁上之后：按状态写该做什么；结束了给「好了」回到能再取水的样子。
  Widget _running(BuildContext context) {
    final palette = CampusPalette.of(context);
    final run = _run!;
    final text = switch (_state) {
      2 => '出水中，再按一次按钮停止',
      3 || 5 => '这次取水结束了，费用稍后从水卡扣',
      _ => '按机器上闪灯的按钮出水，再按一次停止',
    };
    final watching = run.workingId != null && !_ended && _polls < 15;
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(run.choice.name, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: CampusGap.small),
          BalancedText(text, style: const TextStyle(fontSize: CampusFontSize.body)),
          if (watching) ...[const SizedBox(height: CampusGap.medium), const CampusLoading(label: '正在看取水状态', inline: true)],
          if (!watching && !_ended) ...[const SizedBox(height: CampusGap.small), Text('状态先不查了，机器停了就点「好了」', style: TextStyle(color: palette.onSurfaceVariant))],
          const SizedBox(height: CampusGap.large),
          FilledButton.icon(onPressed: _finish, icon: const CampusIcon(CampusIcons.check), label: const Text('好了')),
        ],
      ),
    );
  }

  Widget _recordList(BuildContext context, List<PangguaiWaterRecord> records) {
    final secondary = TextStyle(color: CampusPalette.of(context).onSurfaceVariant);
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('用水记录', style: secondary),
          for (final record in records.take(5))
            Padding(
              key: ValueKey(record.number),
              padding: const EdgeInsets.only(top: CampusGap.small),
              child: Row(
                children: [
                  Expanded(child: DotSeparatedText([if (record.at case final at?) formatCampusRelative(at.toIso8601String()), if (record.device.isNotEmpty) '设备 ${record.device}'].join(' · '))),
                  Text('¥${lifeYuan(record.price)}'),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
