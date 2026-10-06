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
import 'package:superxd/page/about_page.dart';
import 'package:superxd/page/account_page.dart';
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
  bool _loadingAccount = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final session = await widget.gateway.restoreSession();
      if (!mounted) return;
      final name = session.data?.name ?? '';
      final loginId = session.data?.loginId ?? '';
      setState(() => _name = name.isEmpty ? loginId : name);
    } catch (error, stack) { campusLog('[MinePage] action=load errorType=${error.runtimeType}\n$stack'); }
    finally { if (mounted) setState(() => _loadingAccount = false); }
  }

  void _push(Widget page) => Navigator.of(context, rootNavigator: true).push(CampusPageRoute<void>(builder: (context) => page));

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.paddingOf(context).bottom;
    const rowPadding = EdgeInsets.symmetric(horizontal: 20);
    return Column(
      children: [
        const SectionTitleBar(title: '我的'),
        Expanded(child: CampusScrollFade(bottom: inset, child: SingleChildScrollView(padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + inset), child: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // 头像卡进入账号页（同 iOS Apple ID），账号操作都在那里，见 account_page.dart 的人工决策。
            CampusSurface(padding: const EdgeInsets.all(20), onTap: _loadingAccount ? null : () => _push(AccountPage(session: widget.session, name: _name)), child: Row(children: [
              CircleAvatar(radius: 28, backgroundColor: CampusPalette.of(context).surfaceSelected, child: CampusIcon(CampusIcons.account, color: CampusPalette.of(context).primary, size: 28)),
              const SizedBox(width: 16),
              Expanded(child: _loadingAccount ? const CampusLoading(label: '读取账号', inline: true) : Text(_name.isEmpty ? '我的账号' : _name, style: Theme.of(context).textTheme.titleLarge)),
              const CampusIcon(CampusIcons.next),
            ])),
            const SizedBox(height: 16),
            // 多行卡片去掉横向内边距，行自带 20 边距：按下变暗时整行铺满卡片宽度，同 iOS 分组列表。
            CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(children: [
              ListTile(contentPadding: rowPadding, leading: const CampusIcon(CampusIcons.palette), trailing: const CampusIcon(CampusIcons.next), title: const Text('界面'), onTap: () => _push(AppearancePage(social: widget.social))),
              ListTile(contentPadding: rowPadding, leading: const CampusIcon(CampusIcons.info), trailing: const CampusIcon(CampusIcons.next), title: const Text('关于'), onTap: () => _push(const AboutPage())),
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
