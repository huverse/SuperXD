import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_map_view.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_web_map.dart';

// 地图是网页版高德（[人工决策-2026-11-10 13:09:42] 见 chaoxing_web_map.dart），只在安卓与 iOS 的内嵌网页里跑；
// key 与安全密钥走构建参数，没带时地图不可用，位置仍可收藏或手输。
bool get _webViewPlatform => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

bool get chaoxingMapAvailable => chaoxingAmapWebKey.isNotEmpty && chaoxingAmapWebSecret.isNotEmpty && _webViewPlatform;

// 地图用不了时给用户一句原因：位置改用经纬度或收藏，不让人对着空白的地方猜。
String? get chaoxingMapUnavailableReason {
  if (chaoxingAmapWebKey.isEmpty || chaoxingAmapWebSecret.isEmpty) return '这个安装包没有带地图';
  if (!_webViewPlatform) return '这台设备用不了地图';
  return null;
}

// 定位结果慢于这个时间就提示可以先手动点选（室内搜不到卫星时首次结果可能要半分钟），但不停止等待。
const _slowFix = Duration(seconds: 15);

// [人工决策-2026-10-15 22:39:57] 定位来的选点跟着变准、不画精度圈（用户在 OPPO 真机上看到室内只有约 550 米的网络定位后选定，
// 同钉钉打卡持续更新位置、微信发位置只画定位点）：嵌着的地图选中的是定位结果时，30 秒内来了更准的结果（精度数值更小）就换过去；
// 自己点了地图、选了收藏或全屏选了点就不再动。精度圈不画（粗定位时会把整张小地图染色），当前位置只画一个点，图上只留老师的签到范围圈。
const _refineWindow = Duration(seconds: 30);

// [人工决策-2026-10-15 22:39:57] 系统定位关着时（用户选定，同高德、美团、微信发位置）：嵌着的地图左上角写「手机定位没开」，
// 给「去打开」跳到系统定位设置（原生见 LocationSettings.kt）；定位照常开着，打开回来一有定位结果就按原规则选中。
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
// [人工决策-2026-11-09 12:56:15] 删除「签到点附近」的全部逻辑与代码（用户评判这个功能暂时没用；取代 10-29 15:55:56、10-29 19:10:00、11-05 17:18:44 三条）：
// 不再把老师的签到点当默认选点（含 10 米内随机取点、一键重随、地图用不了时预填老师坐标），不再从签到前检查网页读老师坐标，#202 的高德地理编码也不做。
// 默认选点回到上一条：这门课上次签到用的 → 上次签到用的 → 当前位置；地图用不了时把前两者预填进经纬度框（用户交代其余按最佳实践，iOS 没地图时不留两个空框）。
// 详情本来就给坐标时照旧画范围圈，只作提示。
// [人工决策-2026-11-09 20:07:11] 不恢复「没有地图时预填老师坐标」（用户明确答复）：iOS 与不带地图的安卓包里，从没签过任何位置签到的第一次，经纬度框照样留空。
// 留下的教训（别再加回同样的做法）：网页的 #latitude/#longitude 是学生自己的签到位置（没签时 -1），曾被当成老师坐标、取点偏出上千万米；
// #locationLatitude 只出自 Doraemon 2023 年的代码，真实页面上从没见过；按地址的课要靠地理编码，精度不稳又要多一个 SDK 与数据去向。
// 中文出界回复「不在可签到范围内，距教师指定签到地点X米」照旧认成出界、收紧偏移重试一次（chaoxing_signer.dart）。

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

// 定位一直在回报，只在结果真的拿来选点时记一行（以前每次回报都记，地图开着就每秒一条）。日志不记坐标，只记精度。
void _logFixUsed(ChaoxingMapFix fix) => campusLog('[ChaoxingMap] action=locate result=fix accuracy=${fix.accuracy.round()}');

// 地图按 GCJ-02 画：收藏里存的可能是 BD-09 或 WGS-84，先换算过来。没有位置时是全国视角的中心。
ChaoxingMapPoint _target(ChaoxingLocation? location) {
  if (location == null) return (latitude: 34.5, longitude: 108.9);
  if (location.system == ChaoxingCoordinateSystem.gcj02) {
    return (latitude: location.latitude, longitude: location.longitude);
  }
  final gcj02 = toGcj02(location.latitude, location.longitude, location.system);
  return (latitude: gcj02.latitude, longitude: gcj02.longitude);
}

ChaoxingLocation _gcjLocation(ChaoxingMapPoint point, String address) =>
    ChaoxingLocation(latitude: point.latitude, longitude: point.longitude, address: address, system: ChaoxingCoordinateSystem.gcj02);

// 签到范围圈：老师设的签到点（坐标系任意，先换算）与半径，用当前配色的激活色（与开关、选中同一个色），不写死颜色。
ChaoxingMapRange? _range(CampusPalette palette, ChaoxingLocation? center, double? meters) =>
    center == null || meters == null ? null : (center: _target(center), meters: meters, color: palette.accent);

// 平面图与卫星图（同参考项目，地图上一个按钮切换）：这次打开应用期间记住，嵌着的地图与全屏页共用，不落库。
final _satellite = ValueNotifier<bool>(false);

// 卫星图要在图上标出审图号（高德的合规要求）；号码随地图固定，地图第一次画好时取到就留着。
String? _satelliteApproval;

Widget _mapTypeButton({required bool satellite, required VoidCallback onPressed}) => IconButton(
  tooltip: satellite ? '平面地图' : '卫星地图',
  onPressed: onPressed,
  icon: CampusIcon(satellite ? CampusIcons.flatMap : CampusIcons.satelliteMap),
);

// 地图上的浮动小按钮与提示：地图是原生视图（内嵌网页），不叠玻璃（模糊取不到地图内容），用近不透明的表面色。
Widget _mapChip(CampusPalette palette, Widget child) => DecoratedBox(
  decoration: BoxDecoration(color: palette.surface.withValues(alpha: .92), borderRadius: BorderRadius.circular(16)),
  child: child,
);

// 网页地图没加载出来（断网、高德脚本下载失败、key 不对）：正中写明并给「重试」，经纬度与收藏照样能用。
Widget _loadFailed(CampusPalette palette, VoidCallback? onRetry) => Center(
  child: _mapChip(
    palette,
    Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text('地图没加载出来', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
          ),
        ),
        TextButton.icon(onPressed: onRetry, icon: const CampusIcon(CampusIcons.sync), label: const Text('重试')),
      ],
    ),
  ),
);

// 签到弹层里嵌的地图（位置签到默认用它选点，见文件头的人工决策）：点一下地图选点；右上角「定位到我」与「全屏」。
// 建好就申请定位权限并开始定位；没有选中的位置时，第一次定位结果就是默认选中，之后 30 秒内更准的结果跟着换（自己点过地图就不再覆盖）。
// 选中的位置从外面变了（选了收藏、全屏页选点）镜头跟过去；本组件报出去的点不再挪镜头，免得点哪儿跳哪儿。
class ChaoxingInlineMap extends StatefulWidget {
  const ChaoxingInlineMap({
    super.key,
    required this.selected,
    required this.onPicked,
    required this.onExpand,
    this.rangeCenter,
    this.rangeMeters,
    this.backend = const ChaoxingWebMap(),
  });
  final ChaoxingLocation? selected;
  // 报出去的是 GCJ-02、名称为空的位置，名称由弹层的名称框决定。
  final ValueChanged<ChaoxingLocation> onPicked;
  final VoidCallback? onExpand;
  final ChaoxingLocation? rangeCenter;
  final double? rangeMeters;
  final ChaoxingMapBackend backend;

  static const height = 240.0;

  @override
  State<ChaoxingInlineMap> createState() => _ChaoxingInlineMapState();
}

class _ChaoxingInlineMapState extends State<ChaoxingInlineMap> {
  ChaoxingMapEngine? _map;
  late final _listener = ChaoxingMapListener(onTap: _onTap, onFix: _onFix, onStatus: _onStatus);
  ChaoxingMapStatus _status = ChaoxingMapStatus.loading;
  bool _initialized = false;
  // 每次要（重新）开始定位就加一（见 ChaoxingMapScene.locateRequest）。
  int _locateRequest = 0;
  // 下一次定位结果要不要移镜头并选中：自动申请时只在还没选中位置时要，点「定位到我」时总要；自己点了地图就作罢。
  bool _wantFix = false;
  // 点了「定位到我」还在等结果：按钮原地转圈。
  bool _awaitingFix = false;
  bool _serviceOff = false;
  // 选中的是定位结果、还在跟随窗口内：更准的结果来了就换过去（见文件头的人工决策）。
  bool _refining = false;
  Timer? _refineTimer;
  ChaoxingMapFix? _lastFix;
  ChaoxingMapPoint? _reported;
  double _reportedAccuracy = 0;
  Timer? _fixTimeout;

  @override
  void initState() {
    super.initState();
    _satellite.addListener(_onMapType);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    unawaited(_startLocating(explain: false));
  }

  void _onMapType() {
    if (mounted) setState(() {});
  }

  void _onStatus(ChaoxingMapStatus status) {
    if (!mounted) return;
    if (status == ChaoxingMapStatus.ready) _satelliteApproval ??= _map?.satelliteApproval;
    setState(() => _status = status);
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
    _map?.moveCamera(target, 17);
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
      _locateRequest++;
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

  // 定位会持续回报位置：等着的那一次移镜头并选中；之后只在跟随窗口内、精度更好时换过去，别的不跟着拽，免得打断手动选点。
  void _onFix(ChaoxingMapFix fix) {
    if (!mounted) return;
    _lastFix = fix;
    if (_wantFix) {
      _logFixUsed(fix);
      _startRefining();
      _report(fix);
    } else if (_refining && fix.accuracy > 0 && fix.accuracy < _reportedAccuracy) {
      _logFixUsed(fix);
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

  void _report(ChaoxingMapFix fix) {
    _fixTimeout?.cancel();
    setState(() {
      _wantFix = false;
      _awaitingFix = false;
      _serviceOff = false;
    });
    _map?.moveCamera(fix.point, 17);
    _reported = fix.point;
    _reportedAccuracy = fix.accuracy;
    widget.onPicked(_gcjLocation(fix.point, ''));
  }

  // 自己点了就以点的为准，迟到的定位结果不再覆盖。
  void _onTap(ChaoxingMapPoint point) {
    if (!mounted) return;
    _fixTimeout?.cancel();
    _stopRefining();
    setState(() {
      _wantFix = false;
      _awaitingFix = false;
    });
    _reported = point;
    widget.onPicked(_gcjLocation(point, ''));
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final selected = widget.selected;
    final start = selected ?? widget.rangeCenter;
    final failed = _status == ChaoxingMapStatus.failed;
    // 等着定位而系统定位没开：左上角写明并给「去打开」（见文件头的人工决策）；已有选中的位置时，点了「定位到我」才出现。
    final locationOff = _wantFix && _serviceOff;
    final hint = locationOff || selected != null || failed
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
            // 弹层本身能上下拖：手指落在地图上时拖动归地图（地图组件自己声明），弹层滚动从地图外面拖。
            Positioned.fill(
              child: ChaoxingMapView(
                backend: widget.backend,
                center: _target(start),
                zoom: start == null ? 4 : 17,
                background: palette.surface,
                listener: _listener,
                onCreated: (engine) => _map = engine,
                scene: ChaoxingMapScene(
                  marker: selected == null ? null : _target(selected),
                  range: _range(palette, widget.rangeCenter, widget.rangeMeters),
                  satellite: _satellite.value,
                  locateRequest: _locateRequest,
                ),
              ),
            ),
            if (failed) _loadFailed(palette, _map?.reload),
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
  const ChaoxingMapPage({
    super.key,
    this.initial,
    this.initialLabel,
    this.rangeCenter,
    this.rangeMeters,
    this.favorite = false,
    this.backend = const ChaoxingWebMap(),
  });
  final ChaoxingLocation? initial;
  final String? initialLabel;
  final ChaoxingLocation? rangeCenter;
  final double? rangeMeters;
  final bool favorite;
  final ChaoxingMapBackend backend;
  @override
  State<ChaoxingMapPage> createState() => _ChaoxingMapPageState();
}

class _ChaoxingMapPageState extends State<ChaoxingMapPage> {
  final _label = TextEditingController();
  // 从签到弹层进来时带着那边已选的位置：标记直接画上、「用这个位置」可点，不用再点一次（以前进来是空的）。
  // 添加收藏时传进来的是最近一个收藏，只当镜头起点，不预选，免得一点就存出一个重复的收藏。
  late ChaoxingMapPoint? _picked = widget.favorite || widget.initial == null ? null : _target(widget.initial);
  ChaoxingMapEngine? _map;
  late final _listener = ChaoxingMapListener(onTap: _onTap, onFix: _onFix, onStatus: _onStatus);
  ChaoxingMapStatus _status = ChaoxingMapStatus.loading;
  // 点过「定位到我」并拿到权限后开始定位。_wantFix：等下一次定位结果来移镜头并选中（自己点了地图就作罢）；
  // _awaitingFix：按钮原地转圈，最多 15 秒，过了只提示、不停止等待。
  int _locateRequest = 0;
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
    if (mounted) setState(() {});
  }

  void _onStatus(ChaoxingMapStatus status) {
    if (!mounted) return;
    if (status == ChaoxingMapStatus.ready) _satelliteApproval ??= _map?.satelliteApproval;
    setState(() => _status = status);
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
      _locateRequest++;
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

  // 定位会持续回报位置；只有点了「定位到我」后的第一次结果移镜头并选中，之后不跟着拽，免得打断手动选点。
  void _onFix(ChaoxingMapFix fix) {
    if (!mounted || !_wantFix) return;
    _logFixUsed(fix);
    _fixTimeout?.cancel();
    setState(() {
      _wantFix = false;
      _awaitingFix = false;
      _picked = fix.point;
    });
    _map?.moveCamera(fix.point, 17);
  }

  // 自己点了就以点的为准，迟到的定位结果不再覆盖。
  void _onTap(ChaoxingMapPoint point) {
    if (!mounted) return;
    setState(() {
      _picked = point;
      _wantFix = false;
      _awaitingFix = false;
    });
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
            child: ChaoxingMapView(
              backend: widget.backend,
              center: _target(start),
              zoom: start == null ? 4 : 17,
              background: palette.surface,
              listener: _listener,
              onCreated: (engine) => _map = engine,
              // 签到范围圈：老师定的签到点与半径画出来，选点时心里有数（没给范围就不画）。
              scene: ChaoxingMapScene(
                marker: picked,
                range: _range(palette, widget.rangeCenter, widget.rangeMeters),
                satellite: _satellite.value,
                locateRequest: _locateRequest,
              ),
            ),
          ),
          if (_status == ChaoxingMapStatus.failed) _loadFailed(palette, _map?.reload),
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
          // 底部留出高德 logo 的位置：合规要求 logo 可见，面板不压到它。面板是提示条的锚点，「定位有点慢」这类提示停在它上方。
          Align(
            alignment: AlignmentDirectional.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 44),
              child: CampusToastAnchor(child: CampusSurface(
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
              )),
            ),
          ),
        ],
      ),
    );
  }
}
