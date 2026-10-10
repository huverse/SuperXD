
import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
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
  // [人工决策-2026-10-08 19:36:24] 本人固定排第一、不可拖；代签账号只在自己那一段里拖动排序。
  // 库里的排序本来就是「本人在前」，界面与存储同一口径（以前能把代签账号拖到本人前面，松手又跳回去）；
  // 启动时打开排第一的账号，本人在前也保证打开工具进的是自己的账号。
  // 拖动期间先在内存里排（拷一份，不直接改 controller 的状态），松手一次写回。
  late List<ChaoxingAccountRecord> _own = _ownOf(widget.controller.accountList);
  late List<ChaoxingAccountRecord> _delegated = _delegatedOf(widget.controller.accountList);

  static List<ChaoxingAccountRecord> _ownOf(List<ChaoxingAccountRecord> records) => [for (final record in records) if (!record.isOtherUser) record];
  static List<ChaoxingAccountRecord> _delegatedOf(List<ChaoxingAccountRecord> records) => [for (final record in records) if (record.isOtherUser) record];

  void _reload() {
    _own = _ownOf(widget.controller.accountList);
    _delegated = _delegatedOf(widget.controller.accountList);
  }

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
      if (mounted) setState(_reload);
    } on ChaoxingFailure catch (failure) {
      if (mounted) await showCampusNotice(context, failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=account_rename errorType=${failure.runtimeType}\n$stack');
      if (mounted) await showCampusNotice(context, '改名没完成，请重试');
    }
  }

  // [人工决策-2026-10-09 20:32:45] 账号管理每行右侧⋯：改备注名、删除（警示色并确认），删代签账号不用先切过去；
  // 整行点按改备注名。同课程管理卡片的规范，用户选定。
  Future<void> _menu(BuildContext anchor, ChaoxingAccountRecord record) async {
    final action = await showCampusMenu<String>(anchor, items: const [
      CampusMenuItem(value: 'rename', label: '改备注名', icon: CampusIcons.edit),
      CampusMenuItem(value: 'remove', label: '删除', icon: CampusIcons.delete, destructive: true),
    ]);
    if (!mounted) return;
    if (action == 'rename') await _rename(record);
    if (action == 'remove') await _remove(record);
  }

  Future<void> _remove(ChaoxingAccountRecord record) async {
    final agreed = await showCampusConfirm(
      context,
      title: '删除${record.name}？',
      message: '会删除本机保存的账号、密码与人脸照片记录，不影响学习通上的数据。',
      action: '删除',
      destructive: true,
    );
    if (!agreed || !mounted) return;
    await widget.controller.removeAccount(record);
    if (!mounted) return;
    // 删光了就回到登录页，弹层没有可管的了。
    if (widget.controller.accountList.isEmpty) {
      Navigator.pop(context);
      return;
    }
    setState(_reload);
  }

  Future<void> _persist() async {
    try {
      await widget.controller.reorderAccounts([..._own, ..._delegated]);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=account_reorder errorType=${failure.runtimeType}\n$stack');
      if (mounted) await showCampusNotice(context, '排序没保存，请重试');
    }
  }

  Widget _tile(CampusPalette palette, ChaoxingAccountRecord record, {int? dragIndex}) => CampusSurface(
    key: ValueKey(record.phoneNumber),
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
    radius: 16,
    onTap: () => _rename(record),
    child: Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(record.displayName, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface)),
                DotSeparatedText(
                  [record.phoneNumber, record.ownerLabel, if (record.label.isNotEmpty) record.name].join(' · '),
                  style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        Builder(
          builder: (anchor) => IconButton(tooltip: '更多操作', onPressed: () => _menu(anchor, record), icon: const CampusIcon(CampusIcons.manage)),
        ),
        // 拖动手柄只是按住拖的把手，不是按钮：读屏给标签，不伪装成可点的按钮。
        if (dragIndex != null)
          ReorderableDragStartListener(
            index: dragIndex,
            child: Semantics(
              label: '按住拖动排序',
              child: const Padding(padding: EdgeInsets.all(12), child: CampusIcon(CampusIcons.dragHandle)),
            ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
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
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final record in _own) _tile(palette, record)],
            ),
          ),
          if (_delegated.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: Text(_delegated.length > 1 ? '代签账号 · 按住右侧把手拖动排序' : '代签账号', style: secondary),
            ),
            Flexible(
              child: ReorderableListView.builder(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.fromLTRB(16, 0, 12, 20),
                itemCount: _delegated.length,
                onReorderItem: (oldIndex, newIndex) {
                  setState(() => _delegated.insert(newIndex, _delegated.removeAt(oldIndex)));
                  _persist().catchError((Object error, StackTrace stack) {
                    campusLog('[Chaoxing] action=account_reorder errorType=${error.runtimeType}\n$stack');
                  });
                },
                itemBuilder: (context, index) => _tile(palette, _delegated[index], dragIndex: _delegated.length > 1 ? index : null),
              ),
            ),
          ] else
            const SizedBox(height: 12),
        ],
      ),
    );
  }
}
