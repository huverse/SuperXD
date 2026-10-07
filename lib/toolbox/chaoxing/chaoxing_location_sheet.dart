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

// 收藏位置的管理弹层：改名与删除（签到弹层里只管选，这里管维护）。
Future<void> showChaoxingLocationSheet(BuildContext context, {required ChaoxingController controller}) =>
    showCampusSheet<void>(context: context, builder: (context) => _ChaoxingLocationSheet(controller: controller));

class _ChaoxingLocationSheet extends StatefulWidget {
  const _ChaoxingLocationSheet({required this.controller});
  final ChaoxingController controller;
  @override
  State<_ChaoxingLocationSheet> createState() => _ChaoxingLocationSheetState();
}

class _ChaoxingLocationSheetState extends State<_ChaoxingLocationSheet> {
  bool _working = false;

  Future<void> _rename(ChaoxingSavedLocation saved) async {
    final controller = TextEditingController(text: saved.label);
    final label = await showCampusDialog<String>(
      context: context,
      builder: (dialog) => CampusGlassDialog(
        title: const Text('改收藏名'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: '名字')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialog, controller.text.trim()), child: const Text('保存')),
        ],
      ),
    );
    controller.dispose();
    if (label == null || label.isEmpty || label == saved.label || !mounted) return;
    await _run(() => widget.controller.renameLocation(saved.id, label), '改名没完成，请重试');
  }

  Future<void> _remove(ChaoxingSavedLocation saved) async {
    final agreed = await showCampusConfirm(
      context,
      title: '删除这个收藏位置？',
      message: '只删本机的收藏，不影响签到。',
      action: '删除',
      destructive: true,
    );
    if (!agreed || !mounted) return;
    await _run(() => widget.controller.forgetLocation(saved.id), '删除没完成，请重试');
  }

  Future<void> _run(Future<void> Function() action, String fallback) async {
    setState(() => _working = true);
    try {
      await action();
    } on ChaoxingFailure catch (failure) {
      if (mounted) await showCampusNotice(context, failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=location_sheet errorType=${failure.runtimeType}\n$stack');
      if (mounted) await showCampusNotice(context, fallback);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final saved = widget.controller.locations;
    return CampusSheetPanel(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 12, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('收藏的位置', style: Theme.of(context).textTheme.titleLarge)),
                IconButton(tooltip: '关闭', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.close)),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (saved.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text('还没有收藏位置，签到成功后会问要不要收藏', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
                    )
                  else
                    for (final item in saved)
                      CampusSurface(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(8),
                        radius: 16,
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(item.label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: palette.onSurface)),
                                  DotSeparatedText(
                                    '${item.location.address} · ${item.location.formattedLatitude}, ${item.location.formattedLongitude}',
                                    style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: '改名',
                              onPressed: _working ? null : () => _rename(item),
                              icon: const CampusIcon(CampusIcons.edit),
                            ),
                            IconButton(
                              tooltip: '删除',
                              onPressed: _working ? null : () => _remove(item),
                              icon: const CampusIcon(CampusIcons.delete),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
