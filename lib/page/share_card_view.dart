import 'package:flutter/material.dart';

import 'package:superxd/domain/share_card.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';

// 私信里的分享卡片：标题行（图标 + 类型）、内容摘要、一个操作按钮。新增卡片类型在这里加一个分支。
class ShareCardView extends StatelessWidget {
  const ShareCardView({super.key, required this.card, required this.outgoing, this.onOpenSchedule, this.onApplyAppearance, this.onOpenVideo});
  final ShareCard card;
  final bool outgoing;
  final VoidCallback? onOpenSchedule;
  final VoidCallback? onApplyAppearance;
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
        action(outgoing ? CampusIcons.open : CampusIcons.commonFree, outgoing ? '查看' : '查看与对比', onOpenSchedule),
      ]),
      final AppearanceShare share => _AppearanceCard(share: share, header: header(CampusIcons.palette, '界面配置'), action: outgoing ? null : action(CampusIcons.check, '套用', onApplyAppearance)),
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

class _AppearanceCard extends StatelessWidget {
  const _AppearanceCard({required this.share, required this.header, this.action});
  final AppearanceShare share;
  final Widget header;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    final known = DisplaySettings.paletteIds.contains(share.paletteId);
    final palette = known ? CampusPalette.byId(share.paletteId, brightness: Theme.of(context).brightness) : null;
    final scaleIndex = DisplaySettings.scales.indexOf(share.scale);
    final details = [
      palette?.label ?? '新配色',
      share.fontId == 'serif' ? '文学衬线' : share.fontId == 'maple' ? 'Maple' : '新字体',
      if (scaleIndex >= 0) '字号${DisplaySettings.labels[scaleIndex]}',
      switch (share.themeMode) { 'light' => '浅色', 'dark' => '深色', _ => '跟随系统' },
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      header,
      const SizedBox(height: 12),
      if (palette != null) Row(children: [
        // 色板预览：背景、主色、激活色三块（背景与卡片色几乎一样白，放两块看不出差别）。
        for (final color in [palette.backgroundTop, palette.primary, palette.accent]) Container(
          width: 28,
          height: 28,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: colors.outlineSubtle)),
        ),
      ]),
      const SizedBox(height: 8),
      // 各项整体换行，不在词中间断开留下孤字。
      Wrap(spacing: 12, runSpacing: 4, children: [for (final detail in details) Text(detail, style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant))]),
      ?action,
    ]);
  }
}
