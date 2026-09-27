import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/glass_panel.dart';

class SchedulePlaceholderPage extends StatelessWidget {
  const SchedulePlaceholderPage({super.key});

  @override
  Widget build(BuildContext context) {
    return CampusBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          children: [
            GlassPanel(
              edge: GlassEdge.bottom,
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: 56,
                  child: Row(
                    children: [
                      IconButton(onPressed: () => context.pop(), icon: CampusIcon(CampusIcons.back, color: CampusPalette.of(context).onSurface)),
                      Text('课表', style: Theme.of(context).textTheme.titleLarge),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('课表钻取下一期做。', style: TextStyle(fontSize: 16, color: CampusPalette.of(context).onSurface)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
