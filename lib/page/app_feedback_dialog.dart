import 'package:flutter/material.dart';

import 'package:superxd/application/app_health.dart';
import 'package:superxd/domain/app_health.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';

// 新版本反馈（人工决策见 domain/app_health.dart）：好或不好必选、一句话可不写，匿名提交；提交成功返回 true（关于页出提示条），失败原地写原因。
Future<bool?> showAppFeedback(BuildContext context, AppHealth health) => showCampusDialog<bool>(context: context, builder: (_) => _FeedbackDialog(health: health));

class _FeedbackDialog extends StatefulWidget {
  const _FeedbackDialog({required this.health});
  final AppHealth health;

  @override
  State<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<_FeedbackDialog> {
  final _text = TextEditingController();
  bool? _good;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final good = _good;
    if (good == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.health.sendFeedback(good: good, text: _text.text);
      if (mounted) Navigator.pop(context, true);
    } on AppHealthException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.message;
        });
      }
    }
  }

  Widget _choice(bool good, IconData icon, String label) => ChoiceChip(
    avatar: CampusIcon(icon),
    label: Text(label),
    selected: _good == good,
    onSelected: _busy ? null : (_) => setState(() => _good = good),
  );

  @override
  Widget build(BuildContext context) => CampusGlassDialog(
    title: const Text('新版本反馈'),
    content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [_choice(true, CampusIcons.thumbsUp, '好用'), _choice(false, CampusIcons.thumbsDown, '不好用')]),
      Padding(
        padding: EdgeInsets.only(top: campusFieldGap(context)),
        child: TextField(controller: _text, enabled: !_busy, minLines: 1, maxLines: 4, maxLength: feedbackTextMax, decoration: const InputDecoration(labelText: '想说的话（可不写）')),
      ),
      if (_error case final error?) Text(error, style: TextStyle(fontSize: 14, color: CampusPalette.of(context).danger)),
    ]),
    actions: [
      TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: _good == null || _busy ? null : _submit, child: CampusBusyContent(busy: _busy, label: '提交', busyLabel: '提交中')),
    ],
  );
}
