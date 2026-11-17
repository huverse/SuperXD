import 'package:flutter/material.dart';

import 'package:superxd/domain/share_card.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';

// 私信里的分享卡片：标题行（图标 + 类型）、内容摘要、一个操作按钮。新增卡片类型在这里加一个分支。
class ShareCardView extends StatelessWidget {
  const ShareCardView({super.key, required this.card, required this.outgoing, this.onOpenSchedule, this.onImportSchedule, this.onOpenVideo});
  final ShareCard card;
  final bool outgoing;
  final VoidCallback? onOpenSchedule;
  // 收到的课表导入到自己的课表；为空（自己发出的、未登录）时不显示。
  final VoidCallback? onImportSchedule;
  final VoidCallback? onOpenVideo;

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
    Widget header(IconData icon, String label) => Row(children: [
      CampusIcon(icon, size: 20, color: colors.primary),
      const SizedBox(width: 8),
      Text(label, style: secondary),
    ]);
    Widget action(IconData icon, String label, VoidCallback? onPressed) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Align(alignment: AlignmentDirectional.centerStart, child: FilledButton.icon(onPressed: onPressed, icon: CampusIcon(icon), label: Text(label))),
    );
    return switch (card) {
      ScheduleShare(:final term, :final courses, :final termStartDate) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        header(CampusIcons.todaySelected, '课表'),
        const SizedBox(height: 8),
        Text(term.label.isEmpty ? term.key : term.label, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('${courses.length} 门课${termStartDate == null ? '' : ' · ${int.parse(termStartDate.substring(5, 7))}月${int.parse(termStartDate.substring(8))}日开学'}', style: secondary),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(onPressed: onOpenSchedule, icon: CampusIcon(outgoing ? CampusIcons.open : CampusIcons.commonFree), label: Text(outgoing ? '查看' : '查看与对比')),
            if (onImportSchedule != null) FilledButton.icon(onPressed: onImportSchedule, icon: const CampusIcon(CampusIcons.importSchedule), label: const Text('导入')),
          ]),
        ),
      ]),
      RetiredShare() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        header(CampusIcons.info, '已不再支持'),
        const SizedBox(height: 8),
        Text('这种卡片已不再支持', style: secondary),
      ]),
      VideoShare(:final title, :final author, :final kind) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        header(kind == 'gallery' ? CampusIcons.images : CampusIcons.video, kind == 'gallery' ? '图集' : '视频'),
        const SizedBox(height: 8),
        Text(title.isEmpty ? '作品分享' : title, maxLines: 3, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
        if (author.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(author, style: secondary)),
        action(CampusIcons.parse, '打开', onOpenVideo),
      ]),
      UnknownShare() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        header(CampusIcons.info, '新版本消息'),
        const SizedBox(height: 8),
        Text('当前版本无法显示，请更新应用后让对方重新发送', style: secondary),
      ]),
    };
  }
}
