import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/application/leisure.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// [人工决策-2026-11-15 23:40:38] 游乐场与积分的设置页（规则见 domain/leisure.dart）：「我的」里那一行进来，上面一组开关，
// 最底下单独一组红字「删除数据」（先确认），同账号页的退出登录、iOS 设置里的删除 App；一行只做一件事，开关不与⋯挤一行。
class LeisurePage extends StatelessWidget {
  const LeisurePage({super.key, required this.leisure, this.appAccounts});

  final Leisure leisure;
  final AppAccounts? appAccounts;

  // 删除数据：先确认写明删哪些；登录着应用账号时连服务器上的一起删，没删成本机也不动。
  Future<void> _delete(BuildContext context) async {
    final username = appAccounts?.username;
    // 长文案：删除确认要写清删哪些数据、删了不能恢复。
    final message = leisure.signedIn ? '本机的游戏成绩与笔记，以及应用账号 $username 在服务器上的积分、挑战成绩与解锁记录都会删除，不能恢复。'
        // 长文案：没登录应用账号时要说明服务器上的积分不在这次删除里。
        : '本机的游戏成绩与笔记会删除，不能恢复；服务器上的积分要登录应用账号后才能删。';
    final confirmed = await showCampusConfirm(context, title: '删除游乐场与积分的数据？', message: message, action: '删除', destructive: true);
    if (!context.mounted || !confirmed) return;
    String? failure;
    await showCampusWaiting(context, label: '正在删除', operation: () async {
      try {
        await leisure.deleteData();
      } on ChallengeException catch (error) {
        failure = error.message;
      }
    });
    if (!context.mounted) return;
    if (failure case final message?) return showCampusNotice(context, message);
    showCampusToast(context, '已删除');
  }

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    const rowPadding = EdgeInsets.symmetric(horizontal: 20);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('游乐场与积分'),
      ),
      body: CampusScrollFade(child: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: ListenableBuilder(listenable: leisure, builder: (context, _) => CampusSwitchTile(
            contentPadding: rowPadding,
            leading: const CampusIcon(CampusIcons.playground),
            title: const Text('游乐场与积分'),
            value: leisure.enabled,
            onChanged: (value) => unawaited(leisure.setEnabled(value)),
          ))),
          const SizedBox(height: 16),
          CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: ListTile(
            contentPadding: rowPadding, onTap: () => unawaited(_delete(context)),
            title: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              CampusIcon(CampusIcons.delete, color: colors.danger), const SizedBox(width: 8),
              Text('删除数据', style: TextStyle(color: colors.danger)),
            ]),
          )),
        ],
      ))))),
    );
  }
}
