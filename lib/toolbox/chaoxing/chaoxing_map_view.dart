import 'package:flutter/widgets.dart';

// 地图端口：选点页（chaoxing_map_page.dart）只经这里画地图、收点按与定位结果，不认识具体是哪种地图。
// 生产实现是内嵌网页加高德 JS API（chaoxing_web_map.dart），测试注入假实现。坐标一律 GCJ-02（高德的坐标系）。

typedef ChaoxingMapPoint = ({double latitude, double longitude});

// 定位结果：已换成 GCJ-02；accuracy 是精度半径（米），0 表示不知道。
typedef ChaoxingMapFix = ({ChaoxingMapPoint point, double accuracy});

// 签到范围圈：中心、半径（米）与颜色。
typedef ChaoxingMapRange = ({ChaoxingMapPoint center, double meters, Color color});

// 地图要画成的样子，选点页每次重建都给一份完整的；ChaoxingMapView 只把变了的交给地图。
// locateRequest 每次要（重新）开始定位就加一，0 是还没要过；开始后一直回报，直到地图关掉。
@immutable
class ChaoxingMapScene {
  const ChaoxingMapScene({this.marker, this.range, this.satellite = false, this.locateRequest = 0});
  final ChaoxingMapPoint? marker;
  final ChaoxingMapRange? range;
  final bool satellite;
  final int locateRequest;
}

enum ChaoxingMapStatus { loading, ready, failed }

// 地图回报给选点页的事件。都在地图建好之后才会来，不会在建的那一刻同步回调。
class ChaoxingMapListener {
  const ChaoxingMapListener({required this.onTap, required this.onFix, required this.onStatus});
  final ValueChanged<ChaoxingMapPoint> onTap;
  final ValueChanged<ChaoxingMapFix> onFix;
  final ValueChanged<ChaoxingMapStatus> onStatus;
}

// 一张地图。画与移镜头都是视觉上的事，实现里出错只记日志、不打断选点。
abstract interface class ChaoxingMapEngine {
  Widget get view;
  void setMarker(ChaoxingMapPoint? point);
  void setRange(ChaoxingMapRange? range);
  void setSatellite(bool satellite);
  // 开始（或重新开始）定位，结果经 onFix 持续回报。
  void locate();
  void moveCamera(ChaoxingMapPoint target, double zoom);
  // 卫星图的审图号（高德的合规要求，卫星图上要标出来）；地图画好之前为空。
  String? get satelliteApproval;
  // 加载失败后重来一次。
  void reload();
  void dispose();
}

abstract interface class ChaoxingMapBackend {
  // 镜头起点、缩放与加载出来之前的底色在建的时候定。
  ChaoxingMapEngine open({
    required ChaoxingMapPoint center,
    required double zoom,
    required Color background,
    required ChaoxingMapListener listener,
  });
}

// 把一张地图挂进组件树：建一次、离开时关掉，每次重建只把场景里变了的交给它。
class ChaoxingMapView extends StatefulWidget {
  const ChaoxingMapView({
    super.key,
    required this.backend,
    required this.center,
    required this.zoom,
    required this.background,
    required this.scene,
    required this.listener,
    required this.onCreated,
  });
  final ChaoxingMapBackend backend;
  final ChaoxingMapPoint center;
  final double zoom;
  final Color background;
  final ChaoxingMapScene scene;
  final ChaoxingMapListener listener;
  final ValueChanged<ChaoxingMapEngine> onCreated;

  @override
  State<ChaoxingMapView> createState() => _ChaoxingMapViewState();
}

class _ChaoxingMapViewState extends State<ChaoxingMapView> {
  late final ChaoxingMapEngine _engine;

  @override
  void initState() {
    super.initState();
    _engine = widget.backend.open(center: widget.center, zoom: widget.zoom, background: widget.background, listener: widget.listener);
    widget.onCreated(_engine);
    _show(widget.scene, null);
  }

  @override
  void didUpdateWidget(ChaoxingMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _show(widget.scene, oldWidget.scene);
  }

  // 覆盖物每重画一次地图上就闪一下，弹层别处一刷新（签到进度等）这里也跟着重建，所以按内容比较、只交变了的。
  void _show(ChaoxingMapScene scene, ChaoxingMapScene? old) {
    if (scene.marker != old?.marker) _engine.setMarker(scene.marker);
    if (scene.range != old?.range) _engine.setRange(scene.range);
    if (scene.satellite != (old?.satellite ?? false)) _engine.setSatellite(scene.satellite);
    if (scene.locateRequest > (old?.locateRequest ?? 0)) _engine.locate();
  }

  @override
  void dispose() {
    _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _engine.view;
}
