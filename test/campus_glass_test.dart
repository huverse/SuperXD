import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;

import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_glass_material.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_glass_surface.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/page/licenses_page.dart';
import 'package:superxd/theme/campus_background.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_surface.dart';

// 玻璃的背景采样整块绘制或不画：显隐期间玻璃之上不得有半透明的 Opacity 或 FadeTransition，否则玻璃到最后才突然出现。
void expectGlassUnfaded(Finder glass) {
  expect(glass, findsWidgets);
  for (final element in glass.evaluate()) {
    element.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is Opacity) expect(widget.opacity, 1);
      if (widget is FadeTransition) expect(widget.opacity.value, 1);
      return true;
    });
  }
}

// 实色面板没有玻璃，仍须随进度淡入：返回其上最小的不透明度。
double fadedOpacity(Finder panel) {
  var opacity = 1.0;
  panel.evaluate().single.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is Opacity) opacity = math.min(opacity, widget.opacity);
    if (widget is FadeTransition) opacity = math.min(opacity, widget.opacity.value);
    return true;
  });
  return opacity;
}

void main() {
  test('暖灰背景最坏明度下正文辅助与按钮对比度合格', () {
    double contrast(Color left, Color right) {
      final a = left.computeLuminance(), b = right.computeLuminance();
      return (a > b ? a + .05 : b + .05) / (a > b ? b + .05 : a + .05);
    }

    for (final background in [
      CampusPalette.values.first.backgroundTop,
      CampusPalette.values.first.backgroundBottom,
      CampusPalette.values.first.surface,
      CampusPalette.values.first.surfaceSelected,
      CampusPalette.values.first.glassFallback,
    ]) {
      expect(
        contrast(CampusPalette.values.first.onSurface, background),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(CampusPalette.values.first.onSurfaceVariant, background),
        greaterThanOrEqualTo(4.5),
      );
    }
    expect(
      contrast(CampusPalette.values.first.primary, CampusPalette.values.first.onPrimary),
      greaterThanOrEqualTo(4.5),
    );
  });
  testWidgets('背景单层循环在减少动画和后台停帧，固定相位可验收', (tester) async {
    Widget host({bool reduced = false, double? phase}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: CampusMotion(
          child: CampusAtmosphere(
            phase: phase,
            child: const Scaffold(body: Text('页面')),
          ),
        ),
      ),
    );
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.binding.hasScheduledFrame, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(host(reduced: true));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(host(phase: .5));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
  testWidgets('许可页精确两行署名并保留多个包及原始许可正文', (tester) async {
    final entry = LicenseEntryWithLineBreaks([
      'flutter-test-package',
      'second-package',
    ], 'Copyright Test Owner\n\nFull original license content.');
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        home: CampusLicensesPage(licenses: Stream.value(entry)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Powered&Design By Galaxyous'), findsOneWidget);
    expect(find.text('基于Flutter框架'), findsOneWidget);
    expect(find.text('Powered by Flutter'), findsNothing);
    expect(find.text('second-package'), findsOneWidget);
    await tester.tap(find.text('flutter-test-package'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Copyright Test Owner'), findsOneWidget);
    expect(
      find.textContaining('Full original license content.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('细磨砂卡在窄屏大字号保持可点击且不添加背景滤镜', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var clicked = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
          child: Scaffold(
            body: CampusSurface(
              onTap: () => clicked = true,
              child: const Text('完整课程名称与成绩信息，不折射业务文字'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.textContaining('完整课程名称'));
    expect(clicked, isTrue);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });
  test('玻璃档位：无障碍实色，简化与未就绪磨砂，自动跟随实测，满档异常退出后降为标准', () {
    CampusGlassTier tier(
      CampusGlassMode mode, {
      liquid.GlassQuality? adaptive,
      bool capped = false,
      bool ready = true,
      bool accessible = false,
    }) => resolveCampusGlassTier(
      mode: mode,
      adaptive: adaptive,
      capped: capped,
      ready: ready,
      accessible: accessible,
    );
    for (final mode in CampusGlassMode.values) {
      expect(tier(mode, accessible: true), CampusGlassTier.solid);
      expect(tier(mode, ready: false), CampusGlassTier.minimal);
    }
    expect(tier(CampusGlassMode.reduced), CampusGlassTier.minimal);
    expect(tier(CampusGlassMode.full, adaptive: liquid.GlassQuality.minimal), CampusGlassTier.full);
    expect(tier(CampusGlassMode.full, capped: true), CampusGlassTier.standard);
    expect(tier(CampusGlassMode.auto), CampusGlassTier.full);
    expect(tier(CampusGlassMode.auto, adaptive: liquid.GlassQuality.premium), CampusGlassTier.full);
    expect(tier(CampusGlassMode.auto, adaptive: liquid.GlassQuality.standard), CampusGlassTier.standard);
    expect(tier(CampusGlassMode.auto, adaptive: liquid.GlassQuality.minimal), CampusGlassTier.minimal);
    expect(tier(CampusGlassMode.auto, adaptive: liquid.GlassQuality.premium, capped: true), CampusGlassTier.standard);
    expect(tier(CampusGlassMode.auto, adaptive: liquid.GlassQuality.minimal, capped: true), CampusGlassTier.minimal);
  });
  test('满档以iOS 27材质按配色着色，色散只给控件与浮层；标准档保持升级前参数', () {
    for (final palette in [...CampusPalette.values, ...CampusPalette.darkValues]) {
      for (final role in CampusGlassRole.values) {
        final full = campusGlassSettings(palette, role, CampusGlassTier.full);
        final preset = palette.isDark ? liquid.LiquidGlassSettings.ios27Dark : liquid.LiquidGlassSettings.ios27Light;
        expect(full.glassColor.withValues(alpha: 1), palette.glassTint.withValues(alpha: 1));
        expect(full.frost, preset.frost);
        expect(full.rimLight, preset.rimLight);
        expect(full.lensModel, liquid.GlassLensModel.paraxial);
        expect(full.platformViewFallbackColor, palette.glassFallback);
        expect(full.chromaticAberration, role == CampusGlassRole.navigation ? 0 : greaterThan(0));
        final standard = campusGlassSettings(palette, role, CampusGlassTier.standard);
        expect(standard.chromaticAberration, 0);
        expect(standard.frost, 0);
        expect(standard.glowIntensity, 0);
        // 浮层：完全雾化不透底层清晰副本；浅色在遮罩上整块均匀提亮（取值见模拟器实测），导航与控件不提亮。
        final overlay = role == CampusGlassRole.overlay;
        expect(full.frostOpacity, overlay ? 1 : preset.frostOpacity);
        for (final settings in [full, standard, campusGlassSettings(palette, role, CampusGlassTier.minimal)]) {
          expect(settings.whitenStrength, overlay && !palette.isDark ? .65 : 0, reason: '${palette.id} $role');
          expect(settings.whitenGated, isFalse);
        }
        // 无遮罩的浮层（菜单、提示条）带柔和投影；其余保持原有阴影。
        expect(full.shadow, preset.shadow);
        for (final tier in [CampusGlassTier.full, CampusGlassTier.standard, CampusGlassTier.minimal]) {
          final floating = campusGlassSettings(palette, role, tier, floating: true);
          if (overlay) expect(floating.shadow, campusFloatingShadow);
          if (!overlay && tier != CampusGlassTier.full) expect(floating.shadow, isNull);
        }
      }
      final pressed = campusGlassSettings(palette, CampusGlassRole.control, CampusGlassTier.full, pressed: true);
      expect(pressed.glassColor.withValues(alpha: 1), palette.surfaceSelected.withValues(alpha: 1));
    }
    final bar = campusGlassSettings(CampusPalette.values.first, CampusGlassRole.navigation, CampusGlassTier.standard, floating: true);
    expect([bar.thickness, bar.blur, bar.refractiveIndex, bar.lightIntensity, bar.shadowElevation], [16, 10, 1.15, .40, 1]);
    final button = campusGlassSettings(CampusPalette.values.first, CampusGlassRole.control, CampusGlassTier.standard);
    expect([button.thickness, button.blur, button.refractiveIndex, button.lightIntensity, button.ambientStrength], [8, 6, 1.10, .35, .16]);
    expect(campusGlassQuality(CampusGlassTier.full), liquid.GlassQuality.premium);
    expect(campusGlassQuality(CampusGlassTier.standard), liquid.GlassQuality.standard);
    expect(campusGlassQuality(CampusGlassTier.minimal), liquid.GlassQuality.minimal);
  });
  testWidgets('玻璃档位读取所在作用域的模式与限档，高对比和减少动画时实色', (tester) async {
    final tiers = <CampusGlassTier>[];
    Future<void> pump(CampusGlassMode mode, {bool capped = false, MediaQueryData media = const MediaQueryData()}) async {
      await tester.pumpWidget(MediaQuery(
        data: media,
        child: CampusGlassScope(
          mode: mode,
          capped: capped,
          child: Builder(builder: (context) {
            tiers.add(CampusGlassScope.tierOf(context, ready: true));
            return const SizedBox();
          }),
        ),
      ));
    }
    await pump(CampusGlassMode.reduced);
    await pump(CampusGlassMode.full, capped: true);
    await pump(CampusGlassMode.full, media: const MediaQueryData(highContrast: true));
    await pump(CampusGlassMode.auto, media: const MediaQueryData(disableAnimations: true));
    expect(tiers, [CampusGlassTier.minimal, CampusGlassTier.standard, CampusGlassTier.solid, CampusGlassTier.solid]);
  });
  group('浮层与控件玻璃', () {
    tearDown(() => campusGlassReady.value = false);
    Widget host(Widget home, {CampusGlassMode mode = CampusGlassMode.full}) => MaterialApp(theme: campusTheme(), home: CampusGlassScope(mode: mode, capped: false, child: home));

    testWidgets('弹窗玻璃面板与实色退路，打开期间顶栏改实色、关闭后恢复', (tester) async {
      campusGlassReady.value = true;
      late BuildContext page;
      await tester.pumpWidget(host(Scaffold(body: Builder(builder: (context) {
        page = context;
        return const GlassPanel(edge: GlassEdge.top, child: SizedBox(height: 56));
      }))));
      bool panelOpaque() => tester.widget<GlassPanelScope>(find.descendant(of: find.byType(GlassPanel), matching: find.byType(GlassPanelScope))).opaque;
      expect(panelOpaque(), isFalse);
      final confirm = showCampusConfirm(page, title: '删除记录？', message: '只移除记录。', action: '删除');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expectGlassUnfaded(find.descendant(of: find.byType(CampusOverlayGlass), matching: find.byType(liquid.AdaptiveGlass)));
      expect(find.byType(liquid.GlassMaterializeTransition), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(CampusGlassDialog), findsOneWidget);
      // 面板一层玻璃；面板内的按钮只做 vibrancy，不再叠第二层。
      expect(find.descendant(of: find.byType(CampusOverlayGlass), matching: find.byType(liquid.AdaptiveGlass)), findsOneWidget);
      expect(find.descendant(of: find.widgetWithText(FilledButton, '删除'), matching: find.byType(liquid.AdaptiveGlass)), findsNothing);
      expect(panelOpaque(), isTrue);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(await confirm, isTrue);
      expect(campusOverlayDepth.value, 0);
      expect(panelOpaque(), isFalse);
      showCampusDialog<void>(context: page, builder: (context) => CampusGlassDialog(solid: true, title: const Text('验证码'), options: [SimpleDialogOption(onPressed: () => Navigator.pop(context), child: const Text('选项一'))]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      // 实色面板没有玻璃，仍随路由进度淡入。
      expect(fadedOpacity(find.descendant(of: find.byType(CampusOverlayGlass), matching: find.byType(DecoratedBox)).first), inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(CampusOverlayGlass), matching: find.byType(liquid.AdaptiveGlass)), findsNothing);
      await tester.tap(find.text('选项一'));
      await tester.pumpAndSettle();
      expect(find.byType(CampusGlassDialog), findsNothing);
      // 日期选择器等系统弹窗不含玻璃面板，整体随进度淡入。
      showCampusDialog<void>(context: page, glassPanel: false, builder: (context) => const AlertDialog(content: Text('选择开学日')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(fadedOpacity(find.byType(AlertDialog)), inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('提示条为玻璃胶囊，撤销48dp可点并收起；未就绪为实色', (tester) async {
      campusGlassReady.value = true;
      late BuildContext page;
      var undone = 0;
      await tester.pumpWidget(host(Scaffold(body: Builder(builder: (context) => Center(child: TextButton(onPressed: () {
        page = context;
        showCampusToast(context, '已保存删除记录', action: '撤销', onAction: () => undone++);
      }, child: const Text('删除')))))));
      await tester.tap(find.text('删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final toast = find.widgetWithText(SnackBar, '已保存删除记录');
      expect(tester.widget<SnackBar>(toast).behavior, SnackBarBehavior.fixed);
      expectGlassUnfaded(find.descendant(of: toast, matching: find.byType(liquid.AdaptiveGlass)));
      await tester.pumpAndSettle();
      expect(toast, findsOneWidget);
      expect(find.descendant(of: toast, matching: find.byType(liquid.AdaptiveGlass)), findsOneWidget);
      expect(tester.getSize(find.widgetWithText(TextButton, '撤销')).height, greaterThanOrEqualTo(48));
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(undone, 1);
      expect(toast, findsNothing);
      campusGlassReady.value = false;
      showCampusToast(page, '删除未完成，请重试');
      await tester.pumpAndSettle();
      final solid = find.widgetWithText(SnackBar, '删除未完成，请重试');
      expect(solid, findsOneWidget);
      expect(find.descendant(of: solid, matching: find.byType(liquid.AdaptiveGlass)), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('选择标签选中带勾可切换，开关行整行可点且读屏为开关', (tester) async {
      var selected = false, enabled = false;
      await tester.pumpWidget(host(Scaffold(body: StatefulBuilder(builder: (context, setState) => Column(children: [
        CampusGlassChip(label: '第一学期', selected: selected, onSelected: (value) => setState(() => selected = value)),
        CampusSwitchTile(title: const Text('保存解析历史'), value: enabled, onChanged: (value) => setState(() => enabled = value)),
      ])))));
      expect(find.byType(CampusIcon), findsNothing);
      await tester.tap(find.text('第一学期'));
      await tester.pumpAndSettle();
      expect(selected, isTrue);
      expect(find.descendant(of: find.byType(CampusGlassChip), matching: find.byType(CampusIcon)), findsOneWidget);
      final semantics = tester.ensureSemantics();
      expect(tester.getSemantics(find.byType(CampusSwitchTile)), isSemantics(hasToggledState: true, isToggled: false, hasTapAction: true, label: '保存解析历史'));
      expect(find.byType(Switch), findsOneWidget);
      await tester.tap(find.text('保存解析历史'));
      await tester.pumpAndSettle();
      expect(enabled, isTrue);
      semantics.dispose();
      campusGlassReady.value = true;
      await tester.pumpAndSettle();
      expect(find.byType(liquid.GlassSwitch), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('浅色玻璃开关关闭态：白色滑块对轨道不低于3:1，且与开启轨道可分', (tester) async {
      campusGlassReady.value = true;
      double contrast(Color a, Color b) {
        final first = a.computeLuminance(), second = b.computeLuminance();
        return (first > second ? first + .05 : second + .05) / (first > second ? second + .05 : first + .05);
      }
      for (final palette in CampusPalette.values) {
        await tester.pumpWidget(MaterialApp(key: ValueKey(palette.id), theme: campusTheme(palette: palette), home: CampusGlassScope(mode: CampusGlassMode.full, capped: false, child: Scaffold(body: CampusSwitchTile(title: const Text('保存解析历史'), value: false, onChanged: (_) {})))));
        final glassSwitch = tester.widget<liquid.GlassSwitch>(find.byType(liquid.GlassSwitch));
        expect(contrast(glassSwitch.thumbColor, glassSwitch.inactiveColor!), greaterThanOrEqualTo(3), reason: palette.id);
        expect(contrast(glassSwitch.activeColor!, glassSwitch.inactiveColor!), greaterThanOrEqualTo(1.8), reason: palette.id);
      }
    });
  });

  group('玻璃菜单与底部弹层', () {
    tearDown(() => campusGlassReady.value = false);
    const items = [
      CampusMenuItem(value: 'cancel', label: '取消全部', icon: CampusIcons.close),
      CampusMenuItem(value: 'delete', label: '删除记录', icon: CampusIcons.manage),
    ];
    Widget host(Widget body, {bool reduceMotion = false}) => MaterialApp(
      theme: campusTheme(),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion), child: child!),
      home: CampusGlassScope(mode: CampusGlassMode.full, capped: false, child: Scaffold(body: body)),
    );
    double menuScale(WidgetTester tester) => tester.widget<Transform>(find.ancestor(of: find.byType(CampusOverlayGlass), matching: find.byType(Transform)).first).transform.getMaxScaleOnAxis();

    testWidgets('菜单为路由：点选返回值，返回键只关菜单，期间栏改实色；展开过冲一次后回位', (tester) async {
      campusGlassReady.value = true;
      late BuildContext anchor;
      final results = <String?>[];
      await tester.pumpWidget(host(Center(child: Builder(builder: (context) {
        anchor = context;
        return TextButton(onPressed: () => showCampusMenu<String>(context, items: items, selected: 'delete').then(results.add), child: const Text('更多'));
      }))));
      await tester.tap(find.text('更多'));
      await tester.pump();
      var peak = 0.0;
      for (var frame = 0; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        peak = math.max(peak, menuScale(tester));
        if (frame == 6) {
          expectGlassUnfaded(find.descendant(of: find.byType(CampusOverlayGlass), matching: find.byType(liquid.AdaptiveGlass)));
          expect(find.byType(liquid.GlassMaterializeTransition), findsOneWidget);
        }
      }
      await tester.pumpAndSettle();
      expect(peak, greaterThan(1.0));
      expect(menuScale(tester), moreOrLessEquals(1, epsilon: 1e-3));
      expect(campusOverlayDepth.value, 1);
      expect(find.descendant(of: find.byType(CampusOverlayGlass), matching: find.byType(liquid.AdaptiveGlass)), findsOneWidget);
      final row = find.ancestor(of: find.text('删除记录'), matching: find.byType(InkWell)).first;
      expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
      expect(find.descendant(of: row, matching: find.byIcon(CampusIcons.check)), findsOneWidget);
      expect(tester.getSemantics(find.text('删除记录')), isSemantics(isSelected: true, hasSelectedState: true, isButton: true, hasTapAction: true, label: '删除记录'));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('取消全部'), findsNothing);
      expect(find.text('更多'), findsOneWidget);
      expect(campusOverlayDepth.value, 0);
      await tester.tap(find.text('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消全部'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更多'));
      await tester.pumpAndSettle();
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      expect(results, [null, 'cancel', null]);
      expect(anchor.mounted, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('减少动画时菜单直接到位不缩放；靠右下角向上、右对齐且不出屏', (tester) async {
      // 按钮离右缘100：左对齐会被屏幕夹回，只有右缘对齐时菜单右缘才与按钮一致。
      await tester.pumpWidget(host(reduceMotion: true, Align(alignment: Alignment.bottomRight, child: Padding(padding: const EdgeInsets.only(right: 100), child: Builder(builder: (context) => IconButton(tooltip: '更多操作', onPressed: () => showCampusMenu<String>(context, items: items), icon: const CampusIcon(CampusIcons.manage)))))));
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pump();
      expect(menuScale(tester), 1);
      final anchor = tester.getRect(find.byType(IconButton));
      final menu = tester.getRect(find.byType(CampusOverlayGlass));
      final screen = tester.getRect(find.byType(Scaffold));
      expect(menu.bottom, lessThanOrEqualTo(anchor.top));
      expect(menu.right, moreOrLessEquals(anchor.right));
      expect(menu.width, greaterThanOrEqualTo(200));
      expect(screen.deflate(12).contains(menu.topLeft), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('下拉字段：标签外观、等宽菜单、只在值变化时回调、禁用不弹出', (tester) async {
      final changes = <int>[];
      var enabled = true;
      await tester.pumpWidget(host(StatefulBuilder(builder: (context, setState) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          CampusMenuField<int>(label: '开始节次', value: 2, items: [for (var period = 1; period <= 3; period++) CampusMenuItem(value: period, label: '第$period节')], onChanged: enabled ? changes.add : null),
          TextButton(onPressed: () => setState(() => enabled = false), child: const Text('禁用')),
        ]),
      ))));
      expect(find.descendant(of: find.byType(InputDecorator), matching: find.text('开始节次')), findsOneWidget);
      expect(find.text('第2节'), findsOneWidget);
      await tester.tap(find.text('第2节'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(CampusOverlayGlass)).width, tester.getSize(find.byType(CampusMenuField<int>)).width);
      await tester.tap(find.text('第2节').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('第2节'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第3节'));
      await tester.pumpAndSettle();
      expect(changes, [3]);
      await tester.tap(find.text('禁用'));
      await tester.pump();
      await tester.tap(find.byType(CampusMenuField<int>));
      await tester.pumpAndSettle();
      expect(find.byType(CampusOverlayGlass), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('底部弹层为悬浮玻璃面板，返回键关闭，期间栏改实色', (tester) async {
      // 手机宽度；宽于640时系统弹层按M3居中限宽，边距另算。
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      campusGlassReady.value = true;
      await tester.pumpWidget(host(Builder(builder: (context) => Center(child: TextButton(
        onPressed: () => showCampusSheet<void>(context: context, builder: (context) => DraggableScrollableSheet(
          expand: false,
          builder: (context, controller) => CampusSheetPanel(child: ListView(controller: controller, children: const [Text('原始成绩记录')])),
        )),
        child: const Text('详情'),
      )))));
      await tester.tap(find.text('详情'));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(CampusSheetPanel), matching: find.byType(liquid.AdaptiveGlass)), findsOneWidget);
      final panel = tester.getRect(find.byType(CampusOverlayGlass));
      final screen = tester.getRect(find.byType(Scaffold));
      expect([panel.left, screen.right - panel.right, screen.bottom - panel.bottom], [8, 8, 8]);
      expect(campusOverlayDepth.value, 1);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('原始成绩记录'), findsNothing);
      expect(campusOverlayDepth.value, 0);
      expect(tester.takeException(), isNull);
    });
  });
}
