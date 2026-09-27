import 'package:flutter/material.dart';

import 'package:superxd/local/display_settings.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';

class AppearancePage extends StatefulWidget {
  const AppearancePage({super.key});
  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage> {
  bool _saving = false;
  String? _error;
  Future<void> _save(Future<void> Function() operation) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error, stack) {
      debugPrint('[Appearance] action=save error=$error\n$stack');
      if (mounted) setState(() => _error = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = DisplayScope.of(context);
    final colors = CampusPalette.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: '返回',
          onPressed: () => Navigator.pop(context),
          icon: const CampusIcon(CampusIcons.back),
        ),
        title: const Text('界面'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('配色', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth > 360
                    ? (constraints.maxWidth - 12) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final palette in CampusPalette.values)
                      SizedBox(
                        width: width,
                        child: Semantics(
                          selected: settings.paletteId == palette.id,
                          button: true,
                          label: palette.label,
                          child: CampusSurface(
                            padding: EdgeInsets.zero,
                            selected: settings.paletteId == palette.id,
                            onTap: _saving
                                ? null
                                : () => _save(
                                    () => settings.setPalette(palette.id),
                                  ),
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    palette.backgroundTop,
                                    palette.backgroundBottom,
                                  ],
                                ),
                              ),
                              child: Row(
                                children: [
                                  for (final color in [
                                    palette.primary,
                                    palette.fogSage,
                                    palette.fogChampagne,
                                  ])
                                    Padding(
                                      padding: const EdgeInsets.only(right: 6),
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: color,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const SizedBox.square(
                                          dimension: 18,
                                        ),
                                      ),
                                    ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      palette.label,
                                      style: TextStyle(
                                        color: palette.onSurface,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ),
                                  if (settings.paletteId == palette.id)
                                    CampusIcon(
                                      CampusIcons.check,
                                      size: 20,
                                      color: palette.primary,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 24),
            Text('字体', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            for (final font in [
              (id: 'maple', label: 'Maple'),
              (id: 'serif', label: '文学衬线'),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Semantics(
                  selected: settings.fontId == font.id,
                  button: true,
                  label: font.label,
                  child: CampusSurface(
                    selected: settings.fontId == font.id,
                    onTap: _saving
                        ? null
                        : () => _save(() => settings.setFont(font.id)),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                font.label,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '山有扶苏，隰有荷华。\n08:00–09:40  高等数学',
                                style: TextStyle(
                                  fontFamily:
                                      DisplaySettings.fontFamilies[font.id],
                                  fontWeight: FontWeight.w500,
                                  fontSize: 16,
                                  height: 1.6,
                                  color: colors.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (settings.fontId == font.id)
                          const CampusIcon(CampusIcons.check),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Text('字号', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (
                  var index = 0;
                  index < DisplaySettings.scales.length;
                  index++
                )
                  ChoiceChip(
                    label: Text(DisplaySettings.labels[index]),
                    selected: settings.scale == DisplaySettings.scales[index],
                    onSelected: _saving
                        ? null
                        : (_) => _save(
                            () => settings.setScale(
                              DisplaySettings.scales[index],
                            ),
                          ),
                  ),
              ],
            ),
            if (_saving) const CampusLoading(label: '保存中', inline: true),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: colors.danger)),
              ),
          ],
        ),
      ),
    );
  }
}
