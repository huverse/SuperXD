import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/application/app_health.dart';
import 'package:superxd/application/app_updates.dart';
import 'package:superxd/application/developer_notes.dart';
import 'package:superxd/domain/painting.dart';
import 'package:superxd/local/developer_settings.dart';
import 'package:superxd/local/diagnostic_log.dart';
import 'package:superxd/page/about_page.dart';
import 'package:superxd/page/account_page.dart';
import 'package:superxd/page/appearance_page.dart';
import 'package:superxd/page/developer_notes_page.dart';
import 'package:superxd/theme/glass_panel.dart';

class ServicePage extends StatelessWidget {
  const ServicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.paddingOf(context).bottom;
    return Column(
      children: [
        const SectionTitleBar(title: '服务'),
        // [人工决策-2026-09-27 20:12:08] 新增百宝箱同级入口；教务无关工具集中注册于百宝箱，不添加未定义服务（「保留课表、成绩」两项由下一条取代）。
        // [人工决策-2026-11-16 13:35:18] 课表、成绩合成一项「学业」（见 academic_page.dart），以后教务相关的都放进去。
        // [人工决策-2026-11-12 21:00:20] 用户要求在服务页新增「游乐场」同级入口（小游戏属娱乐，不算工具，不进百宝箱），排在百宝箱后面。
        // 11-16 起游乐场一直列着（娱乐与积分的开关并进联网偏好，人工决策见 domain/leisure.dart）。
        Expanded(child: CampusScrollFade(bottom: inset, child: Builder(builder: (context) => ListView(padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + inset), children: [
          for (final service in [(label: '学业', route: '/academic', icon: CampusIcons.academic), (label: '百宝箱', route: '/toolbox', icon: CampusIcons.toolbox), (label: '游乐场', route: '/playground', icon: CampusIcons.playground)]) Padding(padding: const EdgeInsets.only(bottom: 16), child: CampusSurface(
            onTap: () => context.push(service.route), padding: const EdgeInsets.all(20),
            child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 40), child: Row(children: [CampusIcon(service.icon, color: CampusPalette.of(context).primary, size: 28), const SizedBox(width: 20), Expanded(child: Text(service.label, style: TextStyle(fontSize: 16, color: CampusPalette.of(context).onSurface))), CampusIcon(CampusIcons.next, color: CampusPalette.of(context).onSurfaceVariant)])),
          )),
        ])))),
      ],
    );
  }
}

class MinePage extends StatelessWidget {
  const MinePage({super.key, required this.session, this.updates, this.health, this.developer, this.logs, this.paintings, this.notes, this.appAccounts, this.openAppAccount});
  final AppSession session;
  // 应用账号（设备级，与教务各管各的）；没配中转时为空，不显示那一行。
  final AppAccounts? appAccounts;
  // 推入应用账号页（组合根给，开发者的话与红包也在那页）。
  final void Function(BuildContext context)? openAppAccount;
  // 开发者的话（设备级）：有没读的信时应用账号一行的行尾一个小圆点；为空（没配中转）时没有。
  final DeveloperNotes? notes;
  final AppUpdates? updates;
  final AppHealth? health;
  final DeveloperSettings? developer;
  final DiagnosticLog? logs;
  final PaintingGallery? paintings;

  void _push(BuildContext context, Widget page) => Navigator.of(context, rootNavigator: true).push(CampusPageRoute<void>(builder: (context) => page));

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.paddingOf(context).bottom;
    const rowPadding = EdgeInsets.symmetric(horizontal: 20);
    return Column(
      children: [
        const SectionTitleBar(title: '我的'),
        // 内容不满一屏也能拖动回弹（同另外三个底栏页的 ListView；SingleChildScrollView 默认内容放得下就拖不动，11-24 用户报「我的」滑不动）。
        Expanded(child: CampusScrollFade(bottom: inset, child: SingleChildScrollView(physics: const AlwaysScrollableScrollPhysics(), padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + inset), child: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // 头像卡进入教务账号页（同 iOS Apple ID），教务账号的操作都在那里；卡上只写姓名，学号与班级在账号页，见 account_page.dart 的人工决策。
            // 直接读当前会话：姓名要等同步课表才知道（之前显示学号），网关学到后会通知，这里跟着刷新。
            ListenableBuilder(listenable: session, builder: (context, _) {
              final account = session.gateway.activeSession;
              final name = account == null ? '' : account.name.isEmpty ? account.loginId : account.name;
              return CampusSurface(padding: const EdgeInsets.all(20), onTap: () => _push(context, AccountPage(session: session, name: name)), child: Row(children: [
                CircleAvatar(radius: 28, backgroundColor: CampusPalette.of(context).surfaceSelected, child: CampusIcon(CampusIcons.account, color: CampusPalette.of(context).primary, size: 28)),
                const SizedBox(width: 16),
                Expanded(child: AccountTitle(name: name)),
                // 箭头同下面各行（ListTile 给的次要色）。
                CampusIcon(CampusIcons.next, color: CampusPalette.of(context).onSurfaceVariant),
              ]));
            }),
            const SizedBox(height: 16),
            // 多行卡片去掉横向内边距，行自带 20 边距：按下变暗时整行铺满卡片宽度，同 iOS 分组列表。
            CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(children: [
              // [人工决策-2026-11-19 13:09:34] 「我的」只剩头像卡、应用账号、界面、关于（用户嫌入口太多太杂，选「合成一行应用账号」，
              // 取代 11-17 21:24:25「我的页加应用账号一行、教务账号页那一行照留」与 11-13 23:07:30「教务账号页单独一组应用账号」）：
              // 应用账号只这一个常驻入口，开发者的话与节日红包挪进应用账号页最上面一组；有没读的信时这一行行尾一个小圆点（底栏「我的」同时有一个）。
              // 同一次选定：自动同步设置只留学业页一处（今天页与学业页的同步范围弹窗里不再给入口），检查到的同类重复入口一并收掉。
              if ((appAccounts, openAppAccount) case (final appAccounts?, final open?)) AppAccountRow(appAccounts: appAccounts, notes: notes, padding: rowPadding, onTap: () => open(context)),
              ListTile(contentPadding: rowPadding, leading: const CampusIcon(CampusIcons.palette), trailing: const CampusIcon(CampusIcons.next), title: const Text('界面'), onTap: () => _push(context, const AppearancePage())),
              ListTile(contentPadding: rowPadding, leading: const CampusIcon(CampusIcons.info), trailing: const CampusIcon(CampusIcons.next), title: const Text('关于'), onTap: () => _push(context, AboutPage(updates: updates, health: health, developer: developer, logs: logs, paintings: paintings))),
            ])),
          ]),
        ))))),
      ],
    );
  }
}

// 「应用账号」一行（人工决策见 MinePage 的 11-19 那条）：名字在左、不折行，用户名或「未登录」靠右，太长时省略（同 iOS 设置里的值），
// 有没读的开发者的话时行尾「›」前一个小圆点。11-17 设计审查：以前用户名放在 trailing，长用户名在窄屏大字号下把「应用账号」挤成「应用账 / 号」。
class AppAccountRow extends StatelessWidget {
  const AppAccountRow({super.key, required this.appAccounts, required this.onTap, required this.padding, this.notes});
  final AppAccounts appAccounts;
  final DeveloperNotes? notes;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: Listenable.merge([appAccounts, ?notes]), builder: (context, _) => ListTile(
    contentPadding: padding, leading: const CampusIcon(CampusIcons.mainAccount),
    title: Row(children: [
      const Text('应用账号', maxLines: 1, softWrap: false),
      const SizedBox(width: CampusGap.medium),
      Expanded(child: Text(!appAccounts.loaded ? '' : appAccounts.username ?? '未登录', maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.end, style: TextStyle(fontSize: CampusFontSize.secondary, color: CampusPalette.of(context).onSurfaceVariant))),
    ]),
    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
      if (notes?.unread ?? false) ...[Semantics(label: '有新的', child: UnreadDot(color: CampusPalette.of(context).dangerFill)), const SizedBox(width: CampusGap.medium)],
      const CampusIcon(CampusIcons.next),
    ]),
    enabled: appAccounts.loaded,
    onTap: onTap,
  ));
}

// 底栏根页的大标题顶栏（今天以外的三个分支共用）。
class SectionTitleBar extends StatelessWidget {
  const SectionTitleBar({super.key, required this.title, this.trailing});
  final String title;
  // 右侧的顶栏操作（玻璃圆钮），消息页的「面对面」用。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    // 至少 56 高（同 AppBar），字号大到标题一行放不下时按标题实际的高长；不再按 56 × 字号倍数，圆钮与留白不跟着放大（见 shell_page.dart 底栏 11-25 的人工决策）。
    return CampusTopBar(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Text(title, style: Theme.of(context).textTheme.headlineMedium),
            )),
            if (trailing != null) Padding(padding: const EdgeInsets.only(right: 12), child: trailing),
          ]),
        ),
      ),
    );
  }
}
