import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_tokens.dart';
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
