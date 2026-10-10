import 'package:flutter/material.dart';

import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/short_video/parse_source.dart';
import 'package:superxd/toolbox/short_video/short_video_store.dart';
import 'package:superxd/domain/campus_log.dart';

// 首页最近解析与历史页共用：点击整行重开解析结果，只展示本机保存的链接、标题、类型和来源。
class ParseHistoryTile extends StatelessWidget {
  const ParseHistoryTile({
    super.key,
    required this.row,
    required this.providers,
    required this.onTap,
    this.trailing,
  });
  final Map<String, Object?> row;
  final Map<String, ParseProvider> providers;
  final VoidCallback? onTap;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final title = row['title'] as String;
    final gallery = row['kind'] == 'gallery';
    final providerId = row['provider_id'] as String;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: CampusIcon(gallery ? CampusIcons.images : CampusIcons.video),
      title: Text(
        title.isEmpty ? '作品链接' : title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${gallery ? '图集' : '视频'} · ${providers[providerId]?.source.name ?? providerId} · ${formatCampusTimestamp(DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int, isUtc: true).toIso8601String())}',
      ),
      trailing: trailing ?? const CampusIcon(CampusIcons.next),
      onTap: onTap,
    );
  }
}

class ParseHistoryPage extends StatefulWidget {
  const ParseHistoryPage({
    super.key,
    required this.store,
    required this.providers,
  });
  final ShortVideoStore store;
  final Map<String, ParseProvider> providers;
  @override
  State<ParseHistoryPage> createState() => _ParseHistoryPageState();
}

class _ParseHistoryPageState extends State<ParseHistoryPage> {
  late Future<List<Map<String, Object?>>> _rows = widget.store.history();
  Future<void> _remove([String? id]) async {
    if (!await showCampusConfirm(
      context,
      title: id == null ? '清空解析历史？' : '删除这条历史？',
      message: '下载记录和已保存文件保持不变。',
      action: '删除', destructive: true,
    )) {
      return;
    }
    try {
      if (id == null) {
        await widget.store.clearHistory();
      } else {
        await widget.store.deleteHistory(id);
      }
      if (mounted) {
        setState(() {
          _rows = widget.store.history();
        });
      }
    } catch (error, stack) {
      campusLog(
        '[ParseHistory] action=delete errorType=${error.runtimeType}\n$stack',
      );
      if (mounted) showCampusToast(context, '删除未完成，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('解析历史'),
      leading: IconButton(
        tooltip: '返回',
        onPressed: () => Navigator.pop(context),
        icon: const CampusIcon(CampusIcons.back),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: CampusGlassCircleButton(
            label: '清空历史',
            size: 44,
            onPressed: () => _remove(),
            icon: const CampusIcon(CampusIcons.delete),
          ),
        ),
      ],
    ),
    body: CampusScrollFade(child: SafeArea(
      child: FutureBuilder<List<Map<String, Object?>>>(
        future: _rows,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: TextButton(
                onPressed: () => setState(() {
                  _rows = widget.store.history();
                }),
                child: const Text('读取失败，重试'),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CampusLoading(label: '读取历史'));
          }
          final rows = snapshot.data!;
          if (rows.isEmpty) return const Center(child: Text('暂无解析历史'));
          return ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final row = rows[index];
              return ParseHistoryTile(
                row: row,
                providers: widget.providers,
                onTap: () => Navigator.pop(context, row),
                trailing: IconButton(
                  tooltip: '删除此条',
                  onPressed: () => _remove(row['id'] as String),
                  icon: const CampusIcon(CampusIcons.delete),
                ),
              );
            },
          );
        },
      ),
    )),
  );
}
