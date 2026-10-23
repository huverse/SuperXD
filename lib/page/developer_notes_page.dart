import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/application/developer_notes.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/developer_note.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_refresh.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 开发者的话（人工决策见 domain/developer_note.dart）：信按发出时刻从新到旧列出，没读的标小圆点，点开读全文；下拉刷新。
// 正文原样显示（换行、空行都照写的来），不加粗、不改写，可长按复制。
class DeveloperNotesPage extends StatelessWidget {
  const DeveloperNotesPage({super.key, required this.notes});
  final DeveloperNotes notes;

  Future<void> _refresh(BuildContext context) async {
    try {
      await notes.refresh();
    } on DeveloperNoteException catch (error) {
      if (context.mounted) showCampusToast(context, error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final inset = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('开发者的话'),
      ),
      body: CampusScrollFade(bottom: inset, child: ListenableBuilder(listenable: notes, builder: (context, _) => CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        slivers: [
          CampusRefreshControl(onRefresh: () => _refresh(context)),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + inset),
            sliver: notes.notes.isEmpty
                ? SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.only(top: 48), child: Text('还没有内容', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant))))
                : SliverList.list(children: [
                    for (final note in notes.notes)
                      Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: _NoteCard(note: note, read: notes.isRead(note), onOpen: () => openDeveloperNote(context, notes, note)))),
                  ]),
          ),
        ],
      ))),
    );
  }
}

// 点开一封就记成读过（写不上只记日志，见 DeveloperNotes）。
Future<void> openDeveloperNote(BuildContext context, DeveloperNotes notes, DeveloperNote note) {
  unawaited(notes.markRead(note));
  return Navigator.of(context, rootNavigator: true).push(CampusPageRoute<void>(builder: (_) => _NotePage(note: note)));
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.note, required this.read, required this.onOpen});
  final DeveloperNote note;
  final bool read;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final date = formatCampusRelative(note.publishedAt.toIso8601String());
    return Semantics(
      label: '${read ? '' : '没读，'}${note.title}，$date',
      excludeSemantics: true,
      button: true,
      child: CampusSurface(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        onTap: onOpen,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(note.title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, height: 1.4, color: palette.onSurface))),
            if (!read) Padding(padding: const EdgeInsets.only(left: 12), child: UnreadDot(color: palette.dangerFill)),
          ]),
          const SizedBox(height: 6),
          // 摘要把换行与空行折成一个空格，三行都给正文。
          Text(note.body.trim().replaceAll(RegExp(r'\s*\n\s*'), ' '), maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, height: 1.6, color: palette.onSurfaceVariant)),
          const SizedBox(height: 10),
          Text(date, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

// 没读的小圆点：状态信息，警示红底（同底栏未读角标），不用主色。
class UnreadDot extends StatelessWidget {
  const UnreadDot({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: 8, child: DecoratedBox(decoration: BoxDecoration(color: color, shape: BoxShape.circle)));
}

class _NotePage extends StatelessWidget {
  const _NotePage({required this.note});
  final DeveloperNote note;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final inset = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('开发者的话'),
      ),
      body: CampusScrollFade(bottom: inset, child: SelectionArea(child: ListView(
        padding: EdgeInsets.fromLTRB(24, 20, 24, 32 + inset),
        children: [
          Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: _Letter(note: note, palette: palette))),
        ],
      ))),
    );
  }
}

// 一封信的版式：标题、正文，落款处写日期（同信纸右下）。读信页与弹出的信共用。
class _Letter extends StatelessWidget {
  const _Letter({required this.note, required this.palette, this.title = true});
  final DeveloperNote note;
  final CampusPalette palette;
  final bool title;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (title) ...[
        Text(note.title, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, height: 1.4, color: palette.onSurface)),
        const SizedBox(height: 16),
      ],
      Text(note.body.trim(), style: TextStyle(fontSize: 16, height: 1.75, color: palette.onSurface)),
      const SizedBox(height: 20),
      Text(formatCampusRelative(note.publishedAt.toIso8601String()), textAlign: TextAlign.end, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
    ]);
  }
}

// 新信弹出来（什么时候弹见 application/app_moments.dart）：玻璃弹窗里读全文，太长可滚动；还有别的没读时多一个「查看全部」。
Future<void> showDeveloperNoteLetter(BuildContext context, {required DeveloperNotes notes, required DeveloperNote note}) async {
  final others = notes.notes.where((item) => item.id != note.id && !notes.isRead(item)).length;
  final all = await showCampusDialog<bool>(
    context: context,
    builder: (context) {
      final palette = CampusPalette.of(context);
      return CampusGlassDialog(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('开发者的话', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: palette.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(note.title),
        ]),
        scrollable: true,
        content: _Letter(note: note, palette: palette, title: false),
        actions: [
          if (others > 0) TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('查看全部')),
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('知道了')),
        ],
      );
    },
  );
  if (all == true && context.mounted) await Navigator.of(context, rootNavigator: true).push(CampusPageRoute<void>(builder: (_) => DeveloperNotesPage(notes: notes)));
}
