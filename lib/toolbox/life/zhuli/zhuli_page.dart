import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_animated_list.dart';
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
import 'package:superxd/toolbox/life/zhuli/zhuli_bath_page.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_coupons_page.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_devices.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_login.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_orders_page.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_pick_page.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_recharge_page.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_service.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_vault.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 手机号打码（130****8541），账号卡与切换菜单用。
String zhuliMaskedPhone(String phone) => phone.length == 11 ? '${phone.substring(0, 3)}****${phone.substring(7)}' : phone;

// 住理生活首页：没登录时是登录表单；登录了从上到下是账号卡（⋯ 里切换、添加与退出账号）、有没结束的单时的「正在用水」（点进去关水）、
// 洗浴（学校开了才有）、余额与券余额（只读，下面充值与买券）、优惠券与订单，下拉刷新。排布的人工决策在 build。
// 当前账号的会话恢复不了（要图形验证码、密码改过了）时，在账号卡下面原地重新登录。
class ZhuliPage extends StatefulWidget {
  const ZhuliPage({super.key, required this.runtime, this.scanOnOpen = false});
  final ToolboxRuntime runtime;
  // 从「扫码洗浴」快捷入口打开：登录着就直接开扫码。
  final bool scanOnOpen;
  // 快捷入口 id（桌面上的快捷方式按它找回页面，发出后不改）。
  static const scanShortcut = 'scan';
  @override
  State<ZhuliPage> createState() => _ZhuliPageState();
}

class _ZhuliPageState extends State<ZhuliPage> {
  late ZhuliService _service;
  late Future<void> _ready = _initialize();
  ZhuliVaultState? _state;
  ZhuliSession? _session;
  ZhuliProfile? _profile;
  ({int balance, int count})? _coupons;
  ZhuliConfig? _config;
  ZhuliLastRecord? _last;
  List<ZhuliDeviceEntry> _recent = const [];
  int _favoriteCount = 0;
  // 最近使用默认只露两台，点「全部」展开。
  var _recentOpen = false;
  String? _error;
  String? _relogin;
  // 切换账号后，旧账号晚回来的结果不再写界面。
  var _generation = 0;

  String? get _phone => _state?.current?.phone;

  Future<void> _initialize() async {
    try {
      await widget.runtime.initialize();
      _service = await widget.runtime.service<ZhuliService>(ZhuliService.serviceId);
      _state = await _service.state();
    } catch (error, stack) {
      campusLog('[Zhuli] action=initialize errorType=${error.runtimeType}\n$stack');
      rethrow;
    }
    if (_phone == null) return;
    unawaited(_load());
    if (widget.scanOnOpen) WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_scan()));
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
      // 一起发；Future.wait 原样抛第一个错（会话过期要原样交给 run 去重登）。
      final result = await _service.run(phone, (session) async {
        final values = await Future.wait<Object?>([_service.client.profile(session), _service.couponBalance(session), _service.client.config(session), _service.client.lastRecord(session)]);
        return (session: session, profile: values[0]! as ZhuliProfile, coupons: values[1]! as ({int balance, int count}), config: values[2]! as ZhuliConfig, last: values[3] as ZhuliLastRecord?);
      });
      final lists = await _service.devices.load(phone);
      if (!mounted || generation != _generation) return;
      setState(() {
        _session = result.session;
        _profile = result.profile;
        _coupons = result.coupons;
        _config = result.config;
        _last = result.last;
        _recent = lists.recent;
        _favoriteCount = lists.favorites.length;
      });
    } on ZhuliException catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => error.failure == ZhuliFailure.notSignedIn || error.failure == ZhuliFailure.captchaRequired ? _relogin = error.message : _error = error.message);
    } catch (error, stack) {
      campusLog('[Zhuli] action=load errorType=${error.runtimeType}\n$stack');
      if (mounted && generation == _generation) setState(() => _error = '没读到账户，稍后再试');
    }
  }

  // 第一次登录前取同意：手机号与密码发给住理、密码存本机安全存储（住理是新来源）。
  Future<bool> _consent() async {
    if (await widget.runtime.store.consent(ZhuliService.serviceId, ZhuliService.consentVersion)) return true;
    if (!mounted) return false;
    final agreed = await showCampusConfirm(
      context,
      title: '使用住理生活',
      // 长文案：第三方账号的同意说明，写清发给谁、存什么。
      message: '用你本人的住理生活账号登录：手机号和密码直接发给住理生活（whxinna.com），密码只存在本机的系统安全存储，用来在会话过期时自动重新登录。\n\n'
          '余额、优惠券与订单即查即用，不在本机保存。在这里登录后，别处的住理生活可能要重新登录。\n\n'
          '住理生活是第三方服务，与本应用无关。请遵守它的服务条款，只用本人的账号。',
      action: '同意并登录',
    );
    if (agreed) await widget.runtime.store.grantConsent(ZhuliService.serviceId, ZhuliService.consentVersion);
    return agreed;
  }

  Future<void> _signedIn(String phone) async {
    _state = await _service.state();
    _session = null;
    _profile = null;
    _coupons = null;
    _config = null;
    _last = null;
    _recent = const [];
    if (mounted) await _load();
  }

  // 去一台设备的洗浴页，回来刷新余额与进行中的单。
  Future<void> _openBath(int deviceId) async {
    await Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => ZhuliBathPage(service: _service, phone: _phone!, deviceId: deviceId)));
    if (mounted) unawaited(_load());
  }

  Future<void> _pickThen(Future<int?> Function() pick) async {
    try {
      final deviceId = await pick();
      if (deviceId != null && mounted) await _openBath(deviceId);
    } on ZhuliException catch (error) {
      if (mounted) showCampusToast(context, error.message);
    } catch (error, stack) {
      campusLog('[Zhuli] action=pick_device errorType=${error.runtimeType}\n$stack');
      if (mounted) showCampusToast(context, '没找到设备，稍后再试');
    }
  }

  Future<void> _scan() => _pickThen(() => zhuliScanDevice(context, runtime: widget.runtime, service: _service, phone: _phone!));

  Future<void> _accountMenu(BuildContext anchor) async {
    final state = _state!, phone = _phone!;
    final picked = await showCampusMenu<String>(anchor, items: [
      for (final account in state.accounts)
        if (account.phone != phone) CampusMenuItem(value: account.phone, label: '切换到 ${zhuliMaskedPhone(account.phone)}', icon: CampusIcons.switchAccount),
      if (state.accounts.length < zhuliAccountLimit) const CampusMenuItem(value: '+', label: '添加账号', icon: CampusIcons.add),
      const CampusMenuItem(value: '-', label: '退出这个账号', icon: CampusIcons.logout, destructive: true),
    ]);
    if (picked == null || !mounted) return;
    if (picked == '+') {
      final added = await Navigator.of(context).push<String>(CampusPageRoute(builder: (_) => ZhuliLoginPage(service: _service, consent: _consent)));
      if (added != null) await _signedIn(added);
    } else if (picked == '-') {
      final agreed = await showCampusConfirm(context, title: '退出这个账号', message: '本机删掉 ${zhuliMaskedPhone(phone)} 记着的密码，再用要重新登录。', action: '退出', destructive: true);
      if (!agreed) return;
      await _service.signOut(phone);
      await _signedIn(phone);
    } else {
      await _service.switchTo(picked);
      await _signedIn(picked);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(tooltip: '返回', onPressed: () => context.canPop() ? context.pop() : Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
      title: const Text('住理生活'),
    ),
    body: CampusScrollFade(
      child: SafeArea(
        bottom: false,
        child: FutureBuilder<void>(
          future: _ready,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return CampusLoadError(message: '住理生活暂未就绪', onRetry: () => setState(() {
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
                    child: ZhuliLoginForm(service: _service, consent: _consent, onSignedIn: (phone) => unawaited(_signedIn(phone))),
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
                          child: ZhuliLoginForm(key: ValueKey(phone), service: _service, consent: _consent, phone: phone, reason: reason, onSignedIn: (phone) => unawaited(_signedIn(phone))),
                        )
                      // [人工决策-2026-11-23 12:47:51] 首页按用的多少排（用户截图指出主次不分、常用设备在不显眼处、按钮折行留大块空、最近使用占地方）：
                      // 洗浴提到余额前面；洗浴卡里常用设备与按楼栋选在前、扫码与设备号在后，各一行两个等宽；最近使用默认两台、点「全部」展开；优惠券与订单并成一张卡。
                      else ...[
                        if (_last case final last? when last.running) ...[_runningCard(context, last), const SizedBox(height: CampusGap.large)],
                        if (_config?.bath == true) ...[_bathCard(context, phone), const SizedBox(height: CampusGap.large)],
                        _walletCard(context),
                        const SizedBox(height: CampusGap.large),
                        _entries(context, phone),
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
                Text(_session?.project.isNotEmpty == true ? _session!.project : '住理生活', style: Theme.of(context).textTheme.titleMedium),
                Text(zhuliMaskedPhone(phone), style: TextStyle(color: palette.onSurfaceVariant)),
              ],
            ),
          ),
          Builder(builder: (anchor) => IconButton(tooltip: '账号', onPressed: () => unawaited(_accountMenu(anchor)), icon: const CampusIcon(CampusIcons.manage))),
        ],
      ),
    );
  }

  // 余额与券余额：只读的状态，不用主色。抵扣由住理在消费时自动做（先用券还是先用余额看券自己的设定）。
  Widget _walletCard(BuildContext context) {
    final palette = CampusPalette.of(context);
    final profile = _profile, coupons = _coupons;
    if (profile == null || coupons == null) {
      if (_error case final error?) return CampusLoadError(message: error, onRetry: () => unawaited(_load()));
      return const CampusSurface(child: CampusLoading(label: '正在读取账户', inline: true, network: true, remote: '住理生活'));
    }
    Widget amount(String label, int cents, String? note) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: palette.onSurfaceVariant)),
          const SizedBox(height: CampusGap.tight),
          Text('¥${zhuliYuan(cents)}', style: const TextStyle(fontSize: CampusFontSize.headline, fontWeight: FontWeight.w600)),
          if (note != null) Text(note, style: TextStyle(color: palette.onSurfaceVariant)),
        ],
      ),
    );
    Future<void> open(Widget Function() page) async {
      await Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => page()));
      if (mounted) unawaited(_load());
    }
    final phone = _phone!;
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              amount('余额', profile.balance, profile.frozen > 0 ? '冻结 ¥${zhuliYuan(profile.frozen)}' : null),
              const SizedBox(width: CampusGap.large),
              amount('券余额', coupons.balance, '${coupons.count} 张可用'),
            ],
          ),
          // 充值与买券（学校开着充值入口才有，付款只走支付宝，见 zhuli_pay.dart），一行两个等宽。
          if (_config?.rechargeShown == true) ...[
            const SizedBox(height: CampusGap.large),
            Row(
              children: [
                Expanded(child: FilledButton.icon(onPressed: () => unawaited(open(() => ZhuliRechargePage(service: _service, phone: phone))), icon: const CampusIcon(CampusIcons.wallet), label: const Text('充值'))),
                const SizedBox(width: CampusGap.medium),
                Expanded(child: FilledButton.icon(onPressed: () => unawaited(open(() => ZhuliShopPage(service: _service, phone: phone))), icon: const CampusIcon(CampusIcons.shop), label: const Text('买券'))),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // 有一单没结束（洗着澡退出了页面、重开了应用）：点进去接着显示「关水」。
  Widget _runningCard(BuildContext context, ZhuliLastRecord last) {
    final palette = CampusPalette.of(context);
    return CampusSurface(
      padding: const EdgeInsets.all(20),
      onTap: () => unawaited(_openBath(last.deviceId)),
      child: Row(
        children: [
          CampusIcon(CampusIcons.bath, size: 28, color: palette.primary),
          const SizedBox(width: CampusGap.large),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('正在用水', style: TextStyle(fontSize: CampusFontSize.body, fontWeight: FontWeight.w600)),
                DotSeparatedText('设备号 ${last.deviceId} · ${zhuliShownTime(last.createAt)} 开始', style: TextStyle(color: palette.onSurfaceVariant)),
              ],
            ),
          ),
          const CampusIcon(CampusIcons.next),
        ],
      ),
    );
  }

  Future<void> _favorites(String phone) async {
    await Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => ZhuliFavoritesPage(runtime: widget.runtime, service: _service, phone: phone)));
    if (mounted) unawaited(_load());
  }

  // 洗浴：常用设备与按楼栋选（用得多，普通按钮加高）在前，扫码与设备号（中性按钮）在后，各一行两个等宽；
  // 最近使用（最多 6 台，新的在前）默认露两台，每台写位置与设备号、有哪几路（同房间同名的设备据此分清）。
  Widget _bathCard(BuildContext context, String phone) {
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
              CampusIcon(CampusIcons.bath, size: 28, color: palette.primary),
              const SizedBox(width: CampusGap.large),
              Expanded(child: Text('洗浴', style: Theme.of(context).textTheme.titleMedium)),
            ],
          ),
          const SizedBox(height: CampusGap.large),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: tall,
                  onPressed: () => unawaited(_favorites(phone)),
                  icon: const CampusIcon(CampusIcons.favorite),
                  label: Text(_favoriteCount > 0 ? '常用设备 $_favoriteCount' : '常用设备'),
                ),
              ),
              const SizedBox(width: CampusGap.medium),
              Expanded(
                child: FilledButton.icon(
                  style: tall,
                  onPressed: () => unawaited(_pickThen(() => Navigator.of(context).push<int>(CampusPageRoute(builder: (_) => ZhuliPickPage(service: _service, phone: phone))))),
                  icon: const CampusIcon(CampusIcons.building),
                  label: const Text('按楼栋选'),
                ),
              ),
            ],
          ),
          const SizedBox(height: CampusGap.small),
          Row(
            children: [
              if (widget.runtime.scanQrCode != null) ...[
                Expanded(child: OutlinedButton.icon(onPressed: () => unawaited(_scan()), icon: const CampusIcon(CampusIcons.scan), label: const Text('扫码'))),
                const SizedBox(width: CampusGap.medium),
              ],
              Expanded(child: OutlinedButton.icon(onPressed: () => unawaited(_pickThen(() => zhuliAskDeviceId(context))), icon: const CampusIcon(CampusIcons.deviceNumber), label: const Text('设备号'))),
            ],
          ),
          if (_recent.isNotEmpty) ...[
            const SizedBox(height: CampusGap.large),
            Row(
              children: [
                Expanded(child: Text('最近使用', style: secondary)),
                if (_recent.length > 2)
                  TextButton.icon(
                    onPressed: () => setState(() => _recentOpen = !_recentOpen),
                    icon: CampusIcon(_recentOpen ? CampusIcons.collapse : CampusIcons.expand),
                    label: Text(_recentOpen ? '收起' : '全部 ${_recent.length} 台'),
                  ),
              ],
            ),
            CampusAnimatedColumn(
              children: [
                for (final entry in shown)
                  InkWell(
                    key: ValueKey(entry.id),
                    onTap: () => unawaited(_openBath(entry.id)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: CampusGap.small),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(entry.place.isEmpty ? '设备号 ${entry.id}' : entry.place, style: const TextStyle(fontSize: CampusFontSize.body)),
                                DotSeparatedText(entry.detail, style: secondary),
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

  // 优惠券与订单：一张卡两行。
  Widget _entries(BuildContext context, String phone) {
    Widget row(IconData icon, String label, Widget Function() page) => InkWell(
      onTap: () async {
        await Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => page()));
        if (mounted) unawaited(_load());
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: CampusGap.large),
        child: Row(
          children: [
            CampusIcon(icon, size: 28, color: CampusPalette.of(context).primary),
            const SizedBox(width: CampusGap.large),
            Expanded(child: Text(label, style: const TextStyle(fontSize: CampusFontSize.body))),
            const CampusIcon(CampusIcons.next),
          ],
        ),
      ),
    );
    return CampusSurface(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          row(CampusIcons.coupon, '优惠券', () => ZhuliCouponsPage(service: _service, phone: phone)),
          Divider(height: 1, indent: 20, endIndent: 20, color: CampusPalette.of(context).outline.withValues(alpha: .3)),
          row(CampusIcons.orders, '订单', () => ZhuliOrdersPage(service: _service, phone: phone)),
        ],
      ),
    );
  }

}
