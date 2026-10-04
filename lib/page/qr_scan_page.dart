import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/page/appearance_page.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/glass_panel.dart';

// 扫好友二维码：相机取景（识别在本机完成，ML Kit 内置模型、不联网），也可从相册选一张截图识别。
// 只认 SuperXD 好友二维码，扫到其他内容原地提示，不跳转、不打开链接。返回解出的邀请。
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});
  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  String? _hint;
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _accept(Iterable<Barcode> barcodes) {
    if (_done) return;
    for (final barcode in barcodes) {
      final code = InviteCode.decode(barcode.rawValue ?? '');
      if (code != null) {
        _done = true;
        Navigator.pop(context, code);
        return;
      }
    }
    if (barcodes.isNotEmpty) setState(() => _hint = '不是 SuperXD 好友二维码');
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
    final colors = CampusPalette.of(context);
    // 相机画面上的文字与取景框固定用白色加阴影，与系统相机一致；不跟随配色，否则浅色字在亮处看不清。
    const onCamera = Colors.white;
    const shadow = [Shadow(blurRadius: 6, color: Colors.black54)];
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
            child: Text(_hint ?? '将好友的二维码放入框内', textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: onCamera, shadows: shadow)),
          ),
        ),
        // 顶栏按钮属于导航层，画玻璃。
        CampusChrome(child: SafeArea(child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(children: [
            CampusGlassCircleButton(label: '返回', size: 44, onPressed: () => Navigator.pop(context), icon: CampusIcon(CampusIcons.back, color: colors.onSurface)),
            const Spacer(),
            ValueListenableBuilder(
              valueListenable: _controller,
              builder: (context, state, _) => state.torchState == TorchState.unavailable
                  ? const SizedBox.shrink()
                  : CampusGlassCircleButton(label: state.torchState == TorchState.on ? '关闭手电筒' : '打开手电筒', size: 44, onPressed: _controller.toggleTorch, icon: CampusIcon(CampusIcons.flashlight, color: colors.onSurface)),
            ),
            const SizedBox(width: 8),
            CampusGlassCircleButton(label: '从相册识别', size: 44, onPressed: _fromGallery, icon: CampusIcon(CampusIcons.scanImage, color: colors.onSurface)),
          ]),
        ))),
      ]),
    );
  }
}
