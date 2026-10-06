import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/application/campus_sync.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/domain/campus_log.dart';

Future<SyncSelection?> chooseSyncSelection(BuildContext context, CampusGateway gateway, {String? initialYear, Set<SyncContent>? initialContents, Set<SyncContent>? allowedContents}) => showCampusDialog<SyncSelection>(
  context: context,
  builder: (context) => _SyncSelectionDialog(gateway: gateway, initialYear: initialYear, initialContents: initialContents, allowedContents: allowedContents),
);

class _SyncSelectionDialog extends StatefulWidget {
  const _SyncSelectionDialog({required this.gateway, this.initialYear, this.initialContents, this.allowedContents});
  final CampusGateway gateway;
  final String? initialYear;
  final Set<SyncContent>? initialContents;
  final Set<SyncContent>? allowedContents;
  @override
  State<_SyncSelectionDialog> createState() => _SyncSelectionDialogState();
}

class _SyncSelectionDialogState extends State<_SyncSelectionDialog> {
  List<String> _years = [];
  late final Set<String> _selectedYears = {?widget.initialYear};
  late final Set<SyncContent> _allowed = widget.allowedContents ?? SyncContent.values.toSet();
  late final Set<SyncContent> _contents = (widget.initialContents ?? _allowed).intersection(_allowed);
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(false);
  }

  Future<void> _load(bool refresh) async {
    setState(() { _loading = true; _error = null; });
    try {
      final result = refresh ? await widget.gateway.syncTerms() : await widget.gateway.listTerms();
      if (!mounted) return;
      final terms = result.data ?? [];
      final years = terms.map((term) => term.xn).toSet().toList()..sort((a, b) => b.compareTo(a));
      setState(() {
        _years = years;
        _selectedYears.removeWhere((year) => !years.contains(year));
        if (_selectedYears.isEmpty && terms.isNotEmpty) _selectedYears.add(terms.first.xn);
        _loading = false;
        _error = result.ok ? null : result.error?.message;
      });
    } catch (error, stack) {
      campusLog('[SyncSelection] action=load errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() { _loading = false; _error = '读取学年失败，请重试'; });
    }
  }

  @override
  Widget build(BuildContext context) => CampusGlassDialog(
    title: const Text('同步范围'),
    content: SizedBox(width: 440, child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [const Expanded(child: Text('选择学年')), TextButton.icon(onPressed: _loading ? null : () => _load(true), icon: const CampusIcon(CampusIcons.sync), label: const Text('刷新学年'))]),
        if (_loading) const CampusLoading(label: '正在读取学年', inline: true),
        if (_error != null) Text(_error!),
        if (!_loading && _years.isEmpty) const Text('暂无学年，请先点“刷新学年”。不会自动同步课表。'),
        if (_years.isNotEmpty) ...[
          CheckboxListTile(contentPadding: EdgeInsets.zero, title: const Text('全部学年'),
            value: _selectedYears.length == _years.length, onChanged: _loading ? null : (value) => setState(() {
              _selectedYears.clear(); if (value == true) _selectedYears.addAll(_years);
            })),
          Wrap(spacing: 8, runSpacing: 8, children: [for (final year in _years)
            CampusGlassChip(label: '$year–${int.parse(year) + 1}', selected: _selectedYears.contains(year), onSelected: _loading ? null : (value) => setState(() {
              if (value) { _selectedYears.add(year); } else { _selectedYears.remove(year); }
            })),
          ]),
        ],
        const SizedBox(height: 16),
        const Text('同步内容'),
        for (final content in SyncContent.values.where(_allowed.contains))
          CheckboxListTile(contentPadding: EdgeInsets.zero,
            value: _contents.contains(content),
            title: Text(switch (content) { SyncContent.schedule => '课表', SyncContent.bells => '作息', SyncContent.grades => '成绩' }),
            onChanged: (value) => setState(() { if (value == true) { _contents.add(content); } else { _contents.remove(content); } }),
          ),
        const Text('覆盖所选学年已公布的学期', style: TextStyle(fontSize: 14)),
      ],
    ))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: _loading || _contents.isEmpty || _selectedYears.isEmpty ? null : () => Navigator.pop(context, SyncSelection(years: _selectedYears, contents: _contents)), child: const Text('开始同步')),
    ],
  );
}
