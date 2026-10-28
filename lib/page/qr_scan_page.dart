import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart' show CameraException, FlashMode;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/page/appearance_page.dart';
import 'package:superxd/theme/campus_icons.dart';

// 通用扫码页：相机取景与相册识别都用 zxing-cpp（flutter_zxing）在本机解码，画面与内容不上传、不联网。
// 只把内容交给调用方的 accept 判断，认下的原样返回，不跳转、不打开链接；不认的原地提示后继续扫。
// 好友二维码与课堂签到二维码共用这一页，accept 由调用方给（见 friend_add_page.dart 与 main.dart）。
// 连续模式（onCode 非空）：认下的码交给 onCode 后接着扫，until 完成时自动关；status 是取景页上的进度文字。
// 课堂二维码会定时刷新，给多人连签时要一直对着老师的屏幕，用的就是这个模式。
// [人工决策-2026-10-28 14:44:29] 识别引擎由 Google ML Kit（mobile_scanner）换成 zxing-cpp（用户选定）：用户在教室后排扫投影上的签到码，
// 取景认不出、拍照后从相册识别也说没有二维码；同一张照片 ML Kit 整张认不出（只有把码紧裁再放大两倍才认得出），zxing-cpp 整张直接解出、缩到 768 像素仍能解。
// 取景按 1080p 整帧找码、可两指缩放与点 1×/2×/4× 拉近（远处的码要放大才认得出）；相册图用系统解码器缩到 2048 像素再交给 zxing，在后台线程解。
typedef QrAccept = String? Function(String raw);

class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key, this.hint, required this.accept, this.onCode, this.until, this.status});
  final String? hint;

  // 返回提示文案表示不认这个内容；返回 null 表示认下，页面随即关掉并把原文交给调用方。
  final QrAccept accept;
  final void Function(String raw)? onCode;
  final Future<void>? until;
  final ValueListenable<String?>? status;
  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

// 相册里的照片缩到这么大再找码：投影上的签到码从后排拍，整张缩到 768 像素还能解、640 就不行了，留足余量。
const _galleryMaxSide = 2048;
// 快捷拉近档：点了直接到这个倍数，超出这台相机的最大倍数的不显示。
const _zoomSteps = [1.0, 2.0, 4.0];

class _QrScanPageState extends State<QrScanPage> {
  String? _hint;
  bool _done = false;
  // 上一个读到的码：取景认出后过一会儿会再报同一个码，连续模式下同一个码只交给 onCode 一次。
  String? _last;
  CameraController? _camera;
  String? _cameraError;
  double _zoom = 1, _minZoom = 1, _maxZoom = 1, _pinchFrom = 1;
  bool _torch = false, _torchUsable = true;

  // 调用方没给进度文字时用的空占位，只建一次、随页面释放。
  final _noStatus = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    widget.until?.whenComplete(() {
      if (mounted && !_done) {
        _done = true;
        Navigator.pop(context);
      }
    });
  }

  @override
  void dispose() {
    _noStatus.dispose();
    super.dispose();
  }

  void _accept(String raw) {
    if (_done || raw.isEmpty || raw == _last) return;
    _last = raw;
    final rejected = widget.accept(raw);
    if (rejected != null) {
      setState(() => _hint = rejected);
      return;
    }
    final onCode = widget.onCode;
    if (onCode != null) {
      setState(() => _hint = null);
      onCode(raw);
      return;
    }
    _done = true;
    Navigator.pop(context, raw);
  }

  // 相机开好（切后台回来会重开一个）或打不开时由取景组件回调。缩放与手电筒跟着新相机从头算。
  void _onCamera(CameraController? camera, Exception? error) {
    if (error != null) {
      campusLog('[QrScan] action=camera errorType=${error.runtimeType}${error is CameraException ? ' code=${error.code}' : ''}');
      if (mounted) setState(() => _cameraError = error is CameraException && error.code.startsWith('CameraAccess') ? '没有相机权限，可在系统设置中开启，或从相册选择二维码截图' : '相机暂不可用，可从相册选择二维码截图');
      return;
    }
    if (camera == null || !mounted) return;
    setState(() {
      _camera = camera;
      _cameraError = null;
      _zoom = 1;
      _torch = false;
    });
    unawaited(() async {
      try {
        final (min, max) = (await camera.getMinZoomLevel(), await camera.getMaxZoomLevel());
        if (!mounted || !identical(camera, _camera)) return;
        setState(() {
          _minZoom = min;
          _maxZoom = max;
        });
      } catch (error, stack) {
        campusLog('[QrScan] action=zoomRange errorType=${error.runtimeType}\n$stack');
      }
    }());
  }

  Future<void> _setZoom(double zoom) async {
    final camera = _camera;
    if (camera == null) return;
    final next = zoom.clamp(_minZoom, _maxZoom);
    setState(() => _zoom = next);
    try {
      await camera.setZoomLevel(next);
    } catch (error, stack) {
      campusLog('[QrScan] action=zoom errorType=${error.runtimeType}\n$stack');
    }
  }

  Future<void> _toggleTorch() async {
    final camera = _camera;
    if (camera == null) return;
    try {
      await camera.setFlashMode(_torch ? FlashMode.off : FlashMode.torch);
      if (mounted) setState(() => _torch = !_torch);
    } catch (error, stack) {
      campusLog('[QrScan] action=torch errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _torchUsable = false);
    }
  }

  // 相册识别：复用壁纸的选图（系统照片选择器只给选中的那一张，不申请存储权限），识别完即删插件留在缓存里的副本。
  Future<void> _fromGallery() async {
    try {
      final picked = await pickWallpaperFromGallery();
      if (picked == null) return;
      final String? raw;
      try {
        raw = await _decodeFile(picked.path);
      } finally {
        await picked.discard();
      }
      if (!mounted) return;
      if (raw == null) {
        setState(() => _hint = '这张图里没有找到二维码');
      } else {
        _last = null;
        _accept(raw);
      }
    } catch (error, stack) {
      campusLog('[QrScan] action=gallery errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _hint = '图片识别失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 相机画面上的文字与取景框固定用白色（文字衬半透明深色底），与系统相机一致；不跟随配色，否则在亮处看不清。
    const onCamera = Colors.white;
    final side = MediaQuery.sizeOf(context).shortestSide * .68;
    final steps = [for (final step in _zoomSteps) if (step <= _maxZoom) step];
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        ReaderWidget(
          codeFormat: Format.qrCode,
          tryHarder: true,
          tryDownscale: true,
          // 整帧都找：码不必正好对准框；取景框只是提示。
          cropPercent: 0,
          resolution: ResolutionPreset.veryHigh,
          scanDelay: const Duration(milliseconds: 150),
          scanDelaySuccess: const Duration(milliseconds: 500),
          showScannerOverlay: false,
          showFlashlight: false,
          showToggleCamera: false,
          showGallery: false,
          allowPinchZoom: false,
          actionButtonsBackgroundColor: Colors.transparent,
          loading: const ColoredBox(color: Colors.black),
          onScan: (code) {
            if (code.isValid) _accept(code.text ?? '');
          },
          onControllerCreated: _onCamera,
        ),
        Center(child: Container(
          width: side,
          height: side,
          decoration: BoxDecoration(border: Border.all(color: onCamera, width: 2), borderRadius: BorderRadius.circular(24)),
        )),
        Align(
          alignment: const Alignment(0, .62),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: DecoratedBox(
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: ValueListenableBuilder<String?>(
                  valueListenable: widget.status ?? _noStatus,
                  builder: (context, status, _) => Text(
                    _cameraError ?? _hint ?? status ?? widget.hint ?? '把二维码放入框内',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, color: onCamera),
                  ),
                ),
              ),
            ),
          ),
        ),
        // 两指缩放（拉近远处的码），盖在取景框与提示上面（框的边框会接住触摸），按钮在它上面；一指的横滑照常交给 iOS 的右滑返回。
        RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            _PinchRecognizer: GestureRecognizerFactoryWithHandlers<_PinchRecognizer>(_PinchRecognizer.new, (recognizer) => recognizer
              ..onStart = ((_) => _pinchFrom = _zoom)
              ..onUpdate = (details) {
                if (details.pointerCount >= 2) unawaited(_setZoom(_pinchFrom * details.scale));
              }),
          },
        ),
        if (_camera != null && steps.length > 1)
          Align(
            alignment: const Alignment(0, .84),
            child: DecoratedBox(
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(28)),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  for (final step in steps) _ZoomStep(zoom: step, selected: (_zoom - step).abs() < .05, onPressed: () => _setZoom(step)),
                ]),
              ),
            ),
          ),
        // 取景页顶栏按钮用半透明深色圆底加白色图标（同系统相机）：玻璃会随取景画面变亮变暗，亮处的白色图标看不清。
        // 钉在顶部，铺满的 Stack 里不定位会被拉到正中。
        Positioned(top: 0, left: 0, right: 0, child: SafeArea(child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(children: [
            _CameraButton(tooltip: '返回', icon: CampusIcons.back, onPressed: () => Navigator.pop(context)),
            const Spacer(),
            if (_camera != null && _torchUsable) ...[
              _CameraButton(tooltip: _torch ? '关闭手电筒' : '打开手电筒', icon: CampusIcons.flashlight, onPressed: _toggleTorch),
              const SizedBox(width: 8),
            ],
            _CameraButton(tooltip: '从相册识别', icon: CampusIcons.scanImage, onPressed: _fromGallery),
          ]),
        ))),
      ]),
    );
  }
}

// 相册里的一张图：系统解码器边解边缩到 _galleryMaxSide（快，认得 HEIC），取出 RGBA 像素交给 zxing 在后台线程解，主线程不卡。
// 找不到码时返回 null。
Future<String?> _decodeFile(String path) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(await File(path).readAsBytes());
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final scale = math.min(1.0, _galleryMaxSide / math.max(descriptor.width, descriptor.height));
  final codec = await descriptor.instantiateCodec(targetWidth: (descriptor.width * scale).round(), targetHeight: (descriptor.height * scale).round());
  final frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  final image = frame.image;
  final (width, height) = (image.width, image.height);
  final pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  image.dispose();
  return Isolate.run(() {
    final code = zx.readBarcode(pixels, DecodeParams(imageFormat: ImageFormat.rgba, format: Format.qrCode, width: width, height: height, tryHarder: true, tryDownscale: true));
    return code.isValid ? code.text : null;
  });
}

// 两指一落下就认作缩放：iOS 的页面任意位置右滑返回（campus_transitions.dart）也在抢横向移动，两指分开时先走够距离的那根手指会被它拿走。
class _PinchRecognizer extends ScaleGestureRecognizer {
  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);
    if (event is PointerDownEvent && pointerCount >= 2) resolve(GestureDisposition.accepted);
  }
}

class _ZoomStep extends StatelessWidget {
  const _ZoomStep({required this.zoom, required this.selected, required this.onPressed});
  final double zoom;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: '拉近到 ${zoom.round()} 倍',
    excludeSemantics: true,
    child: GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(shape: BoxShape.circle, color: selected ? Colors.white : Colors.transparent),
        child: Text('${zoom.round()}×', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: selected ? Colors.black : Colors.white)),
      ),
    ),
  );
}

class _CameraButton extends StatelessWidget {
  const _CameraButton({required this.tooltip, required this.icon, required this.onPressed});
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: const ButtonStyle(backgroundColor: WidgetStatePropertyAll(Colors.black54), fixedSize: WidgetStatePropertyAll(Size(48, 48))),
    icon: CampusIcon(icon, color: Colors.white),
  );
}
