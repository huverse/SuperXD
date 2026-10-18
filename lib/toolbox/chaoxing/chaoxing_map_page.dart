import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:math';

import 'package:amap_map/amap_map.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

// [人工决策-2026-10-15 22:39:57] 定位来的选点跟着变准、不画精度圈（用户在 OPPO 真机上看到室内只有约 550 米的网络定位后选定，
// 同钉钉打卡持续更新位置、微信发位置只画定位点）：嵌着的地图选中的是定位结果时，30 秒内来了更准的结果（精度数值更小）就换过去；
// 自己点了地图、选了收藏或全屏选了点就不再动。高德默认的精度圈不画（粗定位时会把整张小地图染色），图上只留老师的签到范围圈。
const _refineWindow = Duration(seconds: 30);

typedef _Fix = ({LatLng point, double accuracy});

MyLocationStyleOptions _myLocationStyle(bool enabled) =>
    MyLocationStyleOptions(enabled, circleFillColor: Colors.transparent, circleStrokeColor: Colors.transparent, circleStrokeWidth: 0);

// [人工决策-2026-10-15 22:39:57] 系统定位关着时（用户选定，同高德、美团、微信发位置）：嵌着的地图左上角写「手机定位没开」，
// 给「去打开」跳到系统定位设置（原生见 LocationSettings.kt）；定位图层照常开着，打开回来一有定位结果就按原规则选中。
// [人工决策-2026-10-15 23:29:29] 嵌着的地图把「去打开」放在地图左上角的提示上（等着定位时才出现；用户选定：定位没开期间一直在，
// 比几秒就收起的提示条好找）；全屏选点页点「定位到我」用提示条。
const _locationSettings = MethodChannel('superxd/location_settings');

void _openLocationSettings() => unawaited(
  _locationSettings.invokeMethod<void>('open').catchError((Object error, StackTrace stack) {
    campusLog('[ChaoxingMap] action=open_location_settings errorType=${error.runtimeType}\n$stack');
  }),
);

// 查不到系统定位开没开（原生调用出错）就按开着处理，照常等定位结果。
Future<bool> _locationServiceOn() async {
  try {
    return await Permission.locationWhenInUse.serviceStatus != ServiceStatus.disabled;
  } catch (error, stack) {
    campusLog('[ChaoxingMap] action=service_status errorType=${error.runtimeType}\n$stack');
    return true;
  }
}

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

// 高德定位图层回报的位置；定位失败时回报的是 0,0，当没有。
LatLng? _fixOf(AMapLocation location) {
  final point = location.latLng;
  return point.latitude == 0 && point.longitude == 0 ? null : point;
}

// 定位图层大约每秒回报一次，只在结果真的拿来选点时记一行（以前每次回报都记，地图开着就每秒一条）。日志不记坐标，只记来源与精度。
void _logFixUsed(AMapLocation location) =>
    campusLog('[ChaoxingMap] action=locate result=fix provider=${location.provider} accuracy=${location.accuracy.round()}');

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

// 平面图与卫星图（同参考项目，地图上一个按钮切换）：这次打开应用期间记住，嵌着的地图与全屏页共用，不落库。
final _satellite = ValueNotifier<bool>(false);

// 卫星图要在图上标出审图号（高德的合规要求）；号码随 SDK 固定，取到一次就留着。
String? _satelliteApproval;

Future<void> _loadSatelliteApproval(AMapController? map, VoidCallback onLoaded) async {
  if (map == null || _satelliteApproval != null) return;
  try {
    final number = (await map.getSatelliteImageApprovalNumber()).trim();
    if (number.isEmpty) return;
    _satelliteApproval = number;
    onLoaded();
  } catch (error, stack) {
    campusLog('[ChaoxingMap] action=approval_number errorType=${error.runtimeType}\n$stack');
  }
}

Widget _mapTypeButton({required bool satellite, required VoidCallback onPressed}) => IconButton(
  tooltip: satellite ? '平面地图' : '卫星地图',
  onPressed: onPressed,
  icon: CampusIcon(satellite ? CampusIcons.flatMap : CampusIcons.satelliteMap),
);

// 地图上的浮动小按钮与提示：地图是原生视图，不叠玻璃（模糊取不到地图内容），用近不透明的表面色。
Widget _mapChip(CampusPalette palette, Widget child) => DecoratedBox(
  decoration: BoxDecoration(color: palette.surface.withValues(alpha: .92), borderRadius: BorderRadius.circular(16)),
  child: child,
);

// 签到弹层里嵌的地图（位置签到默认用它选点，见文件头的人工决策）：点一下地图选点；右上角「定位到我」与「全屏」。
// 建好就申请定位权限并打开高德定位图层；没有选中的位置时，第一次定位结果就是默认选中，之后 30 秒内更准的结果跟着换（自己点过地图就不再覆盖）。
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
  bool _serviceOff = false;
  // 选中的是定位结果、还在跟随窗口内：更准的结果来了就换过去（见文件头的人工决策）。
  bool _refining = false;
  Timer? _refineTimer;
  _Fix? _lastFix;
  LatLng? _reported;
  double _reportedAccuracy = 0;
  Timer? _fixTimeout;
  // 覆盖物每建一次就是新 id，高德会删了重画；弹层别处一刷新（签到进度等）地图上的点就闪，所以按内容缓存。
  Set<Marker> _markers = const {};
  ChaoxingLocation? _markerFor;
  Set<Polygon> _polygons = const {};
  Object? _polygonsFor;

  @override
  void initState() {
    super.initState();
    _satellite.addListener(_onMapType);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initAmap(context);
    _initialized = true;
    unawaited(_startLocating(explain: false));
  }

  void _onMapType() {
    if (!mounted) return;
    setState(() {});
    if (_satellite.value) unawaited(_loadSatelliteApproval(_map, _onMapType));
  }

  @override
  void didUpdateWidget(ChaoxingInlineMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selected = widget.selected;
    if (selected == null || selected == oldWidget.selected) return;
    final target = _target(selected);
    if (target == _reported) return;
    // 外面换了位置（收藏、全屏选点）：之前等着的定位结果不再覆盖它，也不再跟着变准。
    _wantFix = false;
    _stopRefining();
    _moveCamera(_map, target);
  }

  @override
  void dispose() {
    _satellite.removeListener(_onMapType);
    _fixTimeout?.cancel();
    _refineTimer?.cancel();
    super.dispose();
  }

  Future<void> _startLocating({required bool explain}) async {
    if (!await _locationPermitted(context, explain: explain) || !mounted) return;
    final known = _lastFix;
    if (explain && known != null) {
      _startRefining();
      _report(known);
      return;
    }
    final serviceOn = await _locationServiceOn();
    if (!mounted) return;
    setState(() {
      _locating = true;
      _wantFix = explain || widget.selected == null;
      _awaitingFix = explain && serviceOn;
      _serviceOff = !serviceOn;
    });
    if (!explain || !serviceOn) return;
    _fixTimeout?.cancel();
    _fixTimeout = Timer(_slowFix, () {
      if (!mounted || !_awaitingFix) return;
      campusLog('[ChaoxingMap] action=locate result=slow');
      setState(() => _awaitingFix = false);
      showCampusToast(context, '定位有点慢，可以先在地图上点选');
    });
  }

  // 定位图层会持续回报位置：等着的那一次移镜头并选中；之后只在跟随窗口内、精度更好时换过去，别的不跟着拽，免得打断手动选点。
  void _onLocation(AMapLocation location) {
    final point = _fixOf(location);
    if (point == null) return;
    final fix = (point: point, accuracy: location.accuracy);
    _lastFix = fix;
    if (_wantFix) {
      _logFixUsed(location);
      _startRefining();
      _report(fix);
    } else if (_refining && fix.accuracy > 0 && fix.accuracy < _reportedAccuracy) {
      _logFixUsed(location);
      _report(fix);
    }
  }

  void _startRefining() {
    _refineTimer?.cancel();
    _refining = true;
    _refineTimer = Timer(_refineWindow, () => _refining = false);
  }

  void _stopRefining() {
    _refineTimer?.cancel();
    _refining = false;
  }

  void _report(_Fix fix) {
    _fixTimeout?.cancel();
    setState(() {
      _wantFix = false;
      _awaitingFix = false;
      _serviceOff = false;
    });
    _moveCamera(_map, fix.point);
    _reported = fix.point;
    _reportedAccuracy = fix.accuracy;
    widget.onPicked(_gcjLocation(fix.point, ''));
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
    // 等着定位而系统定位没开：左上角写明并给「去打开」（见文件头的人工决策）；已有选中的位置时，点了「定位到我」才出现。
    final locationOff = _wantFix && _serviceOff;
    final hint = locationOff || selected != null
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
                onMapCreated: (controller) {
                  _map = controller;
                  if (_satellite.value) unawaited(_loadSatelliteApproval(controller, _onMapType));
                },
                mapType: _satellite.value ? MapType.satellite : MapType.normal,
                myLocationStyleOptions: _myLocationStyle(_locating),
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
                  _stopRefining();
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
            if (locationOff)
              // 右边让出按钮列，大字号时文字换行、按钮不被挤掉。
              Positioned(
                left: 8,
                top: 8,
                right: 64,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: _mapChip(
                    palette,
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 12),
                            child: Text('手机定位没开', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
                          ),
                        ),
                        TextButton.icon(onPressed: _openLocationSettings, icon: const CampusIcon(CampusIcons.settings), label: const Text('去打开')),
                      ],
                    ),
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
                  const SizedBox(height: 8),
                  _mapChip(palette, _mapTypeButton(satellite: _satellite.value, onPressed: () => _satellite.value = !_satellite.value)),
                ],
              ),
            ),
            // 卫星图的审图号放右下角（左下角是高德 logo）。
            if (_satellite.value && _satelliteApproval != null)
              Positioned(right: 8, bottom: 8, child: _approvalChip(palette)),
          ],
        ),
      ),
    );
  }
}

Widget _approvalChip(CampusPalette palette) => _mapChip(
  palette,
  Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    child: Text(_satelliteApproval!, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
  ),
);

// 全屏地图选点：点一下地图拿到坐标，配一个名称，返回给签到弹层。
// rangeCenter 与 rangeMeters 给出时画出签到范围圈（详情里的签到点与半径，坐标系任意，会先换算）。
// favorite 为真时是在管理收藏里添加收藏位置：名称必填（同名收藏会被覆盖，不能都叫「地图选点」）。
Future<ChaoxingLocation?> openChaoxingMapPicker(
  BuildContext context, {
  ChaoxingLocation? initial,
  String? label,
  ChaoxingLocation? rangeCenter,
  double? rangeMeters,
  bool favorite = false,
}) => Navigator.of(context).push<ChaoxingLocation>(
  CampusPageRoute(
    builder: (_) => ChaoxingMapPage(
      initial: initial,
      initialLabel: label,
      rangeCenter: rangeCenter,
      rangeMeters: rangeMeters,
      favorite: favorite,
    ),
  ),
);

class ChaoxingMapPage extends StatefulWidget {
  const ChaoxingMapPage({super.key, this.initial, this.initialLabel, this.rangeCenter, this.rangeMeters, this.favorite = false});
  final ChaoxingLocation? initial;
  final String? initialLabel;
  final ChaoxingLocation? rangeCenter;
  final double? rangeMeters;
  final bool favorite;
  @override
  State<ChaoxingMapPage> createState() => _ChaoxingMapPageState();
}

class _ChaoxingMapPageState extends State<ChaoxingMapPage> {
  final _label = TextEditingController();
  // 从签到弹层进来时带着那边已选的位置：标记直接画上、「用这个位置」可点，不用再点一次（以前进来是空的）。
  // 添加收藏时传进来的是最近一个收藏，只当镜头起点，不预选，免得一点就存出一个重复的收藏。
  late LatLng? _picked = widget.favorite || widget.initial == null ? null : _target(widget.initial);
  // 签到范围圈按内容缓存：覆盖物每建一次就是新 id，高德会删了重画，点一下地图范围圈就闪（同嵌着的地图）。
  Set<Polygon> _polygons = const {};
  Object? _polygonsFor;
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
    _satellite.addListener(_onMapType);
  }

  void _onMapType() {
    if (!mounted) return;
    setState(() {});
    if (_satellite.value) unawaited(_loadSatelliteApproval(_map, _onMapType));
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
    _satellite.removeListener(_onMapType);
    _fixTimeout?.cancel();
    _label.dispose();
    super.dispose();
  }

  // 全屏页不自动定位：从签到弹层进来时已有选中的位置，要当前位置点「定位到我」（权限规则见文件头的人工决策）。
  // 系统定位关着时给「去打开」，按钮不转圈，打开回来的第一次定位结果照样选中。
  Future<void> _locate() async {
    if (!await _locationPermitted(context, explain: true) || !mounted) return;
    final serviceOn = await _locationServiceOn();
    if (!mounted) return;
    setState(() {
      _locating = true;
      _wantFix = true;
      _awaitingFix = serviceOn;
    });
    if (!serviceOn) {
      showCampusToast(context, '手机定位没开，可以先在地图上点选', action: '去打开', onAction: _openLocationSettings);
      return;
    }
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
    _logFixUsed(location);
    _fixTimeout?.cancel();
    setState(() {
      _wantFix = false;
      _awaitingFix = false;
      _picked = point;
    });
    _moveCamera(_map, point);
  }

  Set<Polygon> _polygonSet(CampusPalette palette) {
    final key = (widget.rangeCenter, widget.rangeMeters, palette.accent);
    if (key != _polygonsFor) {
      _polygonsFor = key;
      _polygons = _rangePolygon(palette, widget.rangeCenter, widget.rangeMeters);
    }
    return _polygons;
  }

  void _confirm() {
    final picked = _picked;
    final label = _label.text.trim();
    if (picked == null || widget.favorite && label.isEmpty) return;
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
        title: Text(widget.favorite ? '添加收藏位置' : '在地图上选点'),
        leading: IconButton(
          tooltip: '返回',
          onPressed: () => Navigator.pop(context),
          icon: const CampusIcon(CampusIcons.back),
        ),
        actions: [
          _mapTypeButton(satellite: _satellite.value, onPressed: () => _satellite.value = !_satellite.value),
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
              onMapCreated: (controller) {
                _map = controller;
                if (_satellite.value) unawaited(_loadSatelliteApproval(controller, _onMapType));
              },
              mapType: _satellite.value ? MapType.satellite : MapType.normal,
              myLocationStyleOptions: _myLocationStyle(_locating),
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
              polygons: _polygonSet(palette),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.topCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _mapChip(
                    palette,
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: Text(
                        picked == null ? '在教室的位置点一下地图' : '已选 ${picked.latitude.toStringAsFixed(6)}, ${picked.longitude.toStringAsFixed(6)}',
                        style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
                      ),
                    ),
                  ),
                  // 卫星图的审图号（底部面板压着地图下沿，放在顶上提示下面）。
                  if (_satellite.value && _satelliteApproval != null) ...[
                    const SizedBox(height: 8),
                    _approvalChip(palette),
                  ],
                ],
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
                      decoration: InputDecoration(
                        labelText: widget.favorite ? '收藏名' : '位置名称',
                        helperText: widget.favorite ? '例如 知敬楼402' : '例如 知敬楼402，签到时会一起提交',
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 收藏要有名字才能存：名字随输入实时决定按钮能不能点。
                    ListenableBuilder(
                      listenable: _label,
                      builder: (context, _) => FilledButton.icon(
                        style: campusProminent,
                        onPressed: picked == null || widget.favorite && _label.text.trim().isEmpty ? null : _confirm,
                        icon: CampusIcon(widget.favorite ? CampusIcons.addPlace : CampusIcons.check),
                        label: Text(widget.favorite ? '收藏这个位置' : '用这个位置'),
                      ),
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
