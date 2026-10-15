import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';

// [人工决策-2026-10-15 19:18:47] 账号标签（同参考项目）：名字加一种颜色，账号管理里给账号打标签，签到时按标签一起勾选。
// 颜色用主题里的标签色（五套配色共用、对比度有测试守护），只染名字前的小图标，名字仍用正文色；用户选了要配颜色。
// 标签色的名字（换色按钮的读屏与提示），与 CampusPalette.tagColors 一一对应。
const chaoxingTagColorNames = ['红', '橙', '绿', '青', '蓝', '紫'];

class ChaoxingTagLabel extends StatelessWidget {
  const ChaoxingTagLabel({super.key, required this.tag});
  final ChaoxingAccountTag tag;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CampusIcon(CampusIcons.tag, size: 16, color: palette.tagColors[tag.colorIndex]),
        const SizedBox(width: 4),
        Flexible(child: Text(tag.name, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant))),
      ],
    );
  }
}

// 标签管理：列出全部标签，整行点按改名换色，⋯里改与删；底下新建。
Future<void> showChaoxingTagSheet(BuildContext context, {required ChaoxingController controller}) =>
    showCampusSheet<void>(context: context, builder: (_) => _ChaoxingTagSheet(controller: controller));

class _ChaoxingTagSheet extends StatefulWidget {
  const _ChaoxingTagSheet({required this.controller});
  final ChaoxingController controller;
  @override
  State<_ChaoxingTagSheet> createState() => _ChaoxingTagSheetState();
}

class _ChaoxingTagSheetState extends State<_ChaoxingTagSheet> {
  Future<void> _edit([ChaoxingAccountTag? tag]) async {
    final edited = await showCampusDialog<({String name, int colorIndex})>(context: context, builder: (_) => _TagEditor(tag: tag));
    if (edited == null || !mounted) return;
    try {
      await widget.controller.saveTag(id: tag?.id, name: edited.name, colorIndex: edited.colorIndex);
    } on ChaoxingFailure catch (failure) {
      if (mounted) await showCampusNotice(context, failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=tag_save errorType=${failure.runtimeType}\n$stack');
      if (mounted) await showCampusNotice(context, '标签没保存，请重试');
    }
  }

  Future<void> _remove(ChaoxingAccountTag tag) async {
    final agreed = await showCampusConfirm(
      context,
      title: '删除「${tag.name}」标签？',
      message: '会从所有账号上拿掉这个标签，账号本身不受影响。',
      action: '删除',
      destructive: true,
    );
    if (!agreed || !mounted) return;
    try {
      await widget.controller.removeTag(tag);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=tag_remove errorType=${failure.runtimeType}\n$stack');
      if (mounted) await showCampusNotice(context, '删除没完成，请重试');
    }
  }

  Future<void> _menu(BuildContext anchor, ChaoxingAccountTag tag) async {
    final action = await showCampusMenu<String>(anchor, items: const [
      CampusMenuItem(value: 'edit', label: '改名或换颜色', icon: CampusIcons.edit),
      CampusMenuItem(value: 'remove', label: '删除', icon: CampusIcons.delete, destructive: true),
    ]);
    if (!mounted) return;
    if (action == 'edit') await _edit(tag);
    if (action == 'remove') await _remove(tag);
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return CampusSheetPanel(
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final tags = widget.controller.tags;
          final full = tags.length >= ChaoxingStore.tagLimit;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Row(
                    children: [
                      Expanded(child: Text('标签', style: Theme.of(context).textTheme.titleLarge)),
                      IconButton(tooltip: '关闭', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.close)),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                if (tags.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                    child: Text('还没有标签，签到时可以按标签一起勾选', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
                  ),
                for (final tag in tags)
                  CampusSurface(
                    key: ValueKey(tag.id),
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                    radius: 16,
                    onTap: () => _edit(tag),
                    child: Row(
                      children: [
                        Expanded(child: Align(alignment: AlignmentDirectional.centerStart, child: ChaoxingTagLabel(tag: tag))),
                        Builder(
                          builder: (anchor) => IconButton(tooltip: '更多操作', onPressed: () => _menu(anchor, tag), icon: const CampusIcon(CampusIcons.manage)),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: OutlinedButton.icon(
                    onPressed: full ? null : () => _edit(),
                    icon: const CampusIcon(CampusIcons.add),
                    label: Text(full ? '最多 ${ChaoxingStore.tagLimit} 个标签' : '新建标签'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// 新建或编辑一个标签：名字与颜色；返回空表示取消。
class _TagEditor extends StatefulWidget {
  const _TagEditor({required this.tag});
  final ChaoxingAccountTag? tag;
  @override
  State<_TagEditor> createState() => _TagEditorState();
}

class _TagEditorState extends State<_TagEditor> {
  late final _name = TextEditingController(text: widget.tag?.name ?? '');
  late int _colorIndex = widget.tag?.colorIndex ?? 0;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return CampusGlassDialog(
      title: Text(widget.tag == null ? '新建标签' : '编辑标签'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: campusFieldGap(context)),
          TextField(
            controller: _name,
            autofocus: widget.tag == null,
            maxLength: ChaoxingStore.tagNameMaxLength,
            decoration: const InputDecoration(labelText: '标签名'),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 8,
            children: [
              for (final (index, color) in palette.tagColors.indexed)
                IconButton(
                  tooltip: chaoxingTagColorNames[index],
                  onPressed: () => setState(() => _colorIndex = index),
                  icon: DecoratedBox(
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                    child: SizedBox.square(
                      dimension: 32,
                      child: index == _colorIndex ? Center(child: CampusIcon(CampusIcons.check, size: 18, color: palette.surface)) : null,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, (name: _name.text, colorIndex: _colorIndex)), child: const Text('保存')),
      ],
    );
  }
}

// 给一个账号设标签：勾选后一次写回；还没有标签时引导去新建。
Future<void> showChaoxingAccountTagsDialog(BuildContext context, {required ChaoxingController controller, required ChaoxingAccountRecord record}) async {
  final selected = await showCampusDialog<Set<int>>(context: context, builder: (_) => _AccountTagsDialog(controller: controller, record: record));
  if (selected == null || !context.mounted) return;
  try {
    await controller.setAccountTags(record, selected);
  } catch (failure, stack) {
    campusLog('[Chaoxing] action=account_tags errorType=${failure.runtimeType}\n$stack');
    if (context.mounted) await showCampusNotice(context, '标签没保存，请重试');
  }
}

class _AccountTagsDialog extends StatefulWidget {
  const _AccountTagsDialog({required this.controller, required this.record});
  final ChaoxingController controller;
  final ChaoxingAccountRecord record;
  @override
  State<_AccountTagsDialog> createState() => _AccountTagsDialogState();
}

class _AccountTagsDialogState extends State<_AccountTagsDialog> {
  late final Set<int> _selected = {...widget.controller.accountTags[widget.record.phoneNumber] ?? const <int>{}};

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final tags = widget.controller.tags;
    return CampusGlassDialog(
      title: Text('给 ${widget.record.displayName} 设标签'),
      content: tags.isEmpty
          ? Text('还没有标签，先在账号管理顶上的「标签」里新建', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant))
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final tag in tags)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _selected.contains(tag.id),
                    onChanged: (value) => setState(() => value == true ? _selected.add(tag.id) : _selected.remove(tag.id)),
                    title: ChaoxingTagLabel(tag: tag),
                  ),
              ],
            ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        if (tags.isNotEmpty) FilledButton(onPressed: () => Navigator.pop(context, _selected), child: const Text('保存')),
      ],
    );
  }
}
