import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/week.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/domain/campus_log.dart';

Future<String?> editTermStart(BuildContext context, CampusGateway gateway, TermRef term, String? savedDate) async {
  final date = savedDate == null ? campusNow() : parseIsoDate(savedDate);
  final picked = await showCampusDialog<DateTime>(context: context, builder: (context) => DatePickerDialog(
    initialDate: date, currentDate: campusNow(),
    firstDate: DateTime(2000), lastDate: DateTime(2100), helpText: '选择开学日',
    cancelText: '取消', confirmText: '保存',
    switchToInputEntryModeIcon: const Icon(CampusIcons.edit), switchToCalendarEntryModeIcon: const Icon(CampusIcons.todaySelected),
  ));
  if (picked == null || !context.mounted) return null;
  final value = formatIsoDate(picked);
  try {
    final result = await showCampusWaiting(context, label: '正在保存开学日', operation: () => gateway.setTermStart(term, value));
    if (!context.mounted) return null;
    await showCampusNotice(context, title: result.ok ? '开学日已保存' : '保存失败', result.ok
        ? '${term.label}\n开学日：$value\n第1周从 ${mondayOf(value)} 开始。\n\n$termStartHint'
        : result.error?.message ?? '保存未完成，请重试');
    return result.ok ? value : null;
  } catch (error, stack) {
    campusLog('[TermStart] action=save errorType=${error.runtimeType}\n$stack');
    if (context.mounted) await showCampusNotice(context, '保存开学日失败，请重试');
    return null;
  }
}
