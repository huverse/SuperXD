import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:math';

import 'package:amap_map/amap_map.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
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

// 定位结果慢于这个时间就提示可以先手动点选（高德联网定位不通时首次结果要半分钟才退回 GPS），但不停止等待。
const _slowFix = Duration(seconds: 15);

// [人工决策-2026-10-14 21:26:16] 位置签到默认选中的位置（用户选定参考项目同款，取代 10-14 15:58:13「落点按 签到点 → 已选 →
// 上次地图选点 → 最近收藏、只在点「定位到我」时申请定位权限」）：签到弹层里直接嵌地图，默认选中 这门课上次签到用的位置 →
// 上次签到用的位置 → 当前位置；进位置签到就申请定位权限（仅使用期间），拒绝了照样能点地图、选收藏或手输。老师设了签到点就画范围圈。
// 高德 SDK 的合规声明与 key：地图是它唯一的用武之地，每次建地图前先按用户已同意的口径声明一次再初始化。
void _initAmap(BuildContext context) {
  AMapInitializer.updatePrivacyAgree(const AMapPrivacyStatement(hasContains: true, hasShow: true, hasAgree: true));
  AMapInitializer.init(context, apiKey: const AMapApiKey(androidKey: chaoxingAmapKey));
}

// 申请定位权限（仅使用期间）。explain 为真（用户点了「定位到我」）时没给就说原因；进签到页的自动申请不打扰。
Future<bool> _locationPermitted(BuildContext context, {required bool explain}) async {
  final PermissionStatus status;
  try {
    status = await Permission.locationWhenInUse.request();
  } catch (error, stack) {
    // 权限请求是原生调用，出错就按没有权限处理：照样能点选、选收藏或手输。
    campusLog('[ChaoxingMap] action=locate errorType=${error.runtimeType}\n$stack');
    return false;
  }
  campusLog('[ChaoxingMap] action=locate permission=${status.name} explain=$explain');
  if (status.isGranted || status.isLimited) return true;
  if (explain && context.mounted) {
    final blocked = status.isPermanentlyDenied;
    showCampusToast(
      context,
      blocked ? '定位权限已关闭，可在系统设置里打开，也可以直接点选' : '没有定位权限，可以直接在地图上点选',
      action: blocked ? '去设置' : null,
      onAction: blocked
          ? () => unawaited(
              openAppSettings().then((_) {}, onError: (Object error, StackTrace stack) {
                campusLog('[ChaoxingMap] action=open_settings errorType=${error.runtimeType}\n$stack');
              }),
            )
          : null,
    );
  }
  return false;
}

// 移镜头只是视觉跟随，原生侧失败不影响选点：记下来，不打断用户。
void _moveCamera(AMapController? map, LatLng target) {
  map?.moveCamera(CameraUpdate.newLatLngZoom(target, 17)).catchError((Object error, StackTrace stack) {
    campusLog('[ChaoxingMap] action=move_camera errorType=${error.runtimeType}\n$stack');
  });
}

// 高德定位图层回报的位置；定位失败时回报的是 0,0，当没有。日志不记坐标，只记来源与精度。
LatLng? _fixOf(AMapLocation location) {
  final point = location.latLng;
  final empty = point.latitude == 0 && point.longitude == 0;
  campusLog('[ChaoxingMap] action=locate result=${empty ? 'empty' : 'fix'} provider=${location.provider} accuracy=${location.accuracy.round()}');
  return empty ? null : point;
}

// 地图按 GCJ-02 画：收藏里存的可能是 BD-09 或 WGS-84，先换算过来。没有位置时是全国视角的中心。
LatLng _target(ChaoxingLocation? location) {
  if (location == null) return const LatLng(34.5, 108.9);
  if (location.system == ChaoxingCoordinateSystem.gcj02) {
    return LatLng(location.latitude, location.longitude);
  }
  final gcj02 = toGcj02(location.latitude, location.longitude, location.system);
  return LatLng(gcj02.latitude, gcj02.longitude);
}

ChaoxingLocation _gcjLocation(LatLng point, String address) =>
    ChaoxingLocation(latitude: point.latitude, longitude: point.longitude, address: address, system: ChaoxingCoordinateSystem.gcj02);

// 签到范围圈的多边形逼近：36 个点连一圈（纬度每米约 1/111320 度，经度再除 cos 纬度）。
Set<Polygon> _rangePolygon(CampusPalette palette, ChaoxingLocation? center, double? meters) {
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

// 地图上的浮动小按钮与提示：地图是原生视图，不叠玻璃（模糊取不到地图内容），用近不透明的表面色。
Widget _mapChip(CampusPalette palette, Widget child) => DecoratedBox(
  decoration: BoxDecoration(color: palette.surface.withValues(alpha: .92), borderRadius: BorderRadius.circular(16)),
  child: child,
);

// 签到弹层里嵌的地图（位置签到默认用它选点，见文件头的人工决策）：点一下地图选点；右上角「定位到我」与「全屏」。
// 建好就申请定位权限并打开高德定位图层；没有选中的位置时，第一次定位结果就是默认选中（自己点过地图就不再覆盖）。
// 选中的位置从外面变了（选了收藏、全屏页选点）镜头跟过去；本组件报出去的点不再挪镜头，免得点哪儿跳哪儿。
class ChaoxingInlineMap extends StatefulWidget {
  const ChaoxingInlineMap({
    super.key,
    required this.selected,
    required this.onPicked,
    required this.onExpand,
    this.rangeCenter,
    this.rangeMeters,
  });
  final ChaoxingLocation? selected;
  // 报出去的是 GCJ-02、名称为空的位置，名称由弹层的名称框决定。
  final ValueChanged<ChaoxingLocation> onPicked;
  final VoidCallback? onExpand;
  final ChaoxingLocation? rangeCenter;
  final double? rangeMeters;

  static const height = 240.0;

  @override
  State<ChaoxingInlineMap> createState() => _ChaoxingInlineMapState();
}

class _ChaoxingInlineMapState extends State<ChaoxingInlineMap> {
  AMapController? _map;
  bool _initialized = false;
  bool _locating = false;
  // 下一次定位结果要不要移镜头并选中：自动申请时只在还没选中位置时要，点「定位到我」时总要；自己点了地图就作罢。
  bool _wantFix = false;
  // 点了「定位到我」还在等结果：按钮原地转圈。
  bool _awaitingFix = false;
  LatLng? _lastFix;
  LatLng? _reported;
  Timer? _fixTimeout;
  // 覆盖物每建一次就是新 id，高德会删了重画；弹层别处一刷新（签到进度等）地图上的点就闪，所以按内容缓存。
  Set<Marker> _markers = const {};
  ChaoxingLocation? _markerFor;
  Set<Polygon> _polygons = const {};
  Object? _polygonsFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initAmap(context);
    _initialized = true;
    unawaited(_startLocating(explain: false));
  }

  @override
  void didUpdateWidget(ChaoxingInlineMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selected = widget.selected;
    if (selected == null || selected == oldWidget.selected) return;
    final target = _target(selected);
    if (target == _reported) return;
    // 外面换了位置（收藏、全屏选点）：之前等着的定位结果不再覆盖它。
    _wantFix = false;
    _moveCamera(_map, target);
  }

  @override
  void dispose() {
    _fixTimeout?.cancel();
    super.dispose();
  }

  Future<void> _startLocating({required bool explain}) async {
    if (!await _locationPermitted(context, explain: explain) || !mounted) return;
    final known = _lastFix;
    if (explain && known != null) {
      _report(known);
      return;
    }
    setState(() {
      _locating = true;
      _wantFix = explain || widget.selected == null;
      _awaitingFix = explain;
    });
    if (!explain) return;
    _fixTimeout?.cancel();
    _fixTimeout = Timer(_slowFix, () {
      if (!mounted || !_awaitingFix) return;
      campusLog('[ChaoxingMap] action=locate result=slow');
      setState(() => _awaitingFix = false);
      showCampusToast(context, '定位有点慢，可以先在地图上点选');
    });
  }

  // 定位图层会持续回报位置；只有等着的那一次移镜头并选中，之后不跟着拽，免得打断手动选点。
  void _onLocation(AMapLocation location) {
    final point = _fixOf(location);
    if (point == null) return;
    _lastFix = point;
    if (_wantFix) _report(point);
  }

  void _report(LatLng point) {
    _fixTimeout?.cancel();
    setState(() {
      _wantFix = false;
      _awaitingFix = false;
    });
    _moveCamera(_map, point);
    _reported = point;
    widget.onPicked(_gcjLocation(point, ''));
  }

  Set<Marker> _markerSet(ChaoxingLocation? selected) {
    if (selected != _markerFor) {
      _markerFor = selected;
      _markers = selected == null ? const <Marker>{} : {Marker(position: _target(selected), infoWindowEnable: false)};
    }
    return _markers;
  }

  Set<Polygon> _polygonSet(CampusPalette palette) {
    final key = (widget.rangeCenter, widget.rangeMeters, palette.accent);
    if (key != _polygonsFor) {
      _polygonsFor = key;
      _polygons = _rangePolygon(palette, widget.rangeCenter, widget.rangeMeters);
    }
    return _polygons;
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final selected = widget.selected;
    final start = selected ?? widget.rangeCenter;
    final hint = selected != null
        ? null
        : _wantFix
        ? '正在定位…'
        : '点一下地图选签到位置';
    return SizedBox(
      height: ChaoxingInlineMap.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            Positioned.fill(
              child: AMapWidget(
                initialCameraPosition: CameraPosition(target: _target(start), zoom: start == null ? 4 : 17),
                onMapCreated: (controller) => _map = controller,
                myLocationStyleOptions: MyLocationStyleOptions(_locating),
                onLocationChanged: _onLocation,
                compassEnabled: false,
                scaleEnabled: false,
                // 点 POI 会跳详情，选点用不着，关掉免得误触。
                touchPoiEnabled: false,
                // 弹层本身能上下拖：手指落在地图上时拖动归地图，弹层滚动从地图外面拖。
                gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)},
                // 自己点了就以点的为准，迟到的定位结果不再覆盖。
                onTap: (point) {
                  _fixTimeout?.cancel();
                  setState(() {
                    _wantFix = false;
                    _awaitingFix = false;
                  });
                  _reported = point;
                  widget.onPicked(_gcjLocation(point, ''));
                },
                markers: _markerSet(selected),
                polygons: _polygonSet(palette),
              ),
            ),
            if (hint != null)
              Positioned(
                left: 8,
                top: 8,
                child: _mapChip(
                  palette,
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Text(hint, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
                  ),
                ),
              ),
            Positioned(
              right: 8,
              top: 8,
              child: Column(
                children: [
                  _mapChip(
                    palette,
                    IconButton(
                      tooltip: _awaitingFix ? '正在定位' : '定位到我',
                      onPressed: _awaitingFix ? null : () => unawaited(_startLocating(explain: true)),
                      icon: _awaitingFix ? const CampusLoader(size: 20, delay: Duration.zero) : const CampusIcon(CampusIcons.locateMe),
                    ),
                  ),
                  if (widget.onExpand != null) ...[
                    const SizedBox(height: 8),
                    _mapChip(
                      palette,
                      IconButton(tooltip: '全屏选点', onPressed: widget.onExpand, icon: const CampusIcon(CampusIcons.fullscreen)),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 全屏地图选点：点一下地图拿到坐标，配一个名称，返回给签到弹层。
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
  AMapController? _map;
  // 点过「定位到我」并拿到权限后打开高德的定位图层。_wantFix：等下一次定位结果来移镜头并选中（自己点了地图就作罢）；
  // _awaitingFix：按钮原地转圈，最多 15 秒，过了只提示、不停止等待。
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
    _initAmap(context);
    _initialized = true;
  }

  @override
  void dispose() {
    _fixTimeout?.cancel();
    _label.dispose();
    super.dispose();
  }

  // 全屏页不自动定位：从签到弹层进来时已有选中的位置，要当前位置点「定位到我」（权限规则见文件头的人工决策）。
  Future<void> _locate() async {
    if (!await _locationPermitted(context, explain: true) || !mounted) return;
    setState(() {
      _locating = true;
      _wantFix = true;
      _awaitingFix = true;
    });
    _fixTimeout?.cancel();
    _fixTimeout = Timer(_slowFix, () {
      if (!mounted || !_awaitingFix) return;
      campusLog('[ChaoxingMap] action=locate result=slow');
      setState(() => _awaitingFix = false);
      showCampusToast(context, '定位有点慢，可以先在地图上点选');
    });
  }

  // 定位图层会持续回报位置；只有点了「定位到我」后的第一次结果移镜头并选中，之后不跟着拽，免得打断手动选点。
  void _onLocation(AMapLocation location) {
    if (!_wantFix) return;
    final point = _fixOf(location);
    if (point == null) return;
    _fixTimeout?.cancel();
    setState(() {
      _wantFix = false;
      _awaitingFix = false;
      _picked = point;
    });
    _moveCamera(_map, point);
  }

  void _confirm() {
    final picked = _picked;
    if (picked == null) return;
    final label = _label.text.trim();
    Navigator.pop(context, _gcjLocation(picked, label.isEmpty ? '地图选点' : label));
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final picked = _picked;
    // 落点：老师设的签到点 → 签到弹层里已选的位置 → 全国。
    final start = widget.rangeCenter ?? widget.initial;
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
              polygons: _rangePolygon(palette, widget.rangeCenter, widget.rangeMeters),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.topCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _mapChip(
                palette,
                Padding(
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
