import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:math';

import 'package:amap_map/amap_map.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:x_amap_base/x_amap_base.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
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
// recent 是没有签到点也没有已选位置时的落点（上次地图选点或最近的收藏，见 ChaoxingController.mapStart）。
Future<ChaoxingLocation?> openChaoxingMapPicker(
  BuildContext context, {
  ChaoxingLocation? initial,
  ChaoxingLocation? recent,
  String? label,
  ChaoxingLocation? rangeCenter,
  double? rangeMeters,
}) => Navigator.of(context).push<ChaoxingLocation>(
  CampusPageRoute(
    builder: (_) => ChaoxingMapPage(initial: initial, recent: recent, initialLabel: label, rangeCenter: rangeCenter, rangeMeters: rangeMeters),
  ),
);

class ChaoxingMapPage extends StatefulWidget {
  const ChaoxingMapPage({super.key, this.initial, this.recent, this.initialLabel, this.rangeCenter, this.rangeMeters});
  final ChaoxingLocation? initial;
  final ChaoxingLocation? recent;
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
  AMapController? _map;
  // 点过「定位到我」并拿到权限后打开高德的定位图层。_wantFix：等下一次定位结果来移镜头并选中（自己点了地图就作罢）；
  // _awaitingFix：按钮原地转圈，最多 15 秒，过了只提示、不停止等待（高德联网定位不通时首次结果要半分钟才退回 GPS）。
  bool _locating = false;
  bool _wantFix = false;
  bool _awaitingFix = false;
  Timer? _fixTimeout;

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
    _fixTimeout?.cancel();
    _label.dispose();
    super.dispose();
  }

  // [人工决策-2026-10-14 15:58:13] 地图默认落点与「定位到我」（用户选定，取代 10-06「不申请定位权限」）：
  // 落点按 老师设的签到点 → 这次已选的位置 → 上次地图选点 → 最近的收藏 取，都没有才是全国；定位权限只在点「定位到我」时申请（仅使用期间），
  // 由高德定位图层取当前位置（GCJ-02，与地图同一坐标系），移过去并选中，不点不申请；拒绝也能照常点选。
  Future<void> _locate() async {
    final status = await Permission.locationWhenInUse.request();
    campusLog('[ChaoxingMap] action=locate permission=${status.name}');
    if (!mounted) return;
    if (!status.isGranted && !status.isLimited) {
      final blocked = status.isPermanentlyDenied;
      showCampusToast(
        context,
        blocked ? '定位权限已关闭，可在系统设置里打开，也可以直接点选' : '没有定位权限，可以直接在地图上点选',
        action: blocked ? '去设置' : null,
        onAction: blocked ? () => unawaited(openAppSettings()) : null,
      );
      return;
    }
    setState(() {
      _locating = true;
      _wantFix = true;
      _awaitingFix = true;
    });
    _fixTimeout?.cancel();
    _fixTimeout = Timer(const Duration(seconds: 15), () {
      if (!mounted || !_awaitingFix) return;
      campusLog('[ChaoxingMap] action=locate result=slow');
      setState(() => _awaitingFix = false);
      showCampusToast(context, '定位有点慢，可以先在地图上点选');
    });
  }

  // 定位图层会持续回报位置；只有点了「定位到我」后的第一次结果移镜头并选中，之后不跟着拽，免得打断手动选点。
  void _onLocation(AMapLocation location) {
    final point = location.latLng;
    if (!_wantFix) return;
    // 日志不记坐标，只记来源与精度；高德定位失败时回报的是 0,0。
    final empty = point.latitude == 0 && point.longitude == 0;
    campusLog('[ChaoxingMap] action=locate result=${empty ? 'empty' : 'fix'} provider=${location.provider} accuracy=${location.accuracy.round()}');
    if (empty) return;
    _fixTimeout?.cancel();
    setState(() {
      _wantFix = false;
      _awaitingFix = false;
      _picked = point;
    });
    unawaited(_map?.moveCamera(CameraUpdate.newLatLngZoom(point, 17)));
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
  Set<Polygon> _rangePolygon(CampusPalette palette) {
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
        // 范围圈用当前配色的激活色（与开关、选中同一个色），不写死颜色。
        fillColor: palette.accent.withValues(alpha: .12),
        strokeColor: palette.accent.withValues(alpha: .7),
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
    final start = widget.rangeCenter ?? widget.initial ?? widget.recent;
    return Scaffold(
      appBar: AppBar(
        title: const Text('在地图上选点'),
        leading: IconButton(
          tooltip: '返回',
          onPressed: () => Navigator.pop(context),
          icon: const CampusIcon(CampusIcons.back),
        ),
        actions: [
          IconButton(
            tooltip: _awaitingFix ? '正在定位' : '定位到我',
            onPressed: _awaitingFix ? null : () => unawaited(_locate()),
            icon: _awaitingFix ? const CampusLoader(size: 20, delay: Duration.zero) : const CampusIcon(CampusIcons.locateMe),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: AMapWidget(
              initialCameraPosition: CameraPosition(
                target: _target(start),
                zoom: start == null ? 4 : 17,
              ),
              onMapCreated: (controller) => _map = controller,
              myLocationStyleOptions: MyLocationStyleOptions(_locating),
              onLocationChanged: _onLocation,
              compassEnabled: false,
              scaleEnabled: false,
              // 点 POI 会跳详情，选点用不着，关掉免得误触。
              touchPoiEnabled: false,
              // 自己点了就以点的为准，迟到的定位结果不再覆盖。
              onTap: (point) => setState(() {
                _picked = point;
                _wantFix = false;
                _awaitingFix = false;
              }),
              markers: picked == null ? const <Marker>{} : {Marker(position: picked, infoWindowEnable: false)},
              // 签到范围圈：老师定的签到点与半径画出来，选点时心里有数（没给范围就不画）。
              polygons: _rangePolygon(palette),
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
