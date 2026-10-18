import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/page/account_dialogs.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 账号卡副标题：学号与班级（同微信“我”页的微信号），多账号时好区分；姓名未知时标题已是学号，只写班级。
// [人工决策-2026-10-18 15:18:41] 账号卡加学号 · 班级（用户从走查清单选定）。
String accountDetail(SessionView? account) => account == null ? '' : [if (account.name.isNotEmpty) account.loginId, account.className].where((part) => part.isNotEmpty).join(' · ');

// 账号卡标题：姓名加次要色副标题，“我的”页与账号页共用。
class AccountTitle extends StatelessWidget {
  const AccountTitle({super.key, required this.name, required this.detail});
  final String name;
  final String detail;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
    Text(name.isEmpty ? '我的账号' : name, style: Theme.of(context).textTheme.titleLarge),
    if (detail.isNotEmpty) ...[const SizedBox(height: 2), DotSeparatedText(detail, style: TextStyle(fontSize: 14, color: CampusPalette.of(context).onSurfaceVariant))],
  ]);
}

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

  // 关闭后重新开启：输密码，后台登录一次核对（要验证码就弹），通过才保存；只核对不切换，停在本页（人工决策见 AccountGateway.rememberWithPassword）。
  Future<void> _remember() async {
    final password = await askRememberPassword(context);
    if (!mounted || password == null) return;
    final gateway = widget.session.gateway;
    setState(() => _busy = true);
    try {
      final result = await showCampusWaiting(context, label: '正在核对密码', operation: () => gateway.rememberWithPassword(password));
      if (!mounted) return;
      if (result.needsInput == 'captcha' && result.data?.captcha != null) {
        final error = await showCampusDialog<String>(context: context, barrierDismissible: false, builder: (context) => LoginCaptchaDialog(gateway: gateway, captcha: result.data!.captcha!));
        if (!mounted) return;
        if (error != null) return await showCampusNotice(context, error);
      } else if (!result.ok) {
        return await showCampusNotice(context, result.error?.message ?? '记住账号未开启，请重试。');
      }
      // 验证码弹窗取消也是空结果，以安全存储里有没有为准。
      final remembered = await gateway.isRemembered();
      if (!mounted) return;
      setState(() => _remembered = remembered);
      if (remembered) showCampusToast(context, '已开启记住账号');
    } catch (error, stack) {
      campusLog('[RememberAccount] action=enable errorType=${error.runtimeType}\n$stack');
      if (mounted) await showCampusNotice(context, '记住账号未开启，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    final confirmed = await showCampusConfirm(context, title: '退出登录？', message: '清除本机登录态和此账号保存的自动登录凭据，当前课表和自定义修改保留。', action: '退出', destructive: true);
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
            Expanded(child: AccountTitle(name: widget.name, detail: accountDetail(widget.session.gateway.activeSession))),
          ])),
          const SizedBox(height: 16),
          // 多行卡片去掉横向内边距，行自带 20 边距：按下变暗时整行铺满卡片宽度，同 iOS 分组列表。
          CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(children: [
            // 记住账号：开着时点按关闭（删凭据）；关着时点按输密码核对后开启。
            ListTile(
              contentPadding: rowPadding, leading: const CampusIcon(CampusIcons.lock), title: const Text('记住账号'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(switch (remembered) { null => '', true => '已开启', false => '未开启' }, style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant)),
                if (remembered != null) ...[const SizedBox(width: 4), const CampusIcon(CampusIcons.next)],
              ]),
              enabled: !_busy, onTap: switch (remembered) { null => null, true => _forget, false => _remember },
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
