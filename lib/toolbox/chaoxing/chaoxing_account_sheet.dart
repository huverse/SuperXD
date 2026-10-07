
import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';

// 多账号管理弹层：改备注名、拖动排序（切换账号仍在账号菜单里做）。
Future<void> showChaoxingAccountSheet(BuildContext context, {required ChaoxingController controller}) =>
    showCampusSheet<void>(context: context, builder: (context) => _ChaoxingAccountSheet(controller: controller));

class _ChaoxingAccountSheet extends StatefulWidget {
  const _ChaoxingAccountSheet({required this.controller});
  final ChaoxingController controller;
  @override
  State<_ChaoxingAccountSheet> createState() => _ChaoxingAccountSheetState();
}

class _ChaoxingAccountSheetState extends State<_ChaoxingAccountSheet> {
  // 拖动期间先在内存里排，松手一次写回。
  late List<ChaoxingAccountRecord> _ordered = widget.controller.accountList;

  Future<void> _rename(ChaoxingAccountRecord record) async {
    final editor = TextEditingController(text: record.label);
    final label = await showCampusDialog<String>(
      context: context,
      builder: (dialog) => CampusGlassDialog(
        title: Text('给 ${record.name} 起备注名'),
        content: TextField(controller: editor, autofocus: true, decoration: const InputDecoration(labelText: '备注名（空则用昵称）')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialog, editor.text.trim()), child: const Text('保存')),
        ],
      ),
    );
    editor.dispose();
    if (label == null || label == record.label || !mounted) return;
    try {
      await widget.controller.renameAccount(record, label);
      setState(() => _ordered = widget.controller.accountList);
    } on ChaoxingFailure catch (failure) {
      if (mounted) await showCampusNotice(context, failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=account_rename errorType=${failure.runtimeType}\n$stack');
      if (mounted) await showCampusNotice(context, '改名没完成，请重试');
    }
  }

  Future<void> _persist() async {
    try {
      await widget.controller.reorderAccounts(_ordered);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=account_reorder errorType=${failure.runtimeType}\n$stack');
      if (mounted) await showCampusNotice(context, '排序没保存，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return CampusSheetPanel(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 12, 4),
            child: Row(
              children: [
                Expanded(child: Text('账号管理', style: Theme.of(context).textTheme.titleLarge)),
                IconButton(tooltip: '关闭', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.close)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('拖动排序（下次登录按这个顺序）；点备注图标改名。', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
          ),
          Flexible(
            child: ReorderableListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 12, 20),
              itemCount: _ordered.length,
              onReorderItem: (oldIndex, newIndex) {
                setState(() => _ordered.insert(newIndex, _ordered.removeAt(oldIndex)));
                _persist();
              },
              itemBuilder: (context, index) {
                final record = _ordered[index];
                return CampusSurface(
                  key: ValueKey(record.phoneNumber),
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(8),
                  radius: 16,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(record.displayName, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: palette.onSurface)),
                            DotSeparatedText(
                              [record.phoneNumber, record.isOtherUser ? '对方账号' : '本人账号', if (record.label.isNotEmpty) record.name].join(' · '),
                              style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      IconButton(tooltip: '改备注名', onPressed: () => _rename(record), icon: const CampusIcon(CampusIcons.edit)),
                      ReorderableDragStartListener(
                        index: index,
                        child: IconButton(tooltip: '拖动排序', onPressed: () {}, icon: const CampusIcon(CampusIcons.dragHandle)),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
