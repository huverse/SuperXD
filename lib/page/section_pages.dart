import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/page/account_dialogs.dart';
import 'package:superxd/page/third_party_page.dart';
import 'package:superxd/page/appearance_page.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/domain/campus_log.dart';

class ServicePage extends StatelessWidget {
  const ServicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.paddingOf(context).bottom;
    return Column(
      children: [
        const SectionTitleBar(title: '服务'),
        // [人工决策-2026-09-27 20:12:08] 保留课表、成绩，新增百宝箱同级入口；教务无关工具集中注册于百宝箱，不添加未定义服务。
        Expanded(child: CampusScrollFade(bottom: inset, child: ListView(padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + inset), children: [
          for (final service in [(label: '课表', route: '/schedule', icon: CampusIcons.todaySelected), (label: '成绩', route: '/grades', icon: CampusIcons.grades), (label: '百宝箱', route: '/toolbox', icon: CampusIcons.toolbox)]) Padding(padding: const EdgeInsets.only(bottom: 16), child: CampusSurface(
            onTap: () => context.push(service.route), padding: const EdgeInsets.all(20),
            child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 40), child: Row(children: [CampusIcon(service.icon, color: CampusPalette.of(context).primary, size: 28), const SizedBox(width: 20), Expanded(child: Text(service.label, style: TextStyle(fontSize: 16, color: CampusPalette.of(context).onSurface))), CampusIcon(CampusIcons.next, color: CampusPalette.of(context).onSurfaceVariant)])),
          )),
        ]))),
      ],
    );
  }
}

class MinePage extends StatefulWidget {
  const MinePage({super.key, required this.gateway, required this.session, this.social});
  final CampusGateway gateway;
  final AppSession session;
  final SocialService? social;

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  String _name = '';
  bool _busy = false;
  bool _remembered = false;
  bool _loadingAccount = true;

  Future<void> _forget() async {
    final confirmed = await showCampusConfirm(context, title: '关闭记住账号？', message: '将删除此账号保存的自动登录凭据。课表和历史数据保持不变。', action: '关闭并清除', destructive: true);
    if (!mounted || !confirmed) return;
    setState(() => _busy = true);
    try { await showCampusWaiting(context, label: '正在清除记住账号凭据', operation: widget.session.gateway.forgetCredential); if (mounted) setState(() => _remembered = false); }
    catch (error, stack) {
      campusLog('[RememberAccount] errorType=${error.runtimeType}\n$stack');
      if (mounted) await showCampusNotice(context, '自动登录凭据未能清除，请重试。');
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _logout() async {
    final confirmed = await showCampusConfirm(context, title: '退出登录？', message: '清除本机登录态和此账号保存的自动登录凭据，当前课表和自定义修改保留，历史版本按每学期最多100版保留。', action: '退出', destructive: true);
    if (!mounted || !confirmed) return;
    setState(() => _busy = true);
    try {
      await showCampusWaiting(context, label: '正在退出账号', operation: widget.session.gateway.logout);
    } catch (error, stack) {
      campusLog('[MinePage] action=logout errorType=${error.runtimeType}\n$stack');
      if (mounted) await showCampusNotice(context, '退出未完成，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final session = await widget.gateway.restoreSession();
      var remembered = false;
      try { remembered = await widget.session.gateway.isRemembered(); }
      catch (error, stack) { campusLog('[RememberAccount] action=read errorType=${error.runtimeType}\n$stack'); }
      if (!mounted) return;
      _remembered = remembered;
      final name = session.data?.name ?? '';
      final loginId = session.data?.loginId ?? '';
      setState(() => _name = name.isEmpty ? loginId : name);
    } catch (error, stack) { campusLog('[MinePage] action=load errorType=${error.runtimeType}\n$stack'); }
    finally { if (mounted) setState(() => _loadingAccount = false); }
  }

  Widget _settingsCard({required Widget child}) => CampusSurface(padding: const EdgeInsets.all(20), child: child);

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.paddingOf(context).bottom;
    return Column(
      children: [
        const SectionTitleBar(title: '我的'),
        Expanded(child: CampusScrollFade(bottom: inset, child: SingleChildScrollView(padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + inset), child: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _settingsCard(child: Row(children: [
              CircleAvatar(radius: 28, backgroundColor: CampusPalette.of(context).surfaceSelected, child: CampusIcon(CampusIcons.account, color: CampusPalette.of(context).primary, size: 28)),
              const SizedBox(width: 16),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (_loadingAccount) const CampusLoading(label: '读取账号', inline: true) else Text(_name.isEmpty ? '我的账号' : _name, style: Theme.of(context).textTheme.titleLarge),
              ])),
            ])),
            const SizedBox(height: 16),
            CampusSurface(padding: const EdgeInsets.all(20), onTap: () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (context) => AppearancePage(social: widget.social))), child: const ListTile(contentPadding: EdgeInsets.zero, leading: CampusIcon(CampusIcons.services), title: Text('界面'), trailing: CampusIcon(CampusIcons.next))),
            const SizedBox(height: 16),
            // 多行卡片去掉横向内边距，行自带 20 边距：按下变暗时整行铺满卡片宽度，同 iOS 分组列表。
            CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(children: [
              if (_remembered) ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 20), leading: const CampusIcon(CampusIcons.lock), title: const Text('关闭记住账号'), enabled: !_busy, onTap: _forget),
              ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 20), leading: const CampusIcon(CampusIcons.switchAccount), trailing: const CampusIcon(CampusIcons.next), title: const Text('切换账号'), enabled: !_busy, onTap: () => context.push('/switch-account')),
              ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 20), leading: const CampusIcon(CampusIcons.download), trailing: const CampusIcon(CampusIcons.next), title: const Text('导入旧版本数据'), enabled: !_busy, onTap: () => showLegacyImport(context, widget.session)),
              ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 20), leading: const CampusIcon(CampusIcons.logout), title: const Text('退出登录'), enabled: !_busy, onTap: _logout),
              ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 20), leading: const CampusIcon(CampusIcons.info), trailing: const CampusIcon(CampusIcons.next), title: const Text('开源与第三方声明'), enabled: !_busy, onTap: () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (context) => const ThirdPartyPage()))),
            ])),
          ]),
        ))))),
      ],
    );
  }
}

// 底栏根页的大标题顶栏（今天以外的三个分支共用）。
class SectionTitleBar extends StatelessWidget {
  const SectionTitleBar({super.key, required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return CampusTopBar(
      child: SizedBox(
        height: 56 * MediaQuery.textScalerOf(context).scale(14) / 14,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Text(title, style: Theme.of(context).textTheme.headlineMedium),
          ),
        ),
      ),
    );
  }
}
