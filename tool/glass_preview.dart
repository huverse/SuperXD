import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:superxd/theme/campus_background.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/page/shell_page.dart';
import 'package:superxd/domain/campus_log.dart';

void main() {
  campusLog = debugPrint;
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      theme: campusTheme(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) =>
          CampusMotion(child: CampusAtmosphere(child: child!)),
      home: const _Preview(),
    ),
  );
  unawaited(initializeCampusGlass());
}

class _Preview extends StatefulWidget {
  const _Preview();
  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  int _selected = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(20, 80, 20, 160),
          children: [
            Text('珍珠灰 · 液态玻璃探针', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 24),
            for (var index = 0; index < 12; index++)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: CampusSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '课程 ${index + 1} · 阅读表面',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text('09:00–10:40\n克制流光，清楚的信息，柔和的边缘。'),
                    ],
                  ),
                ),
              ),
          ],
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: MediaQuery.paddingOf(context).bottom + 12,
          child: GlassPanel(
            edge: GlassEdge.top,
            floating: true,
            child: DragNavigationBar(
              selected: _selected,
              onSelected: (value) => setState(() => _selected = value),
            ),
          ),
        ),
      ],
    ),
  );
}
