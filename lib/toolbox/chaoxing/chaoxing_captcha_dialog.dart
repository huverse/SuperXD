import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_captcha.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_photo.dart';

// 滑块验证：底图上拖着缺口块对齐，松手提交位置换 validate；不通过就换一张重来。
Future<String?> showChaoxingCaptchaDialog(
  BuildContext context, {
  required Future<ChaoxingCaptchaPuzzle> Function() load,
  required Future<Uint8List> Function(String url) loadImage,
  required Future<ChaoxingCaptchaAnswer> Function(ChaoxingCaptchaPuzzle puzzle, double position) verify,
}) => showCampusDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (_) => ChaoxingCaptchaDialog(load: load, loadImage: loadImage, verify: verify),
);

class ChaoxingCaptchaDialog extends StatefulWidget {
  const ChaoxingCaptchaDialog({super.key, required this.load, required this.loadImage, required this.verify});
  final Future<ChaoxingCaptchaPuzzle> Function() load;
  final Future<Uint8List> Function(String url) loadImage;
  final Future<ChaoxingCaptchaAnswer> Function(ChaoxingCaptchaPuzzle puzzle, double position) verify;
  @override
  State<ChaoxingCaptchaDialog> createState() => _ChaoxingCaptchaDialogState();
}

class _ChaoxingCaptchaDialogState extends State<ChaoxingCaptchaDialog> {
  // 底图按验证码自己的 280 宽显示，拖动距离与提交坐标一一对应。
  static const _boardWidth = chaoxingCaptchaCanvasWidth;

  ChaoxingCaptchaPuzzle? _puzzle;
  Uint8List? _shade;
  Uint8List? _piece;
  String? _error;
  bool _checking = false;
  double _pieceLeft = 0;
  double _travel = 0;
  double _boardHeight = 0;
  double _pieceWidth = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  // keepError：没对齐自动换图时保留「没有对齐」的原因，让人看得到为什么换了一张。
  Future<void> _reload({String? keepError}) async {
    setState(() {
      _puzzle = null;
      _shade = null;
      _piece = null;
      _error = keepError;
      _pieceLeft = 0;
    });
    try {
      final puzzle = await widget.load();
      final shade = await widget.loadImage(puzzle.shadeImageUrl);
      final piece = await widget.loadImage(puzzle.cutoutImageUrl);
      // 只为量尺寸也要整图解码，放到后台 isolate，不卡拖动与弹窗动画。
      final shadeSize = await compute(_sizeOf, shade);
      final pieceSize = await compute(_sizeOf, piece);
      if (!mounted) return;
      final boardHeight = shadeSize == null ? 160.0 : _boardWidth * shadeSize.height / shadeSize.width;
      final pieceWidth = pieceSize == null || pieceSize.height == 0 ? 56.0 : boardHeight * min(1.0, pieceSize.width / pieceSize.height);
      setState(() {
        _puzzle = puzzle;
        _shade = shade;
        _piece = piece;
        _boardHeight = boardHeight;
        _pieceWidth = pieceWidth;
        _travel = max(0, _boardWidth - pieceWidth);
      });
    } on ChaoxingFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=captcha errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = chaoxingCaptchaLoadFailedMessage);
    }
  }

  static ({int width, int height})? _sizeOf(Uint8List bytes) {
    final decoded = decodeChaoxingPhoto(bytes);
    return decoded == null ? null : (width: decoded.width, height: decoded.height);
  }

  Future<void> _verify() async {
    final puzzle = _puzzle;
    if (puzzle == null || _checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final answer = await widget.verify(puzzle, chaoxingCaptchaPosition(_pieceLeft, _travel));
      if (!mounted) return;
      if (answer.passed) {
        Navigator.pop(context, answer.validate);
        return;
      }
      await _reload(keepError: answer.message ?? '没有对齐，再来一次');
    } on ChaoxingFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=captcha_check errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '验证没做完，请重试');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return CampusGlassDialog(
      solid: true,
      title: const Text('安全验证'),
      actions: [
        TextButton(onPressed: _checking ? null : () => Navigator.pop(context), child: const Text('取消')),
        TextButton(onPressed: _checking ? null : () => _reload(), child: const Text('换一张')),
      ],
      content: SizedBox(
        width: _boardWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _checking ? '正在验证…' : '把缺口块拖到缺口处，松手自动验证',
              style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            _board(palette),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(fontSize: 14, color: palette.danger)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _board(CampusPalette palette) {
    final shade = _shade;
    final piece = _piece;
    if (shade == null || piece == null) {
      return SizedBox(
        height: 160,
        child: Center(child: CampusLoading(label: '正在加载验证码…', inline: true)),
      );
    }
    return GestureDetector(
      onHorizontalDragUpdate: _checking
          ? null
          : (details) => setState(() => _pieceLeft = (_pieceLeft + details.delta.dx).clamp(0.0, _travel)),
      onHorizontalDragEnd: _checking ? null : (_) => _verify(),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: _boardWidth,
          height: _boardHeight,
          child: Stack(
            children: [
              Positioned.fill(child: Image.memory(shade, fit: BoxFit.fill, gaplessPlayback: true)),
              Positioned(
                left: _pieceLeft,
                top: 0,
                width: _pieceWidth,
                height: _boardHeight,
                child: Image.memory(piece, fit: BoxFit.fill, gaplessPlayback: true),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
