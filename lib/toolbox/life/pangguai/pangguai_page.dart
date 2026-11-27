import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_animated_list.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_refresh.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/life/life_money.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_devices.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_device_page.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_login.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_order_page.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_service.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_shop_page.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_vault.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_web_page.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 手机号打码（130****8541），账号卡与切换菜单用。
String pangguaiMaskedPhone(String phone) => phone.length == 11 ? '${phone.substring(0, 3)}****${phone.substring(7)}' : phone;

// 胖乖生活首页：没登录时是登录表单；登录了从上到下是账号卡（⋯ 里切换、添加与退出账号）、进行中的订单（待付款与使用中，点进去付款或看倒计时）、
// 设备（扫码与附近门店，下面是最近使用），下拉刷新。登录凭据失效时在账号卡下面原地重新登录。
class PangguaiPage extends StatefulWidget {
  const PangguaiPage({super.key, required this.runtime});
  final ToolboxRuntime runtime;
  @override
  State<PangguaiPage> createState() => _PangguaiPageState();
}

class _PangguaiPageState extends State<PangguaiPage> {
  late PangguaiService _service;
  late Future<void> _ready = _initialize();
  PangguaiVaultState? _state;
  PangguaiUser? _user;
  List<PangguaiOrder>? _orders;
  List<PangguaiDeviceEntry> _recent = const [];
  var _recentOpen = false;
  String? _error;
  String? _relogin;
  // 切换账号后，旧账号晚回来的结果不再写界面。
  var _generation = 0;

  String? get _phone => _state?.current?.phone;

  Future<void> _initialize() async {
    try {
      await widget.runtime.initialize();
      _service = await widget.runtime.service<PangguaiService>(PangguaiService.serviceId);
      _state = await _service.state();
    } catch (error, stack) {
      campusLog('[Pangguai] action=initialize errorType=${error.runtimeType}\n$stack');
      rethrow;
    }
    if (_phone != null) unawaited(_load());
  }

  Future<void> _load() async {
    final phone = _phone;
    if (phone == null) return;
    final generation = ++_generation;
    setState(() {
      _error = null;
      _relogin = null;
    });
    try {
      final result = await _service.run(phone, (token) async => (user: await _service.client.user(token), orders: await _service.client.orders(token)));
      final recent = await _service.devices.recent(phone);
      if (!mounted || generation != _generation) return;
      setState(() {
        _user = result.user;
        // 进行中：待付款与使用中（第一页里的，胖乖按新的在前给）。
        _orders = [for (final order in result.orders) if (order.status == pangguaiUnpaid || order.status == pangguaiInUse) order];
        _recent = recent;
      });
    } on PangguaiException catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => error.failure == PangguaiFailure.notSignedIn ? _relogin = error.message : _error = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=load errorType=${error.runtimeType}\n$stack');
      if (mounted && generation == _generation) setState(() => _error = '没读到账号，稍后再试');
    }
  }

  // 第一次登录前取同意：手机号与验证码发给胖乖、凭据存本机安全存储、下单与附近门店要用位置（胖乖是新来源）。
  Future<bool> _consent() async {
    if (await widget.runtime.store.consent(PangguaiService.serviceId, PangguaiService.consentVersion)) return true;
    if (!mounted) return false;
    final agreed = await showCampusConfirm(
      context,
      title: '使用胖乖生活',
      // 长文案：第三方账号的同意说明，写清发给谁、存什么、用到位置。
      message: '手机号和短信验证码直接发给胖乖生活（qiekj.com），没注册过的号会注册胖乖账号；登录凭据存在本机的系统安全存储，订单不在本机保存。\n\n'
          '找附近门店和下单时，手机的位置发给胖乖生活。付款用支付宝，收款方是胖乖生活。\n\n'
          '胖乖生活是第三方服务，与本应用无关。只用本人的账号，并遵守它的服务条款。',
      action: '同意并登录',
    );
    if (agreed) await widget.runtime.store.grantConsent(PangguaiService.serviceId, PangguaiService.consentVersion);
    return agreed;
  }

  // 登录、切换或退出账号之后：换成新的账号状态重画（退出了最后一个账号就回登录表单），还在路上的旧账号结果作废（_generation）。
  Future<void> _signedIn() async {
    final state = await _service.state();
    if (!mounted) return;
    setState(() {
      _generation++;
      _state = state;
      _user = null;
      _orders = null;
      _recent = const [];
      _error = null;
      _relogin = null;
    });
    await _load();
  }

  // 设备页、订单页可能被换页（扫码页换成设备页、设备页下完单换成订单页），等不到返回：关掉时下一帧再刷新（关页面的那一帧里不能改界面）。
  void _reloadLater() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) unawaited(_load());
  });

  void _push(Widget page) => unawaited(Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => page)));

  void _openDevice(String goodsId) => _push(PangguaiDevicePage(service: _service, phone: _phone!, goodsId: goodsId, onClose: _reloadLater));

  // 扫码：胖乖的设备码（NQT、IMEI、SN）换成设备页，apwork.cn 的饮水机码换成胖乖的网页；别的码在取景页原地提示。
  Future<void> _scan() async {
    final scan = widget.runtime.scanQrCode, credential = _state?.current;
    if (scan == null || credential == null) return;
    await scan(context, '扫设备上的胖乖生活二维码', (raw) => pangguaiParseCode(raw) == null ? '不是胖乖生活的设备码' : null, then: (raw) => switch (pangguaiParseCode(raw)!) {
      PangguaiWaterCode(:final imei) => PangguaiWaterPage(imei: imei, token: credential.token),
      final PangguaiGoodsCode code => PangguaiDevicePage(service: _service, phone: credential.phone, code: code, onClose: _reloadLater),
    });
  }

  Future<void> _accountMenu(BuildContext anchor) async {
    final state = _state!, phone = _phone!;
    final picked = await showCampusMenu<String>(anchor, items: [
      for (final account in state.accounts)
        if (account.phone != phone) CampusMenuItem(value: account.phone, label: '切换到 ${pangguaiMaskedPhone(account.phone)}', icon: CampusIcons.switchAccount),
      if (state.accounts.length < pangguaiAccountLimit) const CampusMenuItem(value: '+', label: '添加账号', icon: CampusIcons.add),
      const CampusMenuItem(value: '-', label: '退出这个账号', icon: CampusIcons.logout, destructive: true),
    ]);
    if (picked == null || !mounted) return;
    if (picked == '+') {
      final added = await Navigator.of(context).push<String>(CampusPageRoute(builder: (_) => PangguaiLoginPage(service: _service, consent: _consent)));
      if (added != null) await _signedIn();
    } else if (picked == '-') {
      final agreed = await showCampusConfirm(context, title: '退出这个账号', message: '本机删掉 ${pangguaiMaskedPhone(phone)} 的登录凭据和最近使用，再用要重新收短信登录。', action: '退出', destructive: true);
      if (!agreed) return;
      await _service.signOut(phone);
      await _signedIn();
    } else {
      await _service.switchTo(picked);
      await _signedIn();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(tooltip: '返回', onPressed: () => context.canPop() ? context.pop() : Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
      title: const Text('胖乖生活'),
    ),
    body: CampusScrollFade(
      child: SafeArea(
        bottom: false,
        child: FutureBuilder<void>(
          future: _ready,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return CampusLoadError(message: '胖乖生活暂未就绪', onRetry: () => setState(() {
                _ready = _initialize();
              }));
            }
            if (snapshot.connectionState != ConnectionState.done) return const Center(child: CampusLoading(label: '正在准备'));
            final phone = _phone;
            if (phone == null) {
              return ListView(
                padding: campusScrollPadding(context, const EdgeInsets.all(16)),
                children: [
                  CampusSurface(
                    padding: EdgeInsets.fromLTRB(16, campusFieldGap(context), 16, 16),
                    child: PangguaiLoginForm(service: _service, consent: _consent, onSignedIn: (_) => unawaited(_signedIn())),
                  ),
                ],
              );
            }
            return CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                CampusRefreshControl(onRefresh: _load),
                SliverPadding(
                  padding: campusScrollPadding(context, const EdgeInsets.all(16)),
                  sliver: SliverList.list(
                    children: [
                      _accountCard(context, phone),
                      const SizedBox(height: CampusGap.large),
                      if (_relogin case final reason?)
                        CampusSurface(
                          padding: EdgeInsets.fromLTRB(16, campusFieldGap(context), 16, 16),
                          child: PangguaiLoginForm(key: ValueKey(phone), service: _service, consent: _consent, phone: phone, reason: reason, onSignedIn: (_) => unawaited(_signedIn())),
                        )
                      else ...[
                        if (_orders case final orders? when orders.isNotEmpty) ...[_ordersCard(context, orders), const SizedBox(height: CampusGap.large)],
                        if (_error case final error?) ...[CampusLoadError(message: error, onRetry: () => unawaited(_load())), const SizedBox(height: CampusGap.large)],
                        _devicesCard(context),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _accountCard(BuildContext context, String phone) {
    final palette = CampusPalette.of(context);
    final name = _user?.name ?? '';
    return CampusSurface(
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 16),
      child: Row(
        children: [
          CampusIcon(CampusIcons.account, size: 28, color: palette.primary),
          const SizedBox(width: CampusGap.large),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name.isNotEmpty ? name : '胖乖生活', style: Theme.of(context).textTheme.titleMedium),
                Text(pangguaiMaskedPhone(phone), style: TextStyle(color: palette.onSurfaceVariant)),
              ],
            ),
          ),
          Builder(builder: (anchor) => IconButton(tooltip: '账号', onPressed: () => unawaited(_accountMenu(anchor)), icon: const CampusIcon(CampusIcons.manage))),
        ],
      ),
    );
  }

  // 进行中的订单：待付款（5 分钟内能付，过了写已失效、点进去删掉）与使用中（预计几点结束）。
  Widget _ordersCard(BuildContext context, List<PangguaiOrder> orders) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    final now = DateTime.now().toUtc();
    return CampusSurface(
      padding: EdgeInsets.zero,
      child: CampusAnimatedColumn(
        children: [
          for (final order in orders)
            InkWell(
              key: ValueKey(order.orderId),
              onTap: () => _push(PangguaiOrderPage(service: _service, phone: _phone!, orderId: order.orderId, title: order.device, onClose: _reloadLater)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: CampusGap.medium),
                child: Row(
                  children: [
                    CampusIcon(order.status == pangguaiInUse ? CampusIcons.timer : CampusIcons.wallet, size: 28, color: palette.primary),
                    const SizedBox(width: CampusGap.large),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            switch (order) {
                              _ when order.status == pangguaiInUse => '使用中',
                              _ when order.payable(now) => '待付款 ¥${lifeYuan(order.cents)}',
                              _ => '没付的订单已失效',
                            },
                            style: const TextStyle(fontSize: CampusFontSize.body, fontWeight: FontWeight.w600),
                          ),
                          DotSeparatedText(
                            [
                              if (order.device.isNotEmpty) order.device,
                              if (order.function.isNotEmpty) order.function,
                              if (order.status == pangguaiInUse && order.endsAt != null) '预计 ${formatCampusClock(order.endsAt!)} 结束',
                            ].join(' · '),
                            style: secondary,
                          ),
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
    );
  }

  // 设备：扫码与附近门店（一行两个等宽），下面是最近使用（最多 6 台，新的在前，默认露两台、点「全部」展开）。
  Widget _devicesCard(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(color: palette.onSurfaceVariant);
    const tall = ButtonStyle(minimumSize: WidgetStatePropertyAll(Size.fromHeight(52)));
    final shown = _recentOpen ? _recent : _recent.take(2).toList();
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (widget.runtime.scanQrCode != null) ...[
                Expanded(child: FilledButton.icon(style: tall, onPressed: () => unawaited(_scan()), icon: const CampusIcon(CampusIcons.scan), label: const Text('扫码'))),
                const SizedBox(width: CampusGap.medium),
              ],
              Expanded(
                child: FilledButton.icon(
                  style: tall,
                  onPressed: () => _push(PangguaiNearbyPage(service: _service, phone: _phone!)),
                  icon: const CampusIcon(CampusIcons.place),
                  label: const Text('附近门店'),
                ),
              ),
            ],
          ),
          if (_recent.isNotEmpty) ...[
            const SizedBox(height: CampusGap.large),
            Row(
              children: [
                Expanded(child: Text('最近使用', style: secondary)),
                if (_recent.length > 2)
                  TextButton(
                    style: campusLink,
                    onPressed: () => setState(() => _recentOpen = !_recentOpen),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_recentOpen ? '收起' : '全部 ${_recent.length} 台'),
                        const SizedBox(width: CampusGap.tight),
                        CampusIcon(_recentOpen ? CampusIcons.collapse : CampusIcons.expand, size: 18),
                      ],
                    ),
                  ),
              ],
            ),
            CampusAnimatedColumn(
              children: [
                for (final entry in shown)
                  InkWell(
                    key: ValueKey(entry.goodsId),
                    onTap: () => _openDevice(entry.goodsId),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: CampusGap.small),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(entry.name.isEmpty ? (pangguaiCategories[entry.category] ?? '设备') : entry.name, style: const TextStyle(fontSize: CampusFontSize.body)),
                                DotSeparatedText([pangguaiCategories[entry.category] ?? '设备', if (entry.place.isNotEmpty) entry.place].join(' · '), style: secondary),
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
          ],
        ],
      ),
    );
  }
}
