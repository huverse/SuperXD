import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_activity_card.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

// 按课程查看：课程列表可搜课名、老师与学校，可置顶常用的课；同名课程（一门课多个班）合并成一项。
// 点进去看这门课的全部签到，进行中与已结束分开两组。
Future<void> showChaoxingCoursePage(BuildContext context, {required ChaoxingSignLauncher launcher}) =>
    Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => ChaoxingCoursePage(launcher: launcher)));

class ChaoxingCoursePage extends StatefulWidget {
  const ChaoxingCoursePage({super.key, required this.launcher});
  final ChaoxingSignLauncher launcher;
  @override
  State<ChaoxingCoursePage> createState() => _ChaoxingCoursePageState();
}

class _ChaoxingCoursePageState extends State<ChaoxingCoursePage> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _togglePin(ChaoxingCourseGroup group) async {
    try {
      await widget.launcher.controller.setGroupPinned(group, pinned: !group.pinned);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=pin errorType=${failure.runtimeType}\n$stack');
      if (mounted) showCampusToast(context, '置顶没保存，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final controller = widget.launcher.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('按课程查看'),
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([controller, _query]),
        builder: (context, _) {
          final groups = controller.courseGroups(query: _query.text);
          // 课程多的账号上百门：先列出每行的构造函数，滚到哪建到哪。
          final rows = <Widget Function()>[
            () => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                controller: _query,
                decoration: const InputDecoration(
                  labelText: '搜索课程、老师或学校',
                  prefixIcon: CampusIcon(CampusIcons.search),
                ),
              ),
            ),
            if (groups.isEmpty)
              () => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      controller.courses.isEmpty ? '暂无课程，确认登录的学习通账号与学校单位是否正确' : '没有找到「${_query.text.trim()}」',
                      style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
                    ),
                  )
            else
              for (final group in groups)
                () => CampusSurface(
                      key: ValueKey(group.name),
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                      onTap: () => Navigator.of(context).push<void>(
                        CampusPageRoute(builder: (_) => ChaoxingCourseDetailPage(launcher: widget.launcher, group: group)),
                      ),
                      child: Row(
                        children: [
                          // 课程封面（学习通课程频道里带的图，没有就不占位）。
                          if (group.courses.first.cover.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.network(group.courses.first.cover, fit: BoxFit.cover, width: 44, height: 44, errorBuilder: (_, _, _) => const SizedBox.square(dimension: 44, child: Center(child: CampusIcon(CampusIcons.course)))),
                              ),
                            ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(group.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface)),
                                const SizedBox(height: 2),
                                DotSeparatedText(
                                  [
                                    if (group.courses.first.teacher.isNotEmpty) group.courses.first.teacher,
                                    if (group.courses.length > 1) '${group.courses.length} 个班',
                                  ].join(' · '),
                                  style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
                                ),
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
        },
      ),
    );
  }
}

class ChaoxingCourseDetailPage extends StatefulWidget {
  const ChaoxingCourseDetailPage({super.key, required this.launcher, required this.group});
  final ChaoxingSignLauncher launcher;
  final ChaoxingCourseGroup group;
  @override
  State<ChaoxingCourseDetailPage> createState() => _ChaoxingCourseDetailPageState();
}

class _ChaoxingCourseDetailPageState extends State<ChaoxingCourseDetailPage> {
  List<ChaoxingActivity>? _activities;
  int _failures = 0;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // 刷新保留旧列表（局部刷新不清空、不丢滚动位置），只在顶栏按钮上原地转。
  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.launcher.controller.groupActivities(widget.group);
      if (!mounted) return;
      setState(() {
        _activities = result.activities;
        _failures = result.failures;
      });
    } on ChaoxingFailure catch (failure) {
      _failed(failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=course_detail errorType=${failure.runtimeType}\n$stack');
      _failed('这门课的签到活动没读到，请稍后重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // 还没有内容时整页显示原因与重试；已有内容时只给提示条，旧列表留着。
  void _failed(String message) {
    if (!mounted) return;
    if (_activities == null) {
      setState(() => _error = message);
    } else {
      showCampusToast(context, message);
    }
  }

  Future<void> _sign(ChaoxingActivity activity) async {
    await widget.launcher.open(context, activity);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final activities = _activities;
    final ongoing = [for (final activity in activities ?? const <ChaoxingActivity>[]) if (activity.ongoing) activity];
    final ended = [for (final activity in activities ?? const <ChaoxingActivity>[]) if (!activity.ongoing) activity];
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.group.name),
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        actions: [ChaoxingRefreshButton(loading: _loading, onRefresh: () => _load())],
      ),
      body: switch ((_error, activities)) {
        (final String message, null) => ChaoxingLoadError(message: message, onRetry: () => _load()),
        (_, null) => const CampusLoading(label: '正在读取签到活动…', network: true),
        _ => _lazyList([
              if (widget.group.courses.length > 1 || _failures > 0)
                () => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    [
                      if (widget.group.courses.length > 1) '这门课有 ${widget.group.courses.length} 个班，签到已合并显示',
                      if (_failures > 0) '$_failures 个班的签到没读到',
                    ].join('；'),
                    style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
                  ),
                ),
              () => ChaoxingSectionTitle('进行中（${ongoing.length}）'),
              if (ongoing.isEmpty)
                () => Text('现在没有进行中的签到', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant))
              else
                for (final activity in ongoing)
                  () => ChaoxingActivityCard(key: ValueKey(activity.activeId), activity: activity, showCourse: false, onSign: () => _sign(activity)),
              () => ChaoxingSectionTitle('已结束（${ended.length}）'),
              if (ended.isEmpty)
                () => Text('还没有已结束的签到', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant))
              else
                for (final activity in ended)
                  () => ChaoxingActivityCard(key: ValueKey(activity.activeId), activity: activity, showCourse: false, onSign: () => _sign(activity)),
            ]),
      },
    );
  }

  // 一门课的签到会越积越多：按需构建，只建屏幕上的那几行。
  Widget _lazyList(List<Widget Function()> rows) => CampusScrollFade(
    child: ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      itemCount: rows.length,
      itemBuilder: (context, index) => rows[index](),
    ),
  );
}
