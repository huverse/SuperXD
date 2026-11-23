import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/application/quick_nav.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/page/quick_entry.dart';
import 'package:superxd/theme/campus_glass_material.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 编辑侧栏的常用（人工决策见 side_drawer.dart 的 SideDrawerPanel）：上面是常用，勾着、按住右边把手拖动排序；下面按分组列其余的，勾上接到常用末尾。
// 点了就存（同开屏画作的播放顺序页）。此刻看不见的（灰度关了、锁着）不列出来，存的时候原样留在末尾，看得见了还在常用里。
class QuickEditPage extends StatefulWidget {
  const QuickEditPage({super.key, required this.catalog, required this.nav});
  final QuickCatalog catalog;
  final QuickNav nav;

  @override
  State<QuickEditPage> createState() => _QuickEditPageState();
}

class _QuickEditPageState extends State<QuickEditPage> {
  late final _entries = widget.catalog.entries();
  late final _saved = widget.nav.prefs.pinned ?? widget.catalog.defaults;
  late final _visible = {for (final entry in _entries) entry.id};
  late final _pinned = [for (final id in _saved) ?_entries.where((entry) => entry.id == id).firstOrNull];

  Future<void> _save() async {
    try {
      await widget.nav.pin([for (final entry in _pinned) entry.id, for (final id in _saved) if (!_visible.contains(id)) id]);
    } catch (error, stack) {
      campusLog('[QuickNav] action=pin errorType=${error.runtimeType}\n$stack');
      if (mounted) showCampusToast(context, '保存失败，请重试');
    }
  }

  void _toggle(QuickEntry entry) {
    setState(() {
      if (!_pinned.remove(entry)) _pinned.add(entry);
    });
    unawaited(_save());
  }

  @override
  Widget build(BuildContext context) {
    final others = <String, List<QuickEntry>>{};
    for (final entry in _entries) {
      if (!_pinned.contains(entry)) (others[entry.group] ??= []).add(entry);
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('常用'),
      ),
      body: CampusScrollFade(child: SafeArea(bottom: false, child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: CustomScrollView(slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(CampusGap.large, CampusGap.small, CampusGap.large, 0),
          sliver: SliverToBoxAdapter(child: _Heading('常用')),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: CampusGap.large),
          sliver: SliverReorderableList(
            itemCount: _pinned.length,
            // 拖起的卡片保持圆角，投影只画在卡片本身（让出下边距），同开屏画作的播放顺序页。
            proxyDecorator: (child, index, animation) => Stack(children: [
              Positioned.fill(bottom: CampusGap.small, child: FadeTransition(
                opacity: animation,
                child: DecoratedBox(decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), boxShadow: campusFloatingShadow)),
              )),
              child,
            ]),
            onReorderItem: (oldIndex, newIndex) {
              setState(() => _pinned.insert(newIndex, _pinned.removeAt(oldIndex)));
              unawaited(_save());
            },
            itemBuilder: (context, index) => _Row(key: ValueKey(_pinned[index].id), entry: _pinned[index], pinned: true, index: index, onToggle: _toggle),
          ),
        ),
        SliverPadding(
          padding: campusScrollPadding(context, const EdgeInsets.fromLTRB(CampusGap.large, 0, CampusGap.large, CampusGap.large)),
          sliver: SliverList.list(children: [
            for (final MapEntry(key: group, value: members) in others.entries) ...[
              _Heading(group),
              for (final entry in members) _Row(key: ValueKey(entry.id), entry: entry, pinned: false, onToggle: _toggle),
            ],
          ]),
        ),
      ]))))),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(CampusGap.tight, CampusGap.large, CampusGap.tight, CampusGap.small),
    child: Semantics(header: true, child: Text(label, style: TextStyle(fontSize: CampusFontSize.secondary, color: CampusPalette.of(context).onSurfaceVariant))),
  );
}

class _Row extends StatelessWidget {
  const _Row({super.key, required this.entry, required this.pinned, required this.onToggle, this.index});
  final QuickEntry entry;
  final bool pinned;
  final ValueChanged<QuickEntry> onToggle;
  // 常用里的第几个（有它才有拖动把手）。
  final int? index;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final index = this.index;
    return Padding(
      padding: const EdgeInsets.only(bottom: CampusGap.small),
      child: CampusSurface(
        padding: const EdgeInsets.fromLTRB(CampusGap.tight, CampusGap.tight, CampusGap.tight, CampusGap.tight),
        onTap: () => onToggle(entry),
        child: Row(children: [
          Semantics(label: '把「${entry.title}」放进常用', child: Checkbox(value: pinned, onChanged: (_) => onToggle(entry))),
          CampusIcon(entry.icon, size: 20, color: palette.onSurfaceVariant),
          const SizedBox(width: CampusGap.medium),
          Expanded(child: Text(entry.title, style: TextStyle(fontSize: CampusFontSize.body, color: palette.onSurface))),
          // 拖动把手只是按住拖的把手，不是按钮：读屏给标签，不伪装成可点的按钮。
          if (index != null)
            ReorderableDragStartListener(
              index: index,
              child: Semantics(label: '按住拖动排序', child: const Padding(padding: EdgeInsets.all(CampusGap.medium), child: CampusIcon(CampusIcons.dragHandle))),
            )
          else
            const SizedBox(width: 48),
        ]),
      ),
    );
  }
}
