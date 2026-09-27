import 'package:flutter/material.dart';

// [人工决策-2026-09-25 17:43:48] 配色是设备级完整色彩角色，默认苔灰；允许雾蓝、藕粉、暮紫、燕麦，不只替换按钮。
class CampusPalette extends ThemeExtension<CampusPalette> {
  const CampusPalette({
    required this.id,
    required this.label,
    required this.primary,
    required this.backgroundTop,
    required this.backgroundBottom,
    required this.surface,
    required this.surfaceSelected,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.outline,
    required this.outlineSubtle,
    required this.glassTint,
    required this.glassFallback,
    required this.fogSage,
    required this.fogChampagne,
    required this.fogPearl,
  });
  final String id;
  final String label;
  final Color primary;
  Color get onPrimary => Colors.white;
  Color get danger => const Color(0xFFBA1A1A);
  final Color backgroundTop;
  final Color backgroundBottom;
  final Color surface;
  final Color surfaceSelected;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color outline;
  final Color outlineSubtle;
  final Color glassTint;
  final Color glassFallback;
  final Color fogSage;
  final Color fogChampagne;
  // [人工决策-2026-09-25 20:18:09] 五套主题保留；云雾加入主题适配的珠光冷暖层次，不改变文字、卡片遮色或用户显示设置。
  final Color fogPearl;
  static CampusPalette of(BuildContext context) =>
      Theme.of(context).extension<CampusPalette>() ?? values.first;
  static CampusPalette byId(String id) =>
      values.firstWhere((palette) => palette.id == id);
  static const values = [
    CampusPalette(
      id: 'sage',
      label: '苔灰',
      primary: Color(0xFF49584E),
      backgroundTop: Color(0xFFF1F0ED),
      backgroundBottom: Color(0xFFE8E7E3),
      surface: Color(0xFFF9F8F5),
      surfaceSelected: Color(0xFFE1E5DC),
      onSurface: Color(0xFF292B2A),
      onSurfaceVariant: Color(0xFF565B57),
      outline: Color(0xFF7C827A),
      outlineSubtle: Color(0xFFD5D8CF),
      glassTint: Color(0xFFF0F0E9),
      glassFallback: Color(0xFFECECE6),
      fogSage: Color(0xFFA9C8BA),
      fogChampagne: Color(0xFFE3C4A6),
      fogPearl: Color(0xFFC6BDDB),
    ),
    CampusPalette(
      id: 'mist',
      label: '雾蓝',
      primary: Color(0xFF3F566C),
      backgroundTop: Color(0xFFEFF3F5),
      backgroundBottom: Color(0xFFDFE7EE),
      surface: Color(0xFFF6F9FC),
      surfaceSelected: Color(0xFFD7E4F0),
      onSurface: Color(0xFF252D36),
      onSurfaceVariant: Color(0xFF4F5D6A),
      outline: Color(0xFF778794),
      outlineSubtle: Color(0xFFCDD8E2),
      glassTint: Color(0xFFEDF3F9),
      glassFallback: Color(0xFFE5ECF3),
      fogSage: Color(0xFF9DCBE0),
      fogChampagne: Color(0xFFE2BDD0),
      fogPearl: Color(0xFFBEC1E4),
    ),
    CampusPalette(
      id: 'rose',
      label: '藕粉',
      primary: Color(0xFF76525F),
      backgroundTop: Color(0xFFF6F0F0),
      backgroundBottom: Color(0xFFEEDFE3),
      surface: Color(0xFFFCF7F8),
      surfaceSelected: Color(0xFFEBD7E0),
      onSurface: Color(0xFF33292E),
      onSurfaceVariant: Color(0xFF66545D),
      outline: Color(0xFF987C87),
      outlineSubtle: Color(0xFFE1CCD3),
      glassTint: Color(0xFFF5EBEF),
      glassFallback: Color(0xFFF0E4E8),
      fogSage: Color(0xFFE5BACE),
      fogChampagne: Color(0xFFE8C7AB),
      fogPearl: Color(0xFF90CDE6),
    ),
    CampusPalette(
      id: 'dusk',
      label: '暮紫',
      primary: Color(0xFF605275),
      backgroundTop: Color(0xFFF2F0F7),
      backgroundBottom: Color(0xFFE5DFEF),
      surface: Color(0xFFF9F7FC),
      surfaceSelected: Color(0xFFE1D7EE),
      onSurface: Color(0xFF2E2937),
      onSurfaceVariant: Color(0xFF5D546B),
      outline: Color(0xFF8C7F9C),
      outlineSubtle: Color(0xFFD6CDE3),
      glassTint: Color(0xFFF0ECF8),
      glassFallback: Color(0xFFEAE4F2),
      fogSage: Color(0xFFC4B2DF),
      fogChampagne: Color(0xFFE2BED0),
      fogPearl: Color(0xFFACCDD8),
    ),
    CampusPalette(
      id: 'oat',
      label: '燕麦',
      primary: Color(0xFF70563A),
      backgroundTop: Color(0xFFF6F2EA),
      backgroundBottom: Color(0xFFECE1D0),
      surface: Color(0xFFFCF9F2),
      surfaceSelected: Color(0xFFEBDDCA),
      onSurface: Color(0xFF342D24),
      onSurfaceVariant: Color(0xFF64594B),
      outline: Color(0xFF95836B),
      outlineSubtle: Color(0xFFDFD2BF),
      glassTint: Color(0xFFF4EDE0),
      glassFallback: Color(0xFFEFE6D8),
      fogSage: Color(0xFFE2C39D),
      fogChampagne: Color(0xFFBDD0B5),
      fogPearl: Color(0xFFC8BADE),
    ),
  ];
  @override
  CampusPalette copyWith({
    Color? primary,
    Color? backgroundTop,
    Color? backgroundBottom,
    Color? surface,
    Color? surfaceSelected,
    Color? onSurface,
    Color? onSurfaceVariant,
    Color? outline,
    Color? outlineSubtle,
    Color? glassTint,
    Color? glassFallback,
    Color? fogSage,
    Color? fogChampagne,
    Color? fogPearl,
  }) => CampusPalette(
    id: id,
    label: label,
    primary: primary ?? this.primary,
    backgroundTop: backgroundTop ?? this.backgroundTop,
    backgroundBottom: backgroundBottom ?? this.backgroundBottom,
    surface: surface ?? this.surface,
    surfaceSelected: surfaceSelected ?? this.surfaceSelected,
    onSurface: onSurface ?? this.onSurface,
    onSurfaceVariant: onSurfaceVariant ?? this.onSurfaceVariant,
    outline: outline ?? this.outline,
    outlineSubtle: outlineSubtle ?? this.outlineSubtle,
    glassTint: glassTint ?? this.glassTint,
    glassFallback: glassFallback ?? this.glassFallback,
    fogSage: fogSage ?? this.fogSage,
    fogChampagne: fogChampagne ?? this.fogChampagne,
    fogPearl: fogPearl ?? this.fogPearl,
  );
  @override
  CampusPalette lerp(covariant CampusPalette? other, double t) {
    if (other == null) return this;
    Color blend(Color a, Color b) => Color.lerp(a, b, t)!;
    return CampusPalette(
      id: other.id,
      label: other.label,
      primary: blend(primary, other.primary),
      backgroundTop: blend(backgroundTop, other.backgroundTop),
      backgroundBottom: blend(backgroundBottom, other.backgroundBottom),
      surface: blend(surface, other.surface),
      surfaceSelected: blend(surfaceSelected, other.surfaceSelected),
      onSurface: blend(onSurface, other.onSurface),
      onSurfaceVariant: blend(onSurfaceVariant, other.onSurfaceVariant),
      outline: blend(outline, other.outline),
      outlineSubtle: blend(outlineSubtle, other.outlineSubtle),
      glassTint: blend(glassTint, other.glassTint),
      glassFallback: blend(glassFallback, other.glassFallback),
      fogSage: blend(fogSage, other.fogSage),
      fogChampagne: blend(fogChampagne, other.fogChampagne),
      fogPearl: blend(fogPearl, other.fogPearl),
    );
  }
}
