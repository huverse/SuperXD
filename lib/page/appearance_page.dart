import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:superxd/page/image_copy_pick.dart';
import 'package:superxd/page/share_target_sheet.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/wallpaper_tone.dart';
import 'package:superxd/domain/campus_log.dart';

// 选中的壁纸临时文件；discard 删除这次选图产生的临时副本（见 image_copy_pick.dart）。
typedef PickedWallpaper = PickedImage;

// 系统照片选择器；长边压到3200像素、转成JPEG，导入和取色都不用处理几十兆或HEIC原图。
Future<PickedWallpaper?> pickWallpaperFromGallery() => pickImageCopy(source: ImageSource.gallery, maxSide: 3200, quality: 90);

// 字体预览用预先画好的图（tool/font_previews.dart 按同样的文字样式生成），不为预览去加载没在用的字体：
// 内置字体首次使用时要在主线程解析全部三个字重（Maple 约 470ms），界面页首帧会卡住，页面没有过渡直接出现。
// 同微信读书、Kindle 未下载字体的预览图；图随字号缩放、按配色着色。真正换字体时才加载。
const fontPreviewText = '山有扶苏，隰有荷华。\n08:00–09:40  高等数学';
const fontPreviewScale = 3.0;
TextStyle fontPreviewStyle(String family) => TextStyle(fontFamily: family, fontWeight: FontWeight.w500, fontSize: 16, height: 1.6);

class _FontPreview extends StatelessWidget {
  const _FontPreview({required this.fontId, required this.color});
  final String fontId;
  final Color color;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/font_previews/$fontId.png',
    scale: fontPreviewScale * 16 / MediaQuery.textScalerOf(context).scale(16),
    color: color,
    colorBlendMode: BlendMode.srcIn,
    filterQuality: FilterQuality.medium,
    semanticLabel: fontPreviewText,
  );
}

class AppearancePage extends StatefulWidget {
  const AppearancePage({super.key, this.pickWallpaper = pickWallpaperFromGallery, this.social});
  final Future<PickedWallpaper?> Function() pickWallpaper;
  // 为空时不显示“分享给好友”。
  final SocialService? social;
  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage> {
  bool _saving = false;
  String? _error;
  bool _importing = false;
  String? _wallpaperError;
  // 滑杆预览后待保存的定时器：系统取消拖动、读屏增减都没有松手回调，停手 300ms 后补存。
  Timer? _lookSave;
  DisplaySettings? _settings;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = DisplayScope.of(context);
  }

  // 离开页面时还没存的预览立即保存，页面已不在，失败只记日志。
  @override
  void dispose() {
    if (_lookSave?.isActive == true) {
      _lookSave!.cancel();
      _storeLook(_settings!).catchError((Object error, StackTrace stack) {
        campusLog('[Appearance] action=save_wallpaper_look errorType=${error.runtimeType}\n$stack');
      });
    }
    super.dispose();
  }

  Future<void> _storeLook(DisplaySettings settings) {
    final look = settings.wallpaperLook.value;
    return settings.setWallpaperLook(blur: look.blur, fade: look.fade);
  }

  // 拖动中逐帧预览、不落库；正常松手立即保存，其余情况停手后补存。保存失败在背景区原地提示。
  void _preview(DisplaySettings settings, {int? blur, int? fade}) {
    settings.previewWallpaper(blur: blur, fade: fade);
    _lookSave?.cancel();
    _lookSave = Timer(const Duration(milliseconds: 300), () => _commitLook(settings));
  }

  Future<void> _commitLook(DisplaySettings settings) async {
    _lookSave?.cancel();
    try {
      await _storeLook(settings);
    } catch (error, stack) {
      campusLog('[Appearance] action=save_wallpaper_look errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _wallpaperError = '保存失败，请重试');
    }
  }

  // 选图、取色、复制在发起处原地显示进度与错误；取消选图不提示。选图的缓存副本用完即删，不在缓存里累积。
  Future<void> _importWallpaper(DisplaySettings settings) async {
    if (_saving || _importing) return;
    setState(() {
      _importing = true;
      _wallpaperError = null;
    });
    PickedWallpaper? picked;
    try {
      picked = await widget.pickWallpaper();
      if (picked == null || !mounted) return;
      final file = File(picked.path);
      if (await file.length() > DisplaySettings.wallpaperMaxBytes) {
        if (mounted) setState(() => _wallpaperError = '图片超过20MB，请换一张');
        return;
      }
      final WallpaperTone tone;
      try {
        tone = await measureWallpaper(await file.readAsBytes());
      } catch (error, stack) {
        campusLog('[Appearance] action=measure_wallpaper errorType=${error.runtimeType}\n$stack');
        if (mounted) setState(() => _wallpaperError = '无法读取这张图片，请换一张');
        return;
      }
      await settings.setWallpaper(picked.path, tone.encode());
    } catch (error, stack) {
      campusLog('[Appearance] action=wallpaper errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _wallpaperError = '设置背景失败，请重试');
    } finally {
      if (picked != null) {
        try {
          await picked.discard();
        } catch (error, stack) {
          campusLog('[Appearance] action=delete_picked errorType=${error.runtimeType}\n$stack');
        }
      }
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _save(Future<void> Function() operation) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error, stack) {
      campusLog('[Appearance] action=save error=$error\n$stack');
      if (mounted) setState(() => _error = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<Widget> _wallpaperSection(BuildContext context, DisplaySettings settings) {
    final busy = _saving || _importing;
    final custom = settings.wallpaperFile != null;
    // [人工决策-2026-10-04 16:08:17] 壁纸模糊与透明度为连续滑杆，拖动实时预览、松手保存（取代三档标签）；用户实测确认。
    // 模糊与透明度连续可调（0–100%），拖动时背景实时变化；透明度只在保证文字可读的下限之上调，不会让文字看不清。
    Widget slider(String label, int value, void Function(int) preview) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(label, style: Theme.of(context).textTheme.titleMedium)),
        Text('$value%', style: TextStyle(color: CampusPalette.of(context).onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
      ]),
      CampusSlider(
        value: value / DisplaySettings.wallpaperMax,
        label: label,
        onChanged: busy ? null : (fraction) => preview((fraction * DisplaySettings.wallpaperMax).round()),
        onChangeEnd: busy ? null : (_) => _commitLook(settings),
      ),
    ]);
    return [
      const SizedBox(height: 24),
      Text('背景', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        CampusGlassChip(label: '默认云雾', selected: !custom, onSelected: busy ? null : (_) => _save(settings.clearWallpaper)),
        CampusGlassChip(label: '自定义图片', selected: custom, onSelected: busy ? null : (_) => _importWallpaper(settings)),
      ]),
      if (custom) ...[
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.icon(
            onPressed: busy ? null : () => _importWallpaper(settings),
            icon: const CampusIcon(CampusIcons.image),
            label: const Text('更换图片'),
          ),
        ),
        const SizedBox(height: 16),
        ValueListenableBuilder<({int blur, int fade})>(
          valueListenable: settings.wallpaperLook,
          builder: (context, look, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            slider('模糊', look.blur, (value) => _preview(settings, blur: value)),
            const SizedBox(height: 8),
            slider('透明度', look.fade, (value) => _preview(settings, fade: value)),
          ]),
        ),
      ],
      if (_importing) const CampusLoading(label: '正在导入图片', inline: true),
      if (_wallpaperError != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_wallpaperError!, style: TextStyle(color: CampusPalette.of(context).danger)),
        ),
    ];
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
        actions: [
          // 分享当前界面配置（不含壁纸图片），好友预览后一键套用、可撤销。
          if (widget.social case final social?) Padding(
            padding: const EdgeInsets.only(right: 12),
            child: CampusGlassCircleButton(label: '分享给好友', size: 44, onPressed: () => showShareSheet(context, social: social, card: settings.appearance), icon: const CampusIcon(CampusIcons.share)),
          ),
        ],
      ),
      body: CampusScrollFade(child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('外观模式', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            // 三选一用分段控件（同 iOS、鸿蒙）。
            CampusSegmented<ThemeMode>(
              values: const [ThemeMode.system, ThemeMode.light, ThemeMode.dark],
              selected: settings.themeMode,
              label: (mode) => switch (mode) { ThemeMode.system => '跟随系统', ThemeMode.light => '浅色', ThemeMode.dark => '深色' },
              onSelected: _saving ? null : (mode) => _save(() => settings.setThemeMode(mode)),
            ),
            // [人工决策-2026-10-06 13:06:11] 按使用频率排：外观模式、配色、背景、字体、字号在前，玻璃效果（性能项、少用）放最后，用户选定。
            const SizedBox(height: 24),
            Text('配色', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                // 两列放不下“色点 + 名称 + 勾”时改单列，大字号下名称不折出孤字；按当前字体与字号实测最长名称。
                final palettes = CampusPalette.forBrightness(Theme.of(context).brightness);
                final labelWidth = palettes.map((palette) {
                  final painter = TextPainter(text: TextSpan(text: palette.label, style: DefaultTextStyle.of(context).style.copyWith(fontSize: 16)), textDirection: Directionality.of(context), textScaler: MediaQuery.textScalerOf(context))..layout();
                  final width = painter.width;
                  painter.dispose();
                  return width;
                }).reduce(math.max);
                final half = (constraints.maxWidth - 12) / 2;
                final width = half >= 32 + 3 * 24 + 8 + labelWidth + 24 ? half : constraints.maxWidth;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final palette in palettes)
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
            if (settings.supportsWallpaper) ..._wallpaperSection(context, settings),
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
                              _FontPreview(fontId: font.id, color: colors.onSurface),
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
                  CampusGlassChip(
                    label: DisplaySettings.labels[index],
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
            const SizedBox(height: 24),
            Text('玻璃效果', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            CampusSegmented<String>(
              values: const ['auto', 'full', 'reduced'],
              selected: settings.glassMode,
              label: (mode) => switch (mode) { 'full' => '完整', 'reduced' => '简化', _ => '自动' },
              onSelected: _saving ? null : (mode) => _save(() => settings.setGlassMode(mode)),
            ),
            if (_saving) const CampusLoading(label: '保存中', inline: true),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: colors.danger)),
              ),
          ],
        ),
      )),
    );
  }
}
