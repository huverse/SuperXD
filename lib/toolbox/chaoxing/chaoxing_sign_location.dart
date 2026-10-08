import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location_sheet.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_map_page.dart';

// 签到弹层里的位置选择：收藏的位置用 chip 选，或手输经纬度（地图用不了时直接摊开并写明原因），也可在地图上选点。
// 选中与手输的状态归签到弹层管，这里只画与回调。
class ChaoxingSignLocation extends StatelessWidget {
  const ChaoxingSignLocation({
    super.key,
    required this.controller,
    required this.manual,
    required this.selected,
    required this.latitude,
    required this.longitude,
    required this.address,
    required this.busy,
    required this.onManual,
    required this.onSelect,
    required this.onSave,
    required this.onPickOnMap,
  });
  final ChaoxingController controller;
  final bool manual;
  final ChaoxingLocation? selected;
  final TextEditingController latitude;
  final TextEditingController longitude;
  final TextEditingController address;
  final bool busy;
  final ValueChanged<bool> onManual;
  final ValueChanged<ChaoxingLocation> onSelect;
  final VoidCallback onSave;
  final VoidCallback onPickOnMap;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final saved = controller.locations;
    if (manual) {
      final fallback = chaoxingMapUnavailableReason;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (fallback != null) ...[Text('$fallback，填经纬度或用收藏的位置', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)), const SizedBox(height: 12)],
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: latitude,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '纬度'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: longitude,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '经度'),
                ),
              ),
            ],
          ),
          SizedBox(height: campusFieldGap(context)),
          TextField(
            controller: address,
            decoration: const InputDecoration(labelText: '位置名称', helperText: '坐标按高德（GCJ-02）算，例如教学楼名会一起提交', helperMaxLines: 2),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(onPressed: busy ? null : onSave, icon: const CampusIcon(CampusIcons.add), label: const Text('收藏这个位置')),
              if (chaoxingMapAvailable) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(onPressed: busy ? null : onPickOnMap, icon: const CampusIcon(CampusIcons.jumpToday), label: const Text('在地图上选点')),
              ],
            ],
          ),
          if (saved.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(onPressed: () => onManual(false), icon: const CampusIcon(CampusIcons.pin), label: const Text('用收藏的位置')),
            ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (chaoxingMapAvailable) ...[
          OutlinedButton.icon(onPressed: busy ? null : onPickOnMap, icon: const CampusIcon(CampusIcons.jumpToday), label: const Text('在地图上选点')),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in saved) CampusGlassChip(label: item.label, selected: selected == item.location, onSelected: (_) => onSelect(item.location)),
            CampusGlassChip(label: '手动输入', selected: false, onSelected: (_) => onManual(true)),
            // 收藏的维护入口：改名与删除（选择在上面这些 chip 里做）。
            CampusGlassChip(
              label: '管理收藏',
              selected: false,
              onSelected: (_) => showChaoxingLocationSheet(context, controller: controller),
            ),
          ],
        ),
        const SizedBox(height: 8),
        DotSeparatedText(
          selected == null ? '还没有收藏位置' : '${selected!.address} · ${selected!.formattedLatitude}, ${selected!.formattedLongitude}',
          style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
        ),
      ],
    );
  }
}
