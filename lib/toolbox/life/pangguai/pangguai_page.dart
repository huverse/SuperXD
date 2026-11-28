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
import 'package:superxd/toolbox/life/pangguai/pangguai_device_page.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_devices.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_login.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_order_page.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_service.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_shop_page.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_vault.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_water_page.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 手机号打码（130****8541），账号卡与切换菜单用。
String pangguaiMaskedPhone(String phone) => phone.length == 11 ? '${phone.substring(0, 3)}****${phone.substring(7)}' : phone;

// 胖乖生活首页：没登录时是登录表单；登录了从上到下是账号卡（⋯ 里切换、添加与退出账号）、进行中的订单（使用中的，与刚下还没付的，点进订单页）、
// 用设备（扫码与附近门店一行两个等宽，下面最近使用默认两台、点「全部」展开）、订单，下拉刷新。凭据失效时在账号卡下原地重新登录。
// 扫码：胖乖的设备码直接换成设备页，饮水机码换成饮水机页，别的码在取景页提示。
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
      final recent = await _service.devices.load(phone);
      if (mounted && generation == _generation) setState(() => _recent = recent);
      final orders = await _service.ongoing(phone);
      if (mounted && generation == _generation) setState(() => _orders = orders);
    } on PangguaiException catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => error.failure == PangguaiFailure.notSignedIn ? _relogin = error.message : _error = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=load errorType=${error.runtimeType}\n$stack');
      if (mounted && generation == _generation) setState(() => _error = '没读到订单，稍后再试');
    }
  }

  // 第一次发验证码前取同意：发给谁、存什么、用到位置与人机验证（胖乖是新来源）。
  Future<bool> _consent() async {
    if (await widget.runtime.store.consent(PangguaiService.serviceId, PangguaiService.consentVersion)) return true;
    if (!mounted) return false;
    final agreed = await showCampusConfirm(
      context,
      title: '使用胖乖生活',
      // 长文案：第三方账号的同意说明，写清发给谁、存什么、用到什么权限。
      message: '手机号和短信验证码直接发给胖乖生活（qiekj.com），登录凭据存在本机的系统安全存储。胖乖要人机验证时，由网易易盾的验证组件弹出。\n\n'
          '找附近门店和打开设备时读一次手机位置，下单时才发给胖乖。饮水机的水卡由胖乖的合作方 apwork.cn 提供，充值在支付宝小程序里完成。订单和余额不在本机保存。\n\n'
          '胖乖生活是第三方服务，与本应用无关。只用本人的账号，并遵守它的服务条款。',
      action: '同意并继续',
    );
    if (agreed) await widget.runtime.store.grantConsent(PangguaiService.serviceId, PangguaiService.consentVersion);
    return agreed;
  }

  // 登录、切换或退出账号之后：换成新的账号状态重画（退出了最后一个账号就回登录表单），还在路上的旧账号结果作废。
  Future<void> _signedIn() async {
    final state = await _service.state();
    if (!mounted) return;
    setState(() {
      _generation++;
      _state = state;
      _orders = null;
      _recent = const [];
      _error = null;
      _relogin = null;
    });
    await _load();
  }

  // 设备页、订单页可能是换页进去的（扫码、下单）：关掉时下一帧再刷新（关页面的那一帧里不能改界面）。
  void _reloadLater() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) unawaited(_load());
  });

  Widget _pageFor(PangguaiCode code, String phone) => code.key == 'water'
      ? PangguaiWaterPage(service: _service, phone: phone, hash: code.value, onClose: _reloadLater)
      : PangguaiDevicePage(service: _service, phone: phone, code: code, onClose: _reloadLater);

  Future<void> _scan(String phone) async {
    final scan = widget.runtime.scanQrCode;
    if (scan == null) return;
    await scan(context, '扫设备上的胖乖码', (raw) => pangguaiParseCode(raw) == null ? '不是胖乖的设备码' : null, then: (raw) => _pageFor(pangguaiParseCode(raw)!, phone));
  }

  Future<void> _push(Widget page) async {
    await Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => page));
    if (mounted) unawaited(_load());
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
      final agreed = await showCampusConfirm(context, title: '退出这个账号', message: '本机删掉 ${pangguaiMaskedPhone(phone)} 的登录凭据，再用要重新收验证码登录。', action: '退出', destructive: true);
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
                        ..._ongoing(context, phone),
                        _devicesCard(context, phone),
                        const SizedBox(height: CampusGap.large),
                        _ordersEntry(context, phone),
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
    final name = _state?.current?.name ?? '';
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
                Text(name.isEmpty ? '胖乖生活' : name, style: Theme.of(context).textTheme.titleMedium),
                Text(pangguaiMaskedPhone(phone), style: TextStyle(color: palette.onSurfaceVariant)),
              ],
            ),
          ),
          Builder(builder: (anchor) => IconButton(tooltip: '账号', onPressed: () => unawaited(_accountMenu(anchor)), icon: const CampusIcon(CampusIcons.manage))),
        ],
      ),
    );
  }

  // 进行中的订单：每单一张卡，使用中的写预计几点结束，没付的写待付款。
  List<Widget> _ongoing(BuildContext context, String phone) {
    final palette = CampusPalette.of(context);
    final orders = _orders;
    if (orders == null) {
      if (_error case final error?) return [CampusLoadError(message: error, onRetry: () => unawaited(_load())), const SizedBox(height: CampusGap.large)];
      return const [];
    }
    return [
      for (final order in orders) ...[
        CampusSurface(
          key: ValueKey(order.id),
          padding: const EdgeInsets.all(20),
          onTap: () => unawaited(_push(PangguaiOrderPage(service: _service, phone: phone, orderId: order.id))),
          child: Row(
            children: [
              CampusIcon(order.running ? CampusIcons.timer : CampusIcons.wallet, size: 28, color: palette.primary),
              const SizedBox(width: CampusGap.large),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(order.machine.isEmpty ? '设备订单' : order.machine, style: const TextStyle(fontSize: CampusFontSize.body, fontWeight: FontWeight.w600)),
                    DotSeparatedText(
                      [order.statusLabel, if (order.running && order.endsAt != null) '预计 ${formatCampusClock(order.endsAt!)} 结束', if (order.payable) '¥${lifeYuan(order.price)}'].join(' · '),
                      style: TextStyle(color: palette.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const CampusIcon(CampusIcons.next),
            ],
          ),
        ),
        const SizedBox(height: CampusGap.large),
      ],
    ];
  }

  // 用设备：扫码与附近门店一行两个等宽（用得多，加高）；最近使用（最多 6 台，新的在前）默认露两台。
  Widget _devicesCard(BuildContext context, String phone) {
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
                Expanded(child: FilledButton.icon(style: tall, onPressed: () => unawaited(_scan(phone)), icon: const CampusIcon(CampusIcons.scan), label: const Text('扫码'))),
                const SizedBox(width: CampusGap.medium),
              ],
              Expanded(
                child: FilledButton.icon(style: tall, onPressed: () => unawaited(_push(PangguaiNearbyPage(service: _service, phone: phone))), icon: const CampusIcon(CampusIcons.store), label: const Text('附近门店')),
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
                    key: ValueKey('${entry.water}-${entry.id}'),
                    // 设备页下单后会换成订单页，push 在换页那一刻就回来了（那时还没付），所以不经 _push 刷新（刷新会插进付款的几步请求中间，11-28 诊断包 TJEHRHFR）；
                    // 设备页或订单页关掉时经 onClose 刷新。
                    onTap: () => unawaited(entry.water ? _push(PangguaiWaterPage(service: _service, phone: phone, hash: entry.id)) : Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => PangguaiDevicePage(service: _service, phone: phone, goodsId: entry.id, onClose: _reloadLater)))),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: CampusGap.small),
                      child: Row(
                        children: [
                          CampusIcon(entry.water ? CampusIcons.water : pangguaiCategoryIcon(entry.category), color: palette.onSurfaceVariant),
                          const SizedBox(width: CampusGap.medium),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(entry.name.isEmpty ? '设备' : entry.name, style: const TextStyle(fontSize: CampusFontSize.body)),
                                if (entry.place.isNotEmpty) Text(entry.place, style: secondary),
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

  Widget _ordersEntry(BuildContext context, String phone) => CampusSurface(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: CampusGap.large),
    onTap: () => unawaited(_push(PangguaiOrdersPage(service: _service, phone: phone))),
    child: Row(
      children: [
        CampusIcon(CampusIcons.orders, size: 28, color: CampusPalette.of(context).primary),
        const SizedBox(width: CampusGap.large),
        const Expanded(child: Text('订单', style: TextStyle(fontSize: CampusFontSize.body))),
        const CampusIcon(CampusIcons.next),
      ],
    ),
  );
}
