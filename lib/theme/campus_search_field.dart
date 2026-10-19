import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';

// 搜索框：胶囊形（同 iOS 搜索栏），底色与描边同卡片 CampusSurface，高度同旁边的胶囊按钮（视觉约 38dp，大字号时随文字长高）；
// 用占位文字不用浮动标签（标签凸出会顶破胶囊上沿），有字时右侧出「清空搜索」：紧凑图标按钮约 40dp，
// 与搜索图标同占一样的高度，出现时高度不跳。
class CampusSearchField extends StatelessWidget {
  const CampusSearchField({super.key, required this.controller, required this.hint});
  final TextEditingController controller;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final opaque = MediaQuery.highContrastOf(context) || MediaQuery.accessibleNavigationOf(context);
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide(color: palette.surfaceBorder));
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => TextField(
        controller: controller,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: hint,
          filled: true,
          fillColor: palette.surface.withValues(alpha: opaque ? 1 : .91),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          prefixIcon: const CampusIcon(CampusIcons.search, size: 20),
          prefixIconConstraints: const BoxConstraints(minWidth: 44, minHeight: 40),
          suffixIcon: controller.text.isEmpty ? null : IconButton(tooltip: '清空搜索', visualDensity: VisualDensity.compact, onPressed: controller.clear, icon: const CampusIcon(CampusIcons.close, size: 20)),
          suffixIconConstraints: const BoxConstraints(minWidth: 44, minHeight: 40),
          border: border,
          enabledBorder: border,
          focusedBorder: border.copyWith(borderSide: BorderSide(color: palette.primary)),
        ),
      ),
    );
  }
}
