import 'package:flutter/material.dart';

import 'package:superxd/application/campus_reminders.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/week.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_transitions.dart';

Future<void> showReminderSettings(BuildContext context, {required CampusGateway gateway, required CampusReminders reminders}) =>
    showCampusDialog<void>(context: context, builder: (context) => _ReminderDialog(gateway: gateway, reminders: reminders));

class _ReminderDialog extends StatefulWidget {
  const _ReminderDialog({required this.gateway, required this.reminders});
  final CampusGateway gateway;
  final CampusReminders reminders;
  @override
  State<_ReminderDialog> createState() => _ReminderDialogState();
}

// 打开时对账一次拿到真实状态；从系统设置页回来（回到前台）再对账。开关保存的是用户意愿，能否提醒以状态行为准。
class _ReminderDialogState extends State<_ReminderDialog> {
  ReminderStatus? _status;
  bool _busy = false;
  String? _error;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => _run(() async {}));
    _run(() async {});
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      final status = await widget.reminders.reconcile();
      if (mounted) setState(() => _status = status);
    } catch (error, stack) {
      campusLog('[Reminder] action=settings errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '提醒设置未完成，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(TermRef term, ReminderSetting setting) => _run(() async {
    if (setting.enabled && !_status!.capability.notifications) await widget.reminders.port.requestNotifications();
    final saved = await widget.gateway.saveReminderSetting(term, setting);
    if (!saved.ok) throw StateError(saved.error?.message ?? '保存失败');
  });

  String _day(String date) {
    final day = parseIsoDate(date);
    return '${day.month}月${day.day}日';
  }

  @override
  Widget build(BuildContext context) {
    final status = _status, term = status?.term;
    final palette = CampusPalette.of(context);
    final note = TextStyle(color: palette.onSurfaceVariant, fontSize: 14);
    return CampusGlassDialog(
      title: const Text('课前提醒'),
      scrollable: true,
      content: SizedBox(
        width: 400,
        child: status == null
            ? const CampusLoading(label: '读取中', inline: true)
            : term == null
            ? Text('还没有学期，同步课表后再设置。', style: note)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CampusSwitchTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('上课前提醒我'),
                    subtitle: Text(term.label.isEmpty ? '本学期' : term.label),
                    value: status.setting.enabled,
                    onChanged: _busy ? (_) {} : (value) => _save(term, ReminderSetting(enabled: value, leadMinutes: status.setting.leadMinutes)),
                  ),
                  if (status.setting.enabled) ...[
                    const SizedBox(height: 8),
                    Text('提前', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final lead in ReminderSetting.leads)
                        CampusGlassChip(
                          label: '$lead分钟',
                          selected: status.setting.leadMinutes == lead,
                          onSelected: _busy ? null : (_) => _save(term, ReminderSetting(enabled: true, leadMinutes: lead)),
                        ),
                    ]),
                    const SizedBox(height: 12),
                    ..._state(status, note),
                  ],
                  if (_busy) const CampusLoading(label: '正在安排', inline: true),
                  if (_error != null) Text(_error!, style: TextStyle(color: palette.danger, fontSize: 14)),
                ],
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('完成'))],
    );
  }

  // 状态只读、不用主色；需要用户处理的给带图标的按钮。
  List<Widget> _state(ReminderStatus status, TextStyle note) {
    if (!status.capability.notifications) {
      return [
        Text('通知未开启，暂时无法提醒。', style: note),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy ? null : () => _run(() async => widget.reminders.port.requestNotifications()),
          icon: const CampusIcon(CampusIcons.reminder),
          label: const Text('开启通知'),
        ),
      ];
    }
    return switch (status.gap) {
      OccurrenceGap.termStart => [Text('还没设置开学日，设置后才能安排提醒。', style: note)],
      OccurrenceGap.bells => [Text('缺少作息时间，同步作息后才能安排提醒。', style: note)],
      null when status.scheduled == 0 => [Text('未来两周没有课。', style: note)],
      null => [
        Text('已安排${status.scheduled}次，至${_day(status.lastDate!)}${status.capability.exact ? '' : '，可能晚几分钟'}。', style: note),
        if (!status.capability.exact) ...[
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : () => widget.reminders.port.requestExact(),
            icon: const CampusIcon(CampusIcons.settings),
            label: const Text('准时提醒'),
          ),
        ],
      ],
    };
  }
}
