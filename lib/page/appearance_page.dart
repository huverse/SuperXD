import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'package:superxd/page/image_copy_pick.dart';
import 'package:superxd/page/text_size_range.dart';
import 'package:superxd/page/course_cards.dart';
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
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/native_glass.dart';
import 'package:superxd/theme/scroll_anchor.dart';
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

  // 系统字体本来就在系统里，直接用文字预览；内置字体用预先画好的图。
  @override
  Widget build(BuildContext context) => fontId == DisplaySettings.systemFont
      ? Text(fontPreviewText, style: const TextStyle(fontFamily: null, fontWeight: FontWeight.w500, fontSize: 16, height: 1.6).copyWith(color: color))
      : Image.asset(
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
  String? _error;
  bool _importing = false;
  String? _wallpaperError;
  // 滑杆预览后待保存的定时器：系统取消拖动、读屏增减都没有松手回调，停手 300ms 后补存。
  Timer? _lookSave;
  DisplaySettings? _settings;
  // 改字号、换字体会让整页重新排版：点的那一项在过渡期间停在手指下（人工决策见 local/display_settings.dart 的 CampusTextScale）。
  final _scroll = CampusAnchoredScrollController();
  final _scaleAnchor = GlobalKey();
  // 字号条拖动中的大小：只改预览卡与数值，手指抬起（或被系统取消）才改全应用；读屏增减没有手指，停手 300ms 补存。
  // 不靠滑杆的松手回调判断：玻璃滑杆在系统取消时不回调，而按住停一会儿又不能当成松手（会在手指下整页重排）。
  double? _draftSize;
  Timer? _sizeSave;
  bool _pressing = false;
  // 最近一次排版时的系统字号；离开页面时补存要用，那时已不能再从 context 取。
  double _system = 1;
  final _fontAnchors = {for (final id in [DisplaySettings.systemFont, ...DisplaySettings.fontFamilies.keys]) id: GlobalKey()};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = DisplayScope.of(context);
  }

  // 离开页面时还没存的预览立即保存，页面已不在，失败只记日志。
  @override
  void dispose() {
    _scroll.dispose();
    if (_sizeSave?.isActive == true) {
      _sizeSave!.cancel();
      _settings!.setTextSize(_followsAt(_draftSize!, _system) ? null : _draftSize).catchError((Object error, StackTrace stack) {
        campusLog('[Appearance] action=save_text_size errorType=${error.runtimeType}\n$stack');
      });
    }
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
    if (_importing) return;
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

  // 点了就生效：落库在 DisplaySettings 的保存锁里排队、合并完整快照，连着点也不互相覆盖，所以存的时候页面上的选项不变灰，
  // 也不在页尾插「保存中」（以前点一项整页选项闪一下灰、页尾多出一行）。只有导入壁纸这种要等的操作才原地显示进度。
  static double _fraction(double size) => ((size - DisplaySettings.textSizeMin) / (DisplaySettings.textSizeMax - DisplaySettings.textSizeMin)).clamp(0.0, 1.0);
  // 松在「系统」那一档上就回到跟随系统（同 iOS 文字大小的默认档）。
  static bool _followsAt(double size, double system) => size == DisplaySettings.snapTextSize(system);

  // 拖动中每过一档轻震一下，越过推荐上限（进出都算）重震一下，提醒再往大会改排。
  void _dragSize(DisplaySettings settings, double fraction, double current, double comfortable, double system) {
    final size = DisplaySettings.snapTextSize(DisplaySettings.textSizeMin + fraction * (DisplaySettings.textSizeMax - DisplaySettings.textSizeMin));
    final previous = _draftSize ?? current;
    if (size != previous) {
      (previous <= comfortable) != (size <= comfortable) ? HapticFeedback.mediumImpact() : HapticFeedback.selectionClick();
      // 下面的预览卡变高变矮时（贴着页底时滚动位置会被夹住）字号条也停在手指下。
      _scroll.hold(_scaleAnchor, const Duration(milliseconds: 300));
      setState(() => _draftSize = size);
    }
    _sizeSave?.cancel();
    if (!_pressing) _sizeSave = Timer(const Duration(milliseconds: 300), () => _commitSize(settings, system));
  }

  void _releaseSize(DisplaySettings settings, double system) {
    _pressing = false;
    _commitSize(settings, system);
  }

  // 松手：全应用连续过渡到新字号，这一节在过渡期间停在手指下；保存完才撤掉拖动中的值，滑杆不先跳回旧位置。
  Future<void> _commitSize(DisplaySettings settings, double system) async {
    _sizeSave?.cancel();
    final size = _draftSize;
    if (size == null) return;
    _scroll.hold(_scaleAnchor, CampusTextScale.duration + const Duration(milliseconds: 100));
    await _save(() => settings.setTextSize(_followsAt(size, system) ? null : size));
    if (mounted) setState(() => _draftSize = null);
  }

  Future<void> _save(Future<void> Function() operation) async {
    setState(() => _error = null);
    try {
      await operation();
    } catch (error, stack) {
      campusLog('[Appearance] action=save errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '保存失败，请重试');
    }
  }

  // 字号条（人工决策见 local/display_settings.dart 的 textSizeMin）：条上是实际显示大小，下方色条是这台手机的推荐范围、刻度是系统字号；
  // 再下面的预览卡按拖到的大小排；超出推荐时说明哪些页面会改排（同一套规则见 text_size_range.dart）。
  Widget _textSizeSection(BuildContext context, DisplaySettings settings, CampusPalette colors) {
    final system = _system = CampusTextScale.systemOf(context);
    final current = DisplaySettings.effectiveTextSize(settings.textSize, system);
    final shown = _draftSize ?? current;
    final width = MediaQuery.sizeOf(context).width;
    final comfortable = comfortableTextSize(context, width);
    final adaptations = textSizeAdaptations(context, width, shown);
    final following = settings.textSize == null && _draftSize == null;
    final secondary = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
    String percent(double size) => '${(size * 100).round()}%';
    final range = '${percent(DisplaySettings.textSizeMin)}–${percent(comfortable)}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 8, children: [
        Text.rich(TextSpan(children: [
          const TextSpan(text: '字号  '),
          TextSpan(text: percent(shown), style: TextStyle(color: colors.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
        ]), style: Theme.of(context).textTheme.titleLarge),
        CampusGlassChip(
          label: '跟随系统',
          selected: following,
          onSelected: (_) {
            if (following) return;
            _scroll.hold(_scaleAnchor, CampusTextScale.duration + const Duration(milliseconds: 100));
            _save(() => settings.setTextSize(null));
          },
        ),
      ]),
      const SizedBox(height: 8),
      // 改字号时整页重新排版，锚定的是字号条本身：上面的标题行随字号变高变矮也不把手指下的滑杆带走。
      KeyedSubtree(key: _scaleAnchor, child: Listener(
        onPointerDown: (_) => _pressing = true,
        onPointerUp: (_) => _releaseSize(settings, system),
        onPointerCancel: (_) => _releaseSize(settings, system),
        child: CampusSlider(
        value: _fraction(shown),
        label: '字号',
        onChanged: (fraction) => _dragSize(settings, fraction, current, comfortable, system),
        onChangeEnd: (_) => _commitSize(settings, system),
        marks: CampusSliderMarks(
          band: (0, _fraction(comfortable)),
          bandLabel: '推荐',
          ticks: [(_fraction(system), system > DisplaySettings.textSizeMax ? '系统 ${percent(system)}' : '系统')],
        ),
      ))),
      const SizedBox(height: 8),
      // 读屏读这一句：推荐范围，或超出时哪些地方会改排。
      adaptations.isEmpty
          ? BalancedText('这台手机推荐 $range', style: secondary)
          : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: EdgeInsets.only(top: ((MediaQuery.textScalerOf(context).scale(14) * 1.43 - 16) / 2).clamp(0.0, double.infinity)), child: CampusIcon(CampusIcons.warning, size: 16, color: colors.attention)),
              const SizedBox(width: 6),
              Expanded(child: BalancedText('超出推荐：${adaptations.join('、')}', style: secondary)),
            ]),
      // 预览卡在字号条下面：拖动时它变高只把下面的内容往下推，手指下的字号条不动。
      const SizedBox(height: 12),
      CourseCardPreview(textSize: shown),
    ]);
  }

  List<Widget> _wallpaperSection(BuildContext context, DisplaySettings settings) {
    final busy = _importing;
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
          controller: _scroll,
          padding: const EdgeInsets.all(20),
          children: [
            Text('外观模式', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            // 三选一用分段控件（同 iOS、鸿蒙）。
            CampusSegmented<ThemeMode>(
              values: const [ThemeMode.system, ThemeMode.light, ThemeMode.dark],
              selected: settings.themeMode,
              label: (mode) => switch (mode) { ThemeMode.system => '跟随系统', ThemeMode.light => '浅色', ThemeMode.dark => '深色' },
              onSelected: (mode) => _save(() => settings.setThemeMode(mode)),
            ),
            // [人工决策-2026-10-06 13:06:11] 按使用频率排：外观模式、配色、背景、字体、字号在前，玻璃效果（性能项、少用）放最后，用户选定。
            const SizedBox(height: 24),
            Text('配色', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                // 两列放不下“色点 + 名称 + 勾”时改单列，大字号下名称不折出孤字；按当前字体与字号实测最长名称。
                final palettes = CampusPalette.forBrightness(Theme.of(context).brightness);
                final labelWidth = palettes.map((palette) => campusTextWidth(context, palette.label, style: const TextStyle(fontSize: 16))).reduce(math.max);
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
                            onTap: () => _save(
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
              // 系统字体只在 iOS 上有（[人工决策] 见 local/display_settings.dart 的 systemFont）。
              if (DisplaySettings.supportsSystemFont) (id: DisplaySettings.systemFont, label: '系统字体'),
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
                    key: _fontAnchors[font.id],
                    selected: settings.fontId == font.id,
                    // 换字体：第一次用到要解析字形，新字体可能晚几百毫秒才排上，锚定得久一些。
                    onTap: () {
                      _scroll.hold(_fontAnchors[font.id]!, const Duration(milliseconds: 900));
                      _save(() => settings.setFont(font.id));
                    },
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
            // 推荐范围按页面里的默认文字样式量（当前字体与正文字距），要用 Scaffold 里面的 context，页面自己的 context 在它外面。
            Builder(builder: (context) => _textSizeSection(context, settings, colors)),
            // iOS 上固定磨砂档（底栏是系统的，跟随系统设置），没有档位可调（[人工决策] 见 theme/native_glass.dart）。
            if (!campusIos) ...[
              const SizedBox(height: 24),
              Text('玻璃效果', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              CampusSegmented<String>(
                values: const ['auto', 'full', 'reduced'],
                selected: settings.glassMode,
                label: (mode) => switch (mode) { 'full' => '完整', 'reduced' => '简化', _ => '自动' },
                // 限档时点「完整」（已选中也算）即解除限档重试，[人工决策] 见 campus_glass_tier.dart。
                onSelected: (mode) => _save(() async {
                  if (mode == 'full' && campusGlassCapped.value) await CampusGlassGuard.retry();
                  await settings.setGlassMode(mode);
                }),
              ),
              ValueListenableBuilder(
                valueListenable: campusGlassCapped,
                builder: (context, capped, _) => capped && settings.glassMode != 'reduced'
                    ? Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: DotSeparatedText('上次异常退出，已暂时降为简化效果 · 点「完整」重试', style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant)),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
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
