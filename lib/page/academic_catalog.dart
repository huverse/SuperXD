import 'package:flutter/widgets.dart';

import 'package:superxd/application/campus_reminders.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/page/grades_page.dart';
import 'package:superxd/page/schedule_page.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/theme/campus_icons.dart';

// 学业页面共用的接线（路由给）：当前账号的网关、代次核对与会话失效、回今天页同步、去登录，以及课前提醒与私信。
class AcademicHost {
  const AcademicHost({required this.gateway, required this.isAccountCurrent, required this.onSessionExpired, required this.requestSync, required this.requestLogin, this.reminders, this.social});
  final CampusGateway gateway;
  final bool Function() isAccountCurrent;
  final Future<void> Function() onSessionExpired;
  // 回到今天页打开同步范围（year 是要同步的学年，为空按今天页默认）。
  final void Function(String? year) requestSync;
  final VoidCallback requestLogin;
  final CampusReminders? reminders;
  final SocialService? social;
}

// 学业功能登记（[人工决策-2026-11-16 17:26:21] 学业功能注册表，用户选定架构推荐方案）：学业页的入口与路由都从这里生成（同百宝箱的 toolboxCatalog），
// 加一项教务数据的页面只在这里登记一次，不用再改学业页与 router.dart；这类数据怎么同步登记在 application/campus_sync.dart 的 campusSyncSteps。
// id 就是路径（/schedule、/grades），发出后不改（同步记录的「查看课表」等按路径打开）。
class AcademicFeature {
  const AcademicFeature({required this.id, required this.title, required this.icon, required this.builder});
  final String id, title;
  final IconData icon;
  final Widget Function(BuildContext context, AcademicHost host) builder;
  String get path => '/$id';
}

final academicFeatures = <AcademicFeature>[
  AcademicFeature(id: 'schedule', title: '课表', icon: CampusIcons.todaySelected, builder: (context, host) => SchedulePage(gateway: host.gateway, reminders: host.reminders, social: host.social, onSync: host.requestSync)),
  AcademicFeature(id: 'grades', title: '成绩', icon: CampusIcons.grades, builder: (context, host) => GradesPage(gateway: host.gateway, isAccountCurrent: host.isAccountCurrent, onLoginRequired: host.requestLogin)),
];
