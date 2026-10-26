import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/week.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/native_glass.dart';
import 'package:superxd/domain/campus_log.dart';

Future<String?> editTermStart(BuildContext context, CampusGateway gateway, TermRef term, String? savedDate) async {
  final date = savedDate == null ? campusNow() : parseIsoDate(savedDate);
  // iOS 上是系统日期选择（theme/native_glass.dart 的 showNativeDatePicker）。
  final picked = campusNativeGlass
      ? await showNativeDatePicker(title: '选择开学日', confirm: '保存', initial: date, first: DateTime(2000), last: DateTime(2100), timeZone: campusTimeZone)
      : await showCampusDialog<DateTime>(context: context, glassPanel: false, builder: (context) => DatePickerDialog(
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
    // [人工决策-2026-10-18 16:37:59] 保存成功只出提示条、写第1周从哪天开始（成功反馈不打断，同主流做法），删掉周次算法的长说明；失败仍弹窗（用户选定）。
    if (result.ok) {
      final monday = parseIsoDate(mondayOf(value));
      showCampusToast(context, '开学日已保存 · 第1周从 ${monday.month}月${monday.day}日 开始');
      return value;
    }
    await showCampusNotice(context, title: '保存失败', result.error?.message ?? '保存未完成，请重试');
    return null;
  } catch (error, stack) {
    campusLog('[TermStart] action=save errorType=${error.runtimeType}\n$stack');
    if (context.mounted) await showCampusNotice(context, '保存开学日失败，请重试');
    return null;
  }
}
