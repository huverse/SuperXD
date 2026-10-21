import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/toolbox/express/express_models.dart';

// 物流详情弹层（同官方物流页）：快递公司与运单号、有预计送达就写，轨迹按返回顺序列出、第一条最新且加粗。
// 数据由页面先读好再打开（ExpressController.loadTrack），弹层一出来就是最终内容；只读，不做官方的「订阅提醒」。
Future<void> showExpressTrackSheet(BuildContext context, ShippingTrack track) =>
    showCampusSheet<void>(context: context, builder: (context) => _ExpressTrackSheet(track: track));

class _ExpressTrackSheet extends StatelessWidget {
  const _ExpressTrackSheet({required this.track});
  final ShippingTrack track;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    return CampusSheetPanel(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 12, 4),
            child: Row(
              children: [
                Expanded(child: Text('物流详情', style: Theme.of(context).textTheme.titleLarge)),
                IconButton(tooltip: '关闭', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.close)),
              ],
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
              children: [
                DotSeparatedText([track.shippingName, track.trackingNumber].where((part) => part.isNotEmpty).join(' · '), style: secondary),
                if (track.forecast.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(track.forecast, style: TextStyle(fontSize: 16, color: palette.onSurface))),
                const SizedBox(height: 16),
                if (track.traces.isEmpty)
                  Text('暂无这个运单号的物流信息', style: secondary)
                else
                  for (final (index, trace) in track.traces.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(trace.info, style: TextStyle(fontSize: 15, height: 1.4, color: palette.onSurface, fontWeight: index == 0 ? FontWeight.w600 : FontWeight.normal)),
                          if (trace.time.isNotEmpty) Text(trace.time, style: secondary),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
