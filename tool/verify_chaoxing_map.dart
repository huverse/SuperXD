import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_background.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_map_page.dart';

// 手动验证：高德地图选点能不能出图、点得动、返回坐标（不进 CI）。
// 运行：flutter run -t tool/verify_chaoxing_map.dart -d <设备> --dart-define=SUPERXD_AMAP_KEY=<高德Android平台key>
// key 必须绑定这台设备的调试签名 SHA1 与包名 com.superxd.superxd，否则地图白屏并打印 key 校验失败。
void main() {
  campusLog = debugPrint;
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      theme: campusTheme(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => CampusMotion(child: CampusAtmosphere(child: child!)),
      home: const _MapProbe(),
    ),
  );
}

class _MapProbe extends StatefulWidget {
  const _MapProbe();
  @override
  State<_MapProbe> createState() => _MapProbeState();
}

class _MapProbeState extends State<_MapProbe> {
  ChaoxingLocation? _picked;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CampusSurface(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('地图 key：${chaoxingMapAvailable ? '已配置' : '没有配置（用 --dart-define 传）'}', style: const TextStyle(fontSize: 14)),
                  const SizedBox(height: 8),
                  Text(
                    _picked == null
                        ? '还没选点'
                        : '${_picked!.address} · ${_picked!.formattedLatitude}, ${_picked!.formattedLongitude}（gcj02）',
                    style: const TextStyle(fontSize: 14),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () async {
                final picked = await openChaoxingMapPicker(context, label: '测试位置');
                if (!mounted) return;
                setState(() => _picked = picked);
              },
              child: const Text('打开地图选点'),
            ),
          ],
        ),
      ),
    ),
  );
}
