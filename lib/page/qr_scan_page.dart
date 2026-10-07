import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/page/appearance_page.dart';
import 'package:superxd/theme/campus_icons.dart';

// 通用扫码页：相机取景（识别在本机完成，ML Kit 内置模型、不联网），也可从相册选一张截图识别。
// 只把内容交给调用方的 accept 判断，认下的原样返回，不跳转、不打开链接；不认的原地提示后继续扫。
// 好友二维码与课堂签到二维码共用这一页，accept 由调用方给（见 friend_add_page.dart 与 main.dart）。
// 连续模式（onCode 非空）：认下的码交给 onCode 后接着扫，until 完成时自动关；status 是取景页上的进度文字。
// 课堂二维码会定时刷新，给多人连签时要一直对着老师的屏幕，用的就是这个模式。
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

class _QrScanPageState extends State<QrScanPage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  String? _hint;
  bool _done = false;

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
    _controller.dispose();
    _noStatus.dispose();
    super.dispose();
  }

  void _accept(Iterable<Barcode> barcodes) {
    if (_done) return;
    for (final barcode in barcodes) {
      final raw = barcode.rawValue ?? '';
      if (raw.isEmpty) continue;
      final rejected = widget.accept(raw);
      if (rejected == null) {
        final onCode = widget.onCode;
        if (onCode != null) {
          setState(() => _hint = null);
          onCode(raw);
          continue;
        }
        _done = true;
        Navigator.pop(context, raw);
        return;
      }
      setState(() => _hint = rejected);
    }
  }

  // 相册识别：复用壁纸的选图（系统照片选择器只给选中的那一张，不申请存储权限），识别完即删插件留在缓存里的副本。
  Future<void> _fromGallery() async {
    try {
      final picked = await pickWallpaperFromGallery();
      if (picked == null) return;
      final BarcodeCapture? capture;
      try {
        capture = await _controller.analyzeImage(picked.path, formats: const [BarcodeFormat.qrCode]);
      } finally {
        await picked.discard();
      }
      if (!mounted) return;
      if (capture == null || capture.barcodes.isEmpty) {
        setState(() => _hint = '这张图里没有找到二维码');
      } else {
        _accept(capture.barcodes);
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        MobileScanner(
          controller: _controller,
          onDetect: (capture) => _accept(capture.barcodes),
          errorBuilder: (context, error) => Center(child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              error.errorCode == MobileScannerErrorCode.permissionDenied ? '没有相机权限，可在系统设置中开启，或从相册选择二维码截图' : '相机暂不可用，可从相册选择二维码截图',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: onCamera),
            ),
          )),
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
                    _hint ?? status ?? widget.hint ?? '把二维码放入框内',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, color: onCamera),
                  ),
                ),
              ),
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
            ValueListenableBuilder(
              valueListenable: _controller,
              builder: (context, state, _) => state.torchState == TorchState.unavailable
                  ? const SizedBox.shrink()
                  : _CameraButton(tooltip: state.torchState == TorchState.on ? '关闭手电筒' : '打开手电筒', icon: CampusIcons.flashlight, onPressed: _controller.toggleTorch),
            ),
            const SizedBox(width: 8),
            _CameraButton(tooltip: '从相册识别', icon: CampusIcons.scanImage, onPressed: _fromGallery),
          ]),
        ))),
      ]),
    );
  }
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
