import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

// 修复账号：对方改了密码、或会话彻底失效时，重新输一次学习通密码。返回空表示取消。
Future<String?> showChaoxingPasswordPrompt(BuildContext context, {required String name}) => showCampusDialog<String>(
  context: context,
  builder: (_) => _PasswordPrompt(name: name),
);

class _PasswordPrompt extends StatefulWidget {
  const _PasswordPrompt({required this.name});
  final String name;
  @override
  State<_PasswordPrompt> createState() => _PasswordPromptState();
}

class _PasswordPromptState extends State<_PasswordPrompt> {
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CampusGlassDialog(
    title: Text('重新登录 ${widget.name}'),
    content: Padding(
      padding: EdgeInsets.only(top: campusFieldGap(context)),
      child: TextField(
        controller: _password,
        autofocus: true,
        obscureText: _obscure,
        style: const TextStyle(fontSize: 16),
        decoration: InputDecoration(
          labelText: '学习通密码',
          suffixIcon: IconButton(
            tooltip: _obscure ? '显示密码' : '隐藏密码',
            onPressed: () => setState(() => _obscure = !_obscure),
            icon: CampusIcon(_obscure ? CampusIcons.eye : CampusIcons.eyeClosed),
          ),
        ),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: () => Navigator.pop(context, _password.text), child: const Text('登录')),
    ],
  );
}

// 签到设置：学校单位（账号挂在多个单位下时可选）与模拟的客户端（定制版学习通的学校要换）。
Future<void> showChaoxingSettingsSheet(BuildContext context, {required ChaoxingController controller}) =>
    showCampusSheet<void>(context: context, builder: (_) => _ChaoxingSettingsSheet(controller: controller));

class _ChaoxingSettingsSheet extends StatefulWidget {
  const _ChaoxingSettingsSheet({required this.controller});
  final ChaoxingController controller;
  @override
  State<_ChaoxingSettingsSheet> createState() => _ChaoxingSettingsSheetState();
}

class _ChaoxingSettingsSheetState extends State<_ChaoxingSettingsSheet> {
  late final _userAgent = TextEditingController(
    text: widget.controller.profile.id == ChaoxingClientProfile.customId ? widget.controller.profile.userAgent : '',
  );
  late final _packageName = TextEditingController(
    text: widget.controller.profile.id == ChaoxingClientProfile.customId ? widget.controller.profile.packageName : '',
  );
  late String _profileId = widget.controller.profile.id;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _userAgent.dispose();
    _packageName.dispose();
    super.dispose();
  }

  Future<void> _apply(Future<void> Function() action) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await action();
    } on ChaoxingFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=settings errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '设置没保存，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveCustom() async {
    final problem = ChaoxingClientProfile.userAgentProblem(_userAgent.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    await _apply(
      () => widget.controller.setProfile(
        ChaoxingClientProfile.custom(userAgent: _userAgent.text, packageName: _packageName.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final controller = widget.controller;
    final record = controller.current;
    final units = record?.units ?? const <ChaoxingUnit>[];
    return CampusSheetPanel(
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 12, 12, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text('签到设置', style: Theme.of(context).textTheme.titleLarge)),
                  IconButton(tooltip: '关闭', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.close)),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (units.length > 1) ...[
                      Text('学校单位', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final unit in units)
                            CampusGlassChip(
                              label: unit.name,
                              selected: controller.current?.fid == unit.fid,
                              onSelected: _saving ? null : (_) => _apply(() => controller.selectUnit(unit)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],
                    Text('模拟的客户端', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final preset in ChaoxingClientProfile.presets)
                          CampusGlassChip(
                            label: preset.label,
                            selected: _profileId == preset.id,
                            onSelected: _saving
                                ? null
                                : (_) {
                                    setState(() => _profileId = preset.id);
                                    _apply(() => controller.setProfile(preset));
                                  },
                          ),
                        CampusGlassChip(
                          label: '自定义',
                          selected: _profileId == ChaoxingClientProfile.customId,
                          onSelected: _saving ? null : (_) => setState(() => _profileId = ChaoxingClientProfile.customId),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '学校用的是定制版学习通、课程列表对不上时才需要换，否则保持「学习通」',
                      style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
                    ),
                    if (_profileId == ChaoxingClientProfile.customId) ...[
                      SizedBox(height: campusFieldGap(context)),
                      TextField(
                        controller: _userAgent,
                        maxLines: 3,
                        minLines: 1,
                        decoration: const InputDecoration(labelText: '完整的 UserAgent'),
                      ),
                      SizedBox(height: campusFieldGap(context)),
                      TextField(
                        controller: _packageName,
                        decoration: const InputDecoration(labelText: '客户端包名（可不填）'),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _saving ? null : () => _saveCustom(),
                        child: CampusBusyContent(busy: _saving, label: '保存', busyLabel: '保存中', icon: const CampusIcon(CampusIcons.check)),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(fontSize: 14, color: palette.danger)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
