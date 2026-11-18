import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/glass_panel.dart';

// 玻璃显示自检（人工决策见 campus_glass_tier.dart 的 11-16 那条）：底栏以某个玻璃档位稳定显示一会儿后，截一下它那块，
// 整块近乎纯黑就说明这台手机的驱动把玻璃画坏了，发 campusGlassBroken，由组合根改成「关闭」并提示。
// 截图由组合根在安卓上接上（campusGlassProbe，原生 PixelCopy）；iOS 与测试不接，就不截也不计时。
Future<double?> Function(Rect physicalArea)? campusGlassProbe;

// 画坏了的档位；组合根监听。
final campusGlassBroken = StreamController<CampusGlassTier>.broadcast();

// 近乎纯黑的像素占到这么多才算画坏：栏上有图标与文字，正常时远到不了。
const campusGlassBrokenShare = .97;

// 档位换好、盖板过渡走完后再等这么久才截，不截到过渡中途。
const campusGlassProbeDelay = Duration(seconds: 2);

// 测试之间清掉「截过且正常」的记录。
@visibleForTesting
void debugResetCampusGlassProbe() => _CampusGlassProbeState._healthy.clear();

class CampusGlassProbe extends StatefulWidget {
  const CampusGlassProbe({super.key, required this.tier, required this.child});
  final CampusGlassTier tier;
  final Widget child;

  @override
  State<CampusGlassProbe> createState() => _CampusGlassProbeState();
}

class _CampusGlassProbeState extends State<CampusGlassProbe> {
  // 本进程里截过且正常的档位不再截；画坏了的不记，改回来时再截一次。
  static final _healthy = <CampusGlassTier>{};
  Timer? _timer;
  // 栏真画在屏幕上：TickerMode 关着（冷启动时开屏画作盖着、下面的应用不画，或被推入的页面盖住）时截到的是别的东西，等露出来再计时。
  // 以前冷启动时开屏还没溶解完就截了（截到的是画作，记成正常，这一进程里不再截）。
  bool? _shown;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shown = TickerMode.valuesOf(context).enabled;
    if (shown == _shown) return;
    _shown = shown;
    _schedule();
  }

  @override
  void didUpdateWidget(CampusGlassProbe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tier != widget.tier) _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    if (campusGlassProbe == null || _shown != true || widget.tier == CampusGlassTier.solid || _healthy.contains(widget.tier)) return;
    final tier = widget.tier;
    _timer = Timer(campusGlassProbeDelay, () => unawaited(_probe(tier).catchError((Object error, StackTrace stack) => campusLog('[CampusGlass] action=probe errorType=${error.runtimeType}\n$stack'))));
  }

  Future<void> _probe(CampusGlassTier tier) async {
    final probe = campusGlassProbe;
    final box = context.findRenderObject() as RenderBox?;
    // 弹窗开着时栏是实色、在后台时不出帧，都等下次换档再截。
    if (probe == null || box == null || !box.hasSize || campusOverlayDepth.value > 0 || WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final origin = box.localToGlobal(Offset.zero);
    final dark = await probe(Rect.fromLTWH(origin.dx * ratio, origin.dy * ratio, box.size.width * ratio, box.size.height * ratio));
    if (!mounted || dark == null || widget.tier != tier) return;
    campusLog('[CampusGlass] action=probe tier=${tier.name} dark=${dark.toStringAsFixed(3)}');
    if (dark < campusGlassBrokenShare) {
      _healthy.add(tier);
      return;
    }
    campusLog('[CampusGlass] action=broken tier=${tier.name} errorType=GlassRenderedBlack');
    campusGlassBroken.add(tier);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
