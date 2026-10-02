import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;

import 'package:superxd/theme/campus_glass_material.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/page/licenses_page.dart';
import 'package:superxd/theme/campus_background.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_surface.dart';

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
}
