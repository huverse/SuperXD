import 'package:flutter/widgets.dart';

// 侧栏与搜索里的一个入口（页面或功能）：由组合根 router.dart 从各登记表汇总（学业、百宝箱、游乐场与几个设置页），页面层不认识具体功能。
class QuickEntry {
  const QuickEntry({required this.id, required this.title, required this.icon, required this.group, required this.open, this.keywords = const []});
  // 有路由的就是路径，没有的是固定名字；常用与最近按它记，发出后不改。
  final String id;
  final String title;
  final IconData icon;
  // 分组名（学业、百宝箱、游乐场、设置），搜索时写在名字后面、空查询时按它分组。
  final String group;
  // 搜索用的别名（「洗澡」找到住理生活）。
  final List<String> keywords;
  final void Function(BuildContext context) open;
}

// 入口目录：此刻看得见的入口（按登记顺序，解锁、灰度变了会变，changes 里任一个发出就重读）与还没编辑过常用时的默认几个。
class QuickCatalog {
  const QuickCatalog({required this.entries, required this.defaults, this.changes = const []});
  final List<QuickEntry> Function() entries;
  final List<String> defaults;
  final List<Stream<void>> changes;
}
