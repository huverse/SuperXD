import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_map_view.dart';

// [人工决策-2026-11-10 13:09:42] 学习通位置签到的地图改用网页版高德（内嵌网页加高德 JS API 2.0），删掉高德原生地图 SDK（用户选定）：
// 原生 SDK 的原生库在 arm64 包里约 31MB，只为这一个选点页；iOS 上原生 key 绑包名、自签后失效，一直没有地图、只能手输。
// 网页版省掉这部分体积，iOS 也有地图；用户接受选点页重做并重新验收。没选保留原生 SDK（体积与 iOS 无图照旧）。
// 选点页的交互与文案不变（默认选点、跟着变准、不画精度圈、定位没开的提示、平面卫星切换等人工决策都在 chaoxing_map_page.dart），只换地图的实现。
// key 与安全密钥要高德控制台里「Web 端（JS API）」类型的，经构建参数注入、不进仓库；两个都带了地图才可用，没带时同以前没带 key 一样退回手输：
// flutter build apk --dart-define=SUPERXD_AMAP_WEB_KEY=<key> --dart-define=SUPERXD_AMAP_WEB_SECRET=<安全密钥>
const chaoxingAmapWebKey = String.fromEnvironment('SUPERXD_AMAP_WEB_KEY');
const chaoxingAmapWebSecret = String.fromEnvironment('SUPERXD_AMAP_WEB_SECRET');

// 内置页面装在一个 https 的本机地址下（不用 file://）：高德脚本里有以 // 开头的资源地址，取位置也要安全上下文。
// 这个地址不会真的去请求，导航只许停在这一页。
const chaoxingMapPageUrl = 'https://localhost/superxd/chaoxing_map.html';
const _pageAsset = 'assets/chaoxing_map/map.html';
const _configSlot = '/*CONFIG*/null';
const _bridge = 'SuperXdMap';

// 一条消息最长多少字（正常的不到 200 字）。
const _messageLimit = 512;

// 主框架只许停在内置页：外部链接与 scheme 一律拦下（选点用不着跳走）。
NavigationDecision chaoxingMapNavigation(String url) {
  final uri = Uri.tryParse(url);
  return uri != null && uri.removeFragment() == Uri.parse(chaoxingMapPageUrl) ? NavigationDecision.navigate : NavigationDecision.prevent;
}

String _cssColor(Color color) => '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

List<double>? _pair(ChaoxingMapPoint? point) => point == null ? null : [point.latitude, point.longitude];

// 把 key、安全密钥、镜头起点与底色填进页面（页面里有且只有一处 /*CONFIG*/null）；JSON 里的 < 转义，免得提前结束 <script>。
String chaoxingMapHtml(
  String template, {
  required String key,
  required String secret,
  required ChaoxingMapPoint center,
  required double zoom,
  required Color background,
}) {
  if (_configSlot.allMatches(template).length != 1) throw StateError('地图页面里要有且只有一处 $_configSlot');
  final config = jsonEncode({'key': key, 'secret': secret, 'center': _pair(center), 'zoom': zoom, 'background': _cssColor(background)});
  return template.replaceFirst(_configSlot, config.replaceAll('<', r'<'));
}

// 网页经 JS 通道 SuperXdMap 发来的消息，一条一个 JSON 对象。网页里跑着高德的第三方脚本，按外部输入逐项校验：
// 只认下面几种 type；坐标要在经纬度范围内，精度是 0–100 公里的有限数，字符串限长限字符；对不上的整条丢掉。
sealed class ChaoxingMapMessage {
  const ChaoxingMapMessage();
}

// 地图第一次画好；approval 是卫星图的审图号（取不到为空）。
final class ChaoxingMapReady extends ChaoxingMapMessage {
  const ChaoxingMapReady(this.approval);
  final String? approval;
}

// 加载失败：script 是高德脚本没下载下来，key 是 key 或安全密钥不对，init 是建地图出错。
final class ChaoxingMapFailed extends ChaoxingMapMessage {
  const ChaoxingMapFailed(this.reason);
  final String reason;
}

// 点了地图（GCJ-02）。
final class ChaoxingMapTapped extends ChaoxingMapMessage {
  const ChaoxingMapTapped(this.point);
  final ChaoxingMapPoint point;
}

// 系统定位的结果：WGS-84（还没换算）与精度半径（米）。
final class ChaoxingMapLocated extends ChaoxingMapMessage {
  const ChaoxingMapLocated(this.latitude, this.longitude, this.accuracy);
  final double latitude;
  final double longitude;
  final double accuracy;
}

// 定位出错（网页定位的错误码）：1 网页没被允许取位置，2 取不到，3 超时。
final class ChaoxingMapLocateFailed extends ChaoxingMapMessage {
  const ChaoxingMapLocateFailed(this.code);
  final int code;
}

// 被内容安全策略拦下的加载，只带主机名。
final class ChaoxingMapBlocked extends ChaoxingMapMessage {
  const ChaoxingMapBlocked(this.host);
  final String host;
}

double? _within(Object? value, double min, double max) => value is num && value.isFinite && value >= min && value <= max ? value.toDouble() : null;

String? _text(Object? value, int limit, RegExp allowed) => value is String && value.length <= limit && allowed.hasMatch(value) ? value : null;

final _approvalText = RegExp(r'^[^\x00-\x1f<>]+$');
final _hostText = RegExp(r'^[A-Za-z0-9.:\[\]-]*$');

ChaoxingMapMessage? chaoxingMapMessage(String raw) {
  if (raw.length > _messageLimit) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  switch (decoded['type']) {
    case 'ready':
      final approval = decoded['approval'];
      if (approval == null) return const ChaoxingMapReady(null);
      final text = _text(approval, 40, _approvalText);
      return text == null ? null : ChaoxingMapReady(text);
    case 'failed':
      final reason = decoded['reason'];
      return reason == 'script' || reason == 'key' || reason == 'init' ? ChaoxingMapFailed(reason as String) : null;
    case 'tap':
      final latitude = _within(decoded['latitude'], -90, 90);
      final longitude = _within(decoded['longitude'], -180, 180);
      return latitude == null || longitude == null ? null : ChaoxingMapTapped((latitude: latitude, longitude: longitude));
    case 'located':
      final latitude = _within(decoded['latitude'], -90, 90);
      final longitude = _within(decoded['longitude'], -180, 180);
      final accuracy = _within(decoded['accuracy'], 0, 100000);
      return latitude == null || longitude == null || accuracy == null ? null : ChaoxingMapLocated(latitude, longitude, accuracy);
    case 'locateFailed':
      final code = decoded['code'];
      return code is int && code >= 1 && code <= 3 ? ChaoxingMapLocateFailed(code) : null;
    case 'blocked':
      final host = _text(decoded['host'], 253, _hostText);
      return host == null ? null : ChaoxingMapBlocked(host);
  }
  return null;
}

void _quietly(Future<void> future, String action) => unawaited(
  future.catchError((Object error, StackTrace stack) {
    campusLog('[ChaoxingMap] action=$action errorType=${error.runtimeType}\n$stack');
  }),
);

// 生产用的地图：内嵌网页装内置页面（assets/chaoxing_map/map.html），页面里跑高德 JS API 2.0。
class ChaoxingWebMap implements ChaoxingMapBackend {
  const ChaoxingWebMap();

  @override
  ChaoxingMapEngine open({
    required ChaoxingMapPoint center,
    required double zoom,
    required Color background,
    required ChaoxingMapListener listener,
  }) => _WebMapEngine(center, zoom, background, listener);
}

class _WebMapEngine with WidgetsBindingObserver implements ChaoxingMapEngine {
  _WebMapEngine(this._center, this._zoom, this._background, this._listener) {
    _controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(_background)
      ..addJavaScriptChannel(_bridge, onMessageReceived: (message) => _onMessage(message.message))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) => chaoxingMapNavigation(request.url),
          onPageFinished: _onPageFinished,
          onWebResourceError: _onWebError,
        ),
      );
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      _quietly(platform.setGeolocationEnabled(true), 'geolocation_setup');
      _quietly(platform.setGeolocationPermissionsPromptCallbacks(onShowPrompt: _allowGeolocation), 'geolocation_setup');
    }
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  final _controller = WebViewController();
  final Color _background;
  final ChaoxingMapListener _listener;
  ChaoxingMapPoint _center;
  double _zoom;
  ChaoxingMapPoint? _marker;
  ChaoxingMapRange? _range;
  ChaoxingMapPoint? _here;
  bool _satellite = false;
  bool _locating = false;
  String? _approval;
  // 内置页面加载完（页面脚本已定义 superxdMap）之前的吩咐先记着，加载完一起交过去。
  bool _pageLoaded = false;
  bool _disposed = false;

  // 拖动全归网页：弹层本身能上下拖，iOS 页面任意位置右滑返回也会抢横向拖动（同 express_verify_webview.dart）。
  @override
  late final Widget view = WebViewWidget(controller: _controller, gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)});

  Future<void> _load() async {
    _pageLoaded = false;
    try {
      final template = await rootBundle.loadString(_pageAsset);
      if (_disposed) return;
      final html = chaoxingMapHtml(template, key: chaoxingAmapWebKey, secret: chaoxingAmapWebSecret, center: _center, zoom: _zoom, background: _background);
      await _controller.loadHtmlString(html, baseUrl: chaoxingMapPageUrl);
    } catch (error, stack) {
      campusLog('[ChaoxingMap] action=load errorType=${error.runtimeType}\n$stack');
      if (!_disposed) _listener.onStatus(ChaoxingMapStatus.failed);
    }
  }

  void _onPageFinished(String url) {
    if (_disposed) return;
    _pageLoaded = true;
    _run(_cameraScript());
    _run(_markerScript());
    _run(_rangeScript());
    if (_here != null) _run(_hereScript());
    if (_satellite) _run(_satelliteScript());
    if (_locating) _run(_locateScript);
  }

  // 只有内置页面这一帧算加载失败；图块这类子资源失败不管（地图自己会留空白、再拖动时重取）。
  void _onWebError(WebResourceError error) {
    if (_disposed || error.isForMainFrame != true) return;
    campusLog('[ChaoxingMap] action=load errorType=web_${error.errorType?.name ?? '${error.errorCode}'}');
    _listener.onStatus(ChaoxingMapStatus.failed);
  }

  // 安卓内嵌网页要取位置时问应用：只放行内置页面，而且应用已有定位权限（打开位置签到或点「定位到我」时申请过，仅使用期间）；不记住，每次都问。
  Future<GeolocationPermissionsResponse> _allowGeolocation(GeolocationPermissionsRequestParams request) async {
    var allow = false;
    if (Uri.tryParse(request.origin)?.host == Uri.parse(chaoxingMapPageUrl).host) {
      try {
        final status = await Permission.locationWhenInUse.status;
        allow = status.isGranted || status.isLimited;
      } catch (error, stack) {
        campusLog('[ChaoxingMap] action=geolocation_prompt errorType=${error.runtimeType}\n$stack');
      }
    }
    return GeolocationPermissionsResponse(allow: allow, retain: false);
  }

  // 系统定位关着时网页的定位停在出错上，不会自己恢复（原生地图的定位图层会）：回到前台时重新开始，去系统设置打开定位回来就能接着取到。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _locating) _run(_locateScript);
  }

  void _onMessage(String raw) {
    if (_disposed) return;
    switch (chaoxingMapMessage(raw)) {
      case null:
        campusLog('[ChaoxingMap] action=bridge result=rejected length=${raw.length}');
      case ChaoxingMapReady(:final approval):
        _approval = approval;
        campusLog('[ChaoxingMap] action=load result=ready');
        _listener.onStatus(ChaoxingMapStatus.ready);
      case ChaoxingMapFailed(:final reason):
        campusLog('[ChaoxingMap] action=load errorType=$reason');
        _listener.onStatus(ChaoxingMapStatus.failed);
      case ChaoxingMapTapped(:final point):
        _listener.onTap(point);
      // 系统给的是 WGS-84，在本机按公开的 GCJ-02 算法换算（同提交前的换算，chaoxing_location.dart），不把位置发给高德去转；
      // 换好的交回网页画当前位置的点（原生地图时定位图层自己画）。
      case ChaoxingMapLocated(:final latitude, :final longitude, :final accuracy):
        final converted = wgs84ToGcj02(latitude, longitude);
        _here = (latitude: converted.latitude, longitude: converted.longitude);
        _run(_hereScript());
        _listener.onFix((point: _here!, accuracy: accuracy));
      case ChaoxingMapLocateFailed(:final code):
        campusLog('[ChaoxingMap] action=locate result=error code=$code');
      case ChaoxingMapBlocked(:final host):
        campusLog('[ChaoxingMap] action=blocked host=$host');
    }
  }

  void _run(String script) {
    if (_pageLoaded && !_disposed) _quietly(_controller.runJavaScript(script), 'script');
  }

  String _cameraScript() => 'superxdMap.camera(${jsonEncode(_pair(_center))}, ${jsonEncode(_zoom)})';
  String _markerScript() => 'superxdMap.marker(${jsonEncode(_pair(_marker))})';
  String _hereScript() => 'superxdMap.here(${jsonEncode(_pair(_here))})';
  String _satelliteScript() => 'superxdMap.satellite($_satellite)';
  static const _locateScript = 'superxdMap.locate()';

  String _rangeScript() {
    final range = _range;
    final value = range == null ? null : {'center': _pair(range.center), 'meters': range.meters, 'color': _cssColor(range.color)};
    return 'superxdMap.range(${jsonEncode(value)})';
  }

  @override
  void setMarker(ChaoxingMapPoint? point) {
    _marker = point;
    _run(_markerScript());
  }

  @override
  void setRange(ChaoxingMapRange? range) {
    _range = range;
    _run(_rangeScript());
  }

  @override
  void setSatellite(bool satellite) {
    _satellite = satellite;
    _run(_satelliteScript());
  }

  @override
  void locate() {
    _locating = true;
    _run(_locateScript);
  }

  @override
  void moveCamera(ChaoxingMapPoint target, double zoom) {
    _center = target;
    _zoom = zoom;
    _run(_cameraScript());
  }

  @override
  String? get satelliteApproval => _approval;

  @override
  void reload() {
    _listener.onStatus(ChaoxingMapStatus.loading);
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
  }
}
