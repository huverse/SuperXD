import 'package:flutter/material.dart';

import 'package:superxd/local/campus_clock.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/toolbox_store.dart';

class ParseHistoryPage extends StatefulWidget {
  const ParseHistoryPage({super.key, required this.store});
  final ToolboxStore store;
  @override
  State<ParseHistoryPage> createState() => _ParseHistoryPageState();
}

class _ParseHistoryPageState extends State<ParseHistoryPage> {
  late Future<List<Map<String, Object?>>> _rows = widget.store.history();
  Future<void> _remove([String? id]) async {
    final agreed = await showCampusDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(id == null ? '清空解析历史？' : '删除这条历史？'),
        content: const Text('下载记录和已保存文件保持不变。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (agreed != true) return;
    try {
      if (id == null) {
        await widget.store.clearHistory();
      } else {
        await widget.store.deleteHistory(id);
      }
      if (mounted) setState(() => _rows = widget.store.history());
    } catch (error, stack) {
      debugPrint(
        '[ParseHistory] action=delete errorType=${error.runtimeType}\n$stack',
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('删除未完成，请重试')));
      }
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
        IconButton(
          tooltip: '清空历史',
          onPressed: () => _remove(),
          icon: const CampusIcon(CampusIcons.delete),
        ),
      ],
    ),
    body: SafeArea(
      child: FutureBuilder<List<Map<String, Object?>>>(
        future: _rows,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: TextButton(
                onPressed: () => setState(() => _rows = widget.store.history()),
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
              return ListTile(
                title: Text(
                  (row['title'] as String).isEmpty
                      ? '作品链接'
                      : row['title'] as String,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${row['provider_id']} · ${formatCampusTimestamp(DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int, isUtc: true).toIso8601String())}',
                ),
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
    ),
  );
}
