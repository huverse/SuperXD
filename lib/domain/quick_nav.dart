// 侧栏的常用与最近（设备级，人工决策见 page/side_drawer.dart 的 SideDrawerPanel）：常用是用户勾选并排好的入口，最近是最近进过的几个入口。
// 入口 id 由组合根的入口目录给（有路由的就是路径，发出后不改）；这里只管规则，不认识具体页面。

// 最近最多记几个。
const quickRecentLimit = 5;
// 常用最多记几个（入口目录本身也就几十个，这是读本机文件时的上限）。
const quickPinnedLimit = 64;

class QuickNavPrefs {
  const QuickNavPrefs({this.pinned, this.recent = const []});
  // 用户排好的常用；为空表示还没编辑过，用入口目录给的默认（目录以后加了默认项也跟着变）。
  final List<String>? pinned;
  // 最近进过的入口，最新的在前。
  final List<String> recent;

  QuickNavPrefs visited(String id) => QuickNavPrefs(pinned: pinned, recent: [id, for (final item in recent) if (item != id) item].take(quickRecentLimit).toList());

  QuickNavPrefs pinning(List<String> ids) => QuickNavPrefs(pinned: ids.where(_validId).toSet().take(quickPinnedLimit).toList(), recent: recent);

  Map<String, Object?> toJson() => {'pinned': ?pinned, 'recent': recent};

  // 本机文件是外部输入：不是对象当没有，坏了的项丢掉。
  static QuickNavPrefs fromJson(Object? json) {
    if (json is! Map) return const QuickNavPrefs();
    List<String>? ids(Object? value, int limit) => value is List ? value.whereType<String>().where(_validId).toSet().take(limit).toList() : null;
    return QuickNavPrefs(pinned: ids(json['pinned'], quickPinnedLimit), recent: ids(json['recent'], quickRecentLimit) ?? const []);
  }
}

bool _validId(String id) => id.isNotEmpty && id.length <= 128;

// 常用与最近的本机记录（实现在 local/quick_nav_memory.dart）。
abstract interface class QuickNavMemory {
  QuickNavPrefs get prefs;
  Future<void> save(QuickNavPrefs prefs);
}

// 搜索排序：名字以关键字开头的最前，名字里有的其次，只有别名里有的再次；都没有为空。不分大小写，忽略首尾空白。
int? quickNavRank(String query, String title, List<String> keywords) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return null;
  final name = title.toLowerCase();
  if (name.startsWith(needle)) return 0;
  if (name.contains(needle)) return 1;
  return keywords.any((keyword) => keyword.toLowerCase().contains(needle)) ? 2 : null;
}
