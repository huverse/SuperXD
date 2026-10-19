import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_search_field.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_activity_card.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_im.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

// 群聊里的签到：有些签到只发在班级群里，课表那边的活动列表看不到。
// [人工决策-2026-10-15 19:07:26] 先列群（可搜群名、置顶，同名群合并成一项），点进某一项才拉那几个群的消息（同参考项目）；
// 以前一打开就并发拉全部群（最多 200 个）的漫游，工作量随全部群数增长、一下子打出几百个请求。
Future<void> showChaoxingGroupPage(BuildContext context, {required ChaoxingSignLauncher launcher}) =>
    Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => ChaoxingGroupPage(launcher: launcher)));

class ChaoxingGroupPage extends StatefulWidget {
  const ChaoxingGroupPage({super.key, required this.launcher});
  final ChaoxingSignLauncher launcher;
  @override
  State<ChaoxingGroupPage> createState() => _ChaoxingGroupPageState();
}

class _ChaoxingGroupPageState extends State<ChaoxingGroupPage> {
  final _query = TextEditingController();
  List<ChaoxingImGroup>? _chats;
  Set<String> _pinned = const {};
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  // 刷新保留旧列表（不清空、不丢滚动位置），只在顶栏按钮上原地转。
  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.launcher.controller.loadChats();
      if (!mounted) return;
      setState(() {
        _chats = result.chats;
        _pinned = result.pinned;
      });
    } on ChaoxingFailure catch (failure) {
      _failed(failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=chats errorType=${failure.runtimeType}\n$stack');
      _failed('群聊没读到，请稍后重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // 还没有内容时整页显示原因与重试；已有内容时只给提示条，旧列表留着。
  void _failed(String message) {
    if (!mounted) return;
    if (_chats == null) {
      setState(() => _error = message);
    } else {
      showCampusToast(context, message);
    }
  }

  Future<void> _togglePin(ChaoxingChatGroup group) async {
    try {
      final pinned = await widget.launcher.controller.setChatPinned(group, pinned: !group.pinned);
      if (mounted) setState(() => _pinned = pinned);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=chat_pin errorType=${failure.runtimeType}\n$stack');
      if (mounted) showCampusToast(context, '置顶没保存，请重试');
    }
  }

  void _open(ChaoxingChatGroup group) => Navigator.of(context).push<void>(
    CampusPageRoute(
      builder: (_) => ChaoxingActivitiesPage(
        launcher: widget.launcher,
        title: group.name,
        load: () => widget.launcher.controller.chatActivities(group),
        notes: (failures) => [
          if (group.groups.length > 1) '同名的有 ${group.groups.length} 个群，签到已合并显示',
          if (failures > 0) '$failures 场签到没读到',
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final chats = _chats;
    return Scaffold(
      appBar: AppBar(
        title: const Text('群聊里的签到'),
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        // 首次读取时页面中间已经在转，顶栏按钮不再同时转（不让两段加载动画同时演），只是暂不可点。
        actions: [ChaoxingRefreshButton(loading: _loading && chats != null, onRefresh: _loading ? null : () => _load())],
      ),
      body: switch ((_error, chats)) {
        (final String message, null) => CampusLoadError(message: message, onRetry: () => _load()),
        (_, null) => const CampusLoading(label: '正在读取群聊…', network: true, remote: '学习通'),
        (_, final List<ChaoxingImGroup> items) => ListenableBuilder(listenable: _query, builder: (context, _) => _list(items)),
      },
    );
  }

  Widget _list(List<ChaoxingImGroup> chats) {
    final palette = CampusPalette.of(context);
    final groups = chaoxingChatGroups(chats, _pinned, query: _query.text);
    // 群多的账号有上百个：先列出每行的构造函数，滚到哪建到哪。
    final rows = <Widget Function()>[
      () => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: CampusSearchField(controller: _query, hint: '搜索群聊'),
      ),
      if (groups.isEmpty)
        () => Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                chats.isEmpty ? '没有加入的群聊' : '没有找到「${_query.text.trim()}」',
                style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
              ),
            )
      else
        for (final group in groups)
          () => CampusSurface(
                key: ValueKey(group.name),
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                onTap: () => _open(group),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(group.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface)),
                          if (group.groups.length > 1)
                            Text('${group.groups.length} 个群', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: group.pinned ? '取消置顶' : '置顶',
                      onPressed: () => _togglePin(group),
                      icon: CampusIcon(group.pinned ? CampusIcons.unpin : CampusIcons.pin),
                    ),
                    const CampusIcon(CampusIcons.next),
                  ],
                ),
              ),
    ];
    return CampusScrollFade(
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        itemCount: rows.length,
        itemBuilder: (context, index) => rows[index](),
      ),
    );
  }
}
