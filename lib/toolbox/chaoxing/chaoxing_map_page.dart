import 'dart:ffi' show Abi;
import 'dart:math';

import 'package:amap_map/amap_map.dart';
import 'package:flutter/material.dart';
import 'package:x_amap_base/x_amap_base.dart';

import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';

// 高德 key 走构建参数（Android 平台 key，绑定包名与签名，不写进源码）：
// flutter build apk --dart-define=SUPERXD_AMAP_KEY=<key>。没传时地图不可用，位置仍可收藏或手输。
const chaoxingAmapKey = String.fromEnvironment('SUPERXD_AMAP_KEY');

// 高德地图 SDK 只带 armeabi-v7a 与 arm64-v8a 的原生库，x86 模拟器上加载不了
// （地图会黑屏并每 500 毫秒刷一次 UnsatisfiedLinkError），那里不显示地图入口。
bool get _isArmDevice => Abi.current() == Abi.androidArm64 || Abi.current() == Abi.androidArm;

bool get chaoxingMapAvailable => chaoxingAmapKey.isNotEmpty && _isArmDevice;

// 地图用不了时给用户一句原因：位置改用经纬度或收藏，不让人对着空白的地方猜。
String? get chaoxingMapUnavailableReason {
  if (chaoxingAmapKey.isEmpty) return '这个安装包没有带地图';
  if (!_isArmDevice) return '这台设备用不了地图';
  return null;
}

// 地图选点：点一下地图拿到坐标，配一个名称，返回给签到弹层。
// rangeCenter 与 rangeMeters 给出时画出签到范围圈（详情里的签到点与半径，坐标系任意，会先换算）。
Future<ChaoxingLocation?> openChaoxingMapPicker(
  BuildContext context, {
  ChaoxingLocation? initial,
  String? label,
  ChaoxingLocation? rangeCenter,
  double? rangeMeters,
}) => Navigator.of(context).push<ChaoxingLocation>(
  CampusPageRoute(
    builder: (_) => ChaoxingMapPage(initial: initial, initialLabel: label, rangeCenter: rangeCenter, rangeMeters: rangeMeters),
  ),
);

class ChaoxingMapPage extends StatefulWidget {
  const ChaoxingMapPage({super.key, this.initial, this.initialLabel, this.rangeCenter, this.rangeMeters});
  final ChaoxingLocation? initial;
  final String? initialLabel;
  final ChaoxingLocation? rangeCenter;
  final double? rangeMeters;
  @override
  State<ChaoxingMapPage> createState() => _ChaoxingMapPageState();
}

class _ChaoxingMapPageState extends State<ChaoxingMapPage> {
  final _label = TextEditingController();
  LatLng? _picked;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _label.text = widget.initialLabel ?? '';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    // 高德 SDK 的合规声明：本页是它唯一的用武之地，进来先按用户已同意的口径声明一次再初始化。
    AMapInitializer.updatePrivacyAgree(const AMapPrivacyStatement(hasContains: true, hasShow: true, hasAgree: true));
    AMapInitializer.init(context, apiKey: const AMapApiKey(androidKey: chaoxingAmapKey));
    _initialized = true;
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  // 地图按 GCJ-02 画：收藏里存的可能是 BD-09 或 WGS-84，先换算过来。
  LatLng _target(ChaoxingLocation? location) {
    if (location == null) return const LatLng(34.5, 108.9);
    if (location.system == ChaoxingCoordinateSystem.gcj02) {
      return LatLng(location.latitude, location.longitude);
    }
    final gcj02 = toGcj02(location.latitude, location.longitude, location.system);
    return LatLng(gcj02.latitude, gcj02.longitude);
  }

  // 范围圈的多边形逼近：36 个点连一圈（纬度每米约 1/111320 度，经度再除 cos 纬度）。
  Set<Polygon> _rangePolygon() {
    final center = widget.rangeCenter;
    final meters = widget.rangeMeters;
    if (center == null || meters == null) return const <Polygon>{};
    final target = _target(center);
    const edges = 36;
    final points = <LatLng>[];
    for (var index = 0; index < edges; index++) {
      final angle = index / edges * 2 * pi;
      points.add(
        LatLng(
          target.latitude + sin(angle) * meters / 111320,
          target.longitude + cos(angle) * meters / (111320 * cos(target.latitude * pi / 180)),
        ),
      );
    }
    return {
      Polygon(
        points: points,
        fillColor: const Color.fromARGB(31, 59, 130, 246),
        strokeColor: const Color.fromARGB(178, 59, 130, 246),
        strokeWidth: 2,
      ),
    };
  }

  void _confirm() {
    final picked = _picked;
    if (picked == null) return;
    final label = _label.text.trim();
    Navigator.pop(
      context,
      ChaoxingLocation(
        latitude: picked.latitude,
        longitude: picked.longitude,
        address: label.isEmpty ? '地图选点' : label,
        system: ChaoxingCoordinateSystem.gcj02,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final picked = _picked;
    return Scaffold(
      appBar: AppBar(
        title: const Text('在地图上选点'),
        leading: IconButton(
          tooltip: '返回',
          onPressed: () => Navigator.pop(context),
          icon: const CampusIcon(CampusIcons.back),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: AMapWidget(
              initialCameraPosition: CameraPosition(
                target: _target(widget.rangeCenter ?? widget.initial),
                zoom: widget.rangeCenter != null || widget.initial != null ? 17 : 4,
              ),
              compassEnabled: false,
              scaleEnabled: false,
              // 点 POI 会跳详情，选点用不着，关掉免得误触。
              touchPoiEnabled: false,
              onTap: (point) => setState(() => _picked = point),
              markers: picked == null ? const <Marker>{} : {Marker(position: picked, infoWindowEnable: false)},
              // 签到范围圈：老师定的签到点与半径画出来，选点时心里有数（没给范围就不画）。
              polygons: _rangePolygon(),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.topCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: DecoratedBox(
                decoration: BoxDecoration(color: palette.surface.withValues(alpha: .92), borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Text(
                    picked == null ? '在教室的位置点一下地图' : '已选 ${picked.latitude.toStringAsFixed(6)}, ${picked.longitude.toStringAsFixed(6)}',
                    style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ),
          // 底部留出高德 logo 的位置：合规要求 logo 可见，面板不压到它。
          Align(
            alignment: AlignmentDirectional.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 44),
              child: CampusSurface(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: campusFieldGap(context)),
                    TextField(
                      controller: _label,
                      decoration: const InputDecoration(labelText: '位置名称', helperText: '例如 知敬楼402，签到时会一起提交'),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      style: campusProminent,
                      onPressed: picked == null ? null : _confirm,
                      icon: const CampusIcon(CampusIcons.check),
                      label: const Text('用这个位置'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
