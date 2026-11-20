import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/toolbox/toolbox_image.dart';

// 电影院列表的一行：左边海报（经百宝箱的小网络图，只认公网 https，取不到画占位）、右边片名与说明行。
// 用整行卡片不用海报墙网格：网格的格子高度固定，大字号时片名会被裁掉。
class CinemaPosterRow extends StatelessWidget {
  const CinemaPosterRow({super.key, required this.covers, required this.title, required this.lines, required this.onTap});
  final List<String> covers;
  final String title;
  final List<String> lines;
  final VoidCallback onTap;

  static const posterWidth = 72.0;
  static const posterHeight = 104.0;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final text = Theme.of(context).textTheme;
    return CampusSurface(
      padding: const EdgeInsets.all(12),
      onTap: onTap,
      child: Row(
        children: [
          CinemaPoster(urls: covers, width: posterWidth, height: posterHeight),
          const SizedBox(width: CampusGap.medium),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                for (final line in lines)
                  if (line.isNotEmpty) ...[
                    const SizedBox(height: CampusGap.tight),
                    Text(line, style: text.bodyMedium?.copyWith(color: palette.onSurfaceVariant), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
              ],
            ),
          ),
          CampusIcon(CampusIcons.next, color: palette.onSurfaceVariant),
        ],
      ),
    );
  }
}

// 「看过的」横向海报条里的一张（人工决策见 cinema_page.dart 的 _historySlivers）：海报底边是看到哪的进度，下面片名占一整行、再下面集数与⋯
// （⋯ 放在片名那行时片名只剩三个字，Maple 中文字宽）。
// 横向列表要定高，heightOf 按当前字号、字体量两行字，大字号时整条跟着长高、不裁字。
class CinemaHistoryCard extends StatelessWidget {
  const CinemaHistoryCard({super.key, required this.cover, required this.title, required this.episode, required this.progress, required this.onTap, required this.onMore});
  final String cover;
  final String title;
  final String episode;
  // 看到哪占这一集的比例（0–1）；不知道这一集多长时为空，不画进度。
  final double? progress;
  final VoidCallback onTap;
  final void Function(BuildContext anchor) onMore;

  static const posterWidth = 120.0;
  static const posterHeight = 172.0;
  static const width = posterWidth + CampusGap.small * 2;
  // ⋯ 放在集数那一行右边，触区按 48（主题给图标按钮垫的最小触区）算这一行的高。
  static const _more = 48.0;

  static TextStyle? _titleStyle(BuildContext context) => Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600);
  static TextStyle? _episodeStyle(BuildContext context) => Theme.of(context).textTheme.bodyMedium;

  static double heightOf(BuildContext context) {
    final title = campusTextPainter(context, '字', style: _titleStyle(context), maxLines: 1), episode = campusTextPainter(context, '字', style: _episodeStyle(context), maxLines: 1);
    final lines = title.height + math.max(episode.height, _more);
    title.dispose();
    episode.dispose();
    return CampusGap.small + posterHeight + CampusGap.small + lines + CampusGap.small;
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final progress = this.progress;
    return CampusSurface(
      padding: const EdgeInsets.all(CampusGap.small),
      onTap: onTap,
      child: SizedBox(
        width: posterWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(CampusGap.small),
              child: Stack(
                children: [
                  CinemaPoster(urls: [cover], width: posterWidth, height: posterHeight),
                  if (progress != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ColoredBox(
                        color: palette.onSurface.withValues(alpha: .3),
                        child: FractionallySizedBox(
                          alignment: AlignmentDirectional.centerStart,
                          widthFactor: progress.clamp(0.0, 1.0),
                          child: ColoredBox(color: palette.accent, child: const SizedBox(height: CampusGap.tight)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: CampusGap.small),
            Text(title, style: _titleStyle(context), maxLines: 1, overflow: TextOverflow.ellipsis),
            Row(
              children: [
                Expanded(child: Text(episode, style: _episodeStyle(context)?.copyWith(color: palette.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis)),
                Builder(
                  builder: (anchor) => IconButton(
                    tooltip: '更多操作',
                    onPressed: () => onMore(anchor),
                    icon: CampusIcon(CampusIcons.manage, size: 20, color: palette.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// 海报：按给的先后取，取不到（超时、不是公网 https）换下一张，都不行画占位。
class CinemaPoster extends StatefulWidget {
  const CinemaPoster({super.key, required this.urls, required this.width, required this.height});
  final List<String> urls;
  final double width;
  final double height;
  @override
  State<CinemaPoster> createState() => _CinemaPosterState();
}

class _CinemaPosterState extends State<CinemaPoster> {
  var _index = 0;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final placeholder = ColoredBox(color: palette.surfaceSelected, child: Center(child: CampusIcon(CampusIcons.cinema, color: palette.onSurfaceVariant)));
    final candidates = [for (final url in widget.urls) if (Uri.tryParse(url)?.isScheme('https') == true) url];
    final url = _index < candidates.length ? candidates[_index] : null;
    final width = widget.width, height = widget.height;
    return ClipRRect(
      borderRadius: BorderRadius.circular(CampusGap.small),
      child: SizedBox(
        width: width,
        height: height,
        child: url != null
            ? Image(
                key: ValueKey(url),
                image: ToolboxRemoteImage(url, module: 'cinema', side: (height * MediaQuery.devicePixelRatioOf(context)).round()),
                fit: BoxFit.cover,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _index < candidates.length) setState(() => _index++);
                  });
                  return placeholder;
                },
                frameBuilder: (context, child, frame, synchronous) => frame == null && !synchronous ? placeholder : child,
              )
            : placeholder,
      ),
    );
  }
}

// 时长写成 1:02:03 或 12:03。
String formatCinemaDuration(Duration value) {
  final hours = value.inHours, minutes = value.inMinutes % 60, seconds = value.inSeconds % 60;
  String two(int number) => number.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:${two(minutes)}:${two(seconds)}' : '${two(minutes)}:${two(seconds)}';
}
