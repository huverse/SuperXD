import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:morphnext/morphnext.dart';

import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/curve_geometry.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  configureCampusIcons();
  runApp(const _Preview());
}

class _Preview extends StatefulWidget {
  const _Preview();
  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  bool _selected = false;
  bool _reduced = false;
  bool _busy = false;
  double _progress = .5;
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: campusTheme(),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: _reduced),
      child: CampusMotion(child: child!),
    ),
    home: Scaffold(
      appBar: AppBar(title: const Text('隔离动效验收')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SwitchListTile(
              title: const Text('减少动态效果'),
              value: _reduced,
              onChanged: (value) => setState(() => _reduced = value),
            ),
            FilledButton(
              onPressed: () => setState(() => _selected = !_selected),
              child: const Text('切换图标（可快速反向）'),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  CampusMorphIcon(
                    from: CampusIcons.today,
                    to: CampusIcons.todaySelected,
                    selected: _selected,
                    size: 48,
                  ),
                  CampusMorphIcon(
                    from: CampusIcons.services,
                    to: CampusIcons.servicesSelected,
                    selected: _selected,
                    size: 48,
                  ),
                  CampusMorphIcon(
                    from: CampusIcons.messages,
                    to: CampusIcons.messagesSelected,
                    selected: _selected,
                    size: 48,
                  ),
                  CampusMorphIcon(
                    from: CampusIcons.account,
                    to: CampusIcons.accountSelected,
                    selected: _selected,
                    size: 48,
                  ),
                ],
              ),
            ),
            const Text('真实矢量形变中间帧'),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final value in [0.0, .25, .5, .75, 1.0])
                  Column(
                    children: [
                      MorphIcon(
                        from: CampusIcons.services,
                        to: CampusIcons.servicesSelected,
                        progress: AlwaysStoppedAnimation(value),
                        size: 44,
                      ),
                      Text('$value'),
                    ],
                  ),
              ],
            ),
            Slider(
              value: _progress,
              onChanged: (value) => setState(() => _progress = value),
            ),
            Center(
              child: MorphIcon(
                from: CampusIcons.search,
                to: CampusIcons.close,
                progress: AlwaysStoppedAnimation(_progress),
                size: 64,
              ),
            ),
            const SizedBox(height: 20),
            for (final curve in CampusCurve.values)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    CampusLoader(curve: curve, size: 24, delay: Duration.zero),
                    CampusLoader(curve: curve, size: 56, delay: Duration.zero),
                    Text(curve.name),
                  ],
                ),
              ),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      await Future<void>.delayed(const Duration(seconds: 10));
                      if (mounted) setState(() => _busy = false);
                    },
              child: CampusBusyContent(
                busy: _busy,
                label: '模拟保存',
                busyLabel: '保存中',
                icon: const CampusIcon(CampusIcons.check),
              ),
            ),
            const CampusLoading(label: '模拟正在同步成绩', inline: true, network: true),
            TextButton(
              onPressed: () async {
                final manifest = await rootBundle.loadString(
                  'FontManifest.json',
                );
                debugPrint(
                  '[MotionPreview] lucideFont=${manifest.contains('Lucide')} morphs=${MorphCache.currentMorphs} bytes=${MorphCache.currentBytes}',
                );
              },
              child: const Text('检查字体与形变缓存'),
            ),
          ],
        ),
      ),
    ),
  );
}
