import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/page/account_dialogs.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// [人工决策-2026-10-05 01:28:53] 账号操作收进“我的”头像卡进入的账号页（同 iOS Apple ID）：记住账号、切换账号、导入旧版本数据一组，退出登录单独一组、红字放最底。
class AccountPage extends StatefulWidget {
  const AccountPage({super.key, required this.session, required this.name});
  final AppSession session;
  final String name;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  bool _busy = false;
  bool? _remembered;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var remembered = false;
    try { remembered = await widget.session.gateway.isRemembered(); }
    catch (error, stack) { campusLog('[RememberAccount] action=read errorType=${error.runtimeType}\n$stack'); }
    if (mounted) setState(() => _remembered = remembered);
  }

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
      campusLog('[AccountPage] action=logout errorType=${error.runtimeType}\n$stack');
      if (mounted) await showCampusNotice(context, '退出未完成，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    final remembered = _remembered;
    const rowPadding = EdgeInsets.symmetric(horizontal: 20);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('账号'),
      ),
      body: CampusScrollFade(child: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          CampusSurface(padding: const EdgeInsets.all(20), child: Row(children: [
            CircleAvatar(radius: 28, backgroundColor: colors.surfaceSelected, child: CampusIcon(CampusIcons.account, color: colors.primary, size: 28)),
            const SizedBox(width: 16),
            Expanded(child: Text(widget.name.isEmpty ? '我的账号' : widget.name, style: Theme.of(context).textTheme.titleLarge)),
          ])),
          const SizedBox(height: 16),
          // 多行卡片去掉横向内边距，行自带 20 边距：按下变暗时整行铺满卡片宽度，同 iOS 分组列表。
          CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(children: [
            // 记住账号只能在登录时开启（要密码），这里只能关闭；未开启时只读显示状态。
            ListTile(
              contentPadding: rowPadding, leading: const CampusIcon(CampusIcons.lock), title: const Text('记住账号'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(switch (remembered) { null => '', true => '已开启', false => '未开启' }, style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant)),
                if (remembered == true) ...[const SizedBox(width: 4), const CampusIcon(CampusIcons.next)],
              ]),
              // 未开启时不可点但不置灰：这是状态，不是被禁用的操作。
              enabled: !_busy, onTap: remembered == true ? _forget : null,
            ),
            ListTile(contentPadding: rowPadding, leading: const CampusIcon(CampusIcons.switchAccount), trailing: const CampusIcon(CampusIcons.next), title: const Text('切换账号'), enabled: !_busy, onTap: () => context.push('/switch-account')),
            ListTile(contentPadding: rowPadding, leading: const CampusIcon(CampusIcons.download), trailing: const CampusIcon(CampusIcons.next), title: const Text('导入旧版本数据'), enabled: !_busy, onTap: () => showLegacyImport(context, widget.session)),
          ])),
          const SizedBox(height: 16),
          CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: ListTile(
            contentPadding: rowPadding, enabled: !_busy, onTap: _logout,
            title: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              CampusIcon(CampusIcons.logout, color: colors.danger), const SizedBox(width: 8),
              Text('退出登录', style: TextStyle(color: colors.danger)),
            ]),
          )),
        ],
      ))))),
    );
  }
}
