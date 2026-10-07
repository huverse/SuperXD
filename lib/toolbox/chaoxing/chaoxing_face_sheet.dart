import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:superxd/toolbox/chaoxing/chaoxing_image_pick.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';

// 人脸照片：每个账号最多 5 张，照片本身在学习通云盘，这里显示预览、用过几次、有没有被判失败过。
// pick 为真时点一张就返回它的 objectId（签到时选这次用哪张）；否则是管理模式，可以删。
Future<String?> showChaoxingFaceSheet(
  BuildContext context, {
  required ChaoxingController controller,
  required ChaoxingAccountRecord record,
  bool pick = false,
}) => showCampusSheet<String>(
  context: context,
  builder: (context) => _ChaoxingFaceSheet(controller: controller, record: record, pick: pick),
);

class _ChaoxingFaceSheet extends StatefulWidget {
  const _ChaoxingFaceSheet({required this.controller, required this.record, required this.pick});
  final ChaoxingController controller;
  final ChaoxingAccountRecord record;
  final bool pick;
  @override
  State<_ChaoxingFaceSheet> createState() => _ChaoxingFaceSheetState();
}

class _ChaoxingFaceSheetState extends State<_ChaoxingFaceSheet> {
  List<ChaoxingFaceImage>? _images;
  String? _error;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final images = await widget.controller.faceImages(widget.record);
      if (mounted) setState(() => _images = images);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=face_list errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '人脸照片没读到，请重试');
    }
  }

  Future<void> _run(Future<void> Function() action, String fallback) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await action();
      await _load();
    } on ChaoxingFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=face_sheet errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = fallback);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _upload(ImageSource source) => _run(() async {
    // 相册或现场拍摄都进 3:4 裁剪页（可旋转翻转，对齐参考项目）再上传。
    final bytes = await pickChaoxingFacePhoto(context, source: source);
    if (bytes == null || !mounted) return;
    await widget.controller.uploadFacePhoto(widget.record, bytes);
  }, '人脸照片上传失败，请重试');

  Future<void> _fromProfile() => _run(() async {
    final objectId = await widget.controller.importProfileFace(widget.record);
    if (objectId == null) throw const ChaoxingFailure(ChaoxingFailureCode.faceRequired, '学习通里还没有存人脸照片');
  }, '学习通里的人脸照片没取到，请重试');

  Future<void> _remove(ChaoxingFaceImage image) async {
    final agreed = await showCampusConfirm(
      context,
      title: '删除这张人脸照片？',
      message: '只删本机的记录，学习通云盘里的照片不受影响。',
      action: '删除',
      destructive: true,
    );
    if (!agreed || !mounted) return;
    await _run(() => widget.controller.removeFaceImage(widget.record, image.objectId), '删除没完成，请重试');
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final images = _images;
    final full = (images?.length ?? 0) >= ChaoxingStore.faceImageLimit;
    return CampusSheetPanel(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 12, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.pick ? '选这次用的人脸照片' : '${widget.record.name} 的人脸照片',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(tooltip: '关闭', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.close)),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (images == null && _error == null)
                    const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: CampusLoading(label: '正在读取…', inline: true))
                  else if (images != null && images.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text('还没有人脸照片', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
                    )
                  else
                    for (final image in images ?? const <ChaoxingFaceImage>[])
                      _FaceTile(
                        controller: widget.controller,
                        image: image,
                        onPick: widget.pick ? () => Navigator.pop(context, image.objectId) : null,
                        onRemove: widget.pick || _working ? null : () => _remove(image),
                      ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: TextStyle(fontSize: 14, color: palette.danger)),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _working || full ? null : () => _fromProfile(),
                        icon: const CampusIcon(CampusIcons.scanFace),
                        label: const Text('用学习通里存的那张'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _working || full ? null : () => _upload(ImageSource.camera),
                        icon: const CampusIcon(CampusIcons.camera),
                        label: const Text('现拍一张'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _working || full ? null : () => _upload(ImageSource.gallery),
                        icon: const CampusIcon(CampusIcons.image),
                        label: Text(_working ? '处理中' : '相册选一张'),
                      ),
                    ],
                  ),
                  if (full)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('最多存 ${ChaoxingStore.faceImageLimit} 张，删掉一张再加', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FaceTile extends StatefulWidget {
  const _FaceTile({required this.controller, required this.image, this.onPick, this.onRemove});
  final ChaoxingController controller;
  final ChaoxingFaceImage image;
  final VoidCallback? onPick;
  final VoidCallback? onRemove;
  @override
  State<_FaceTile> createState() => _FaceTileState();
}

class _FaceTileState extends State<_FaceTile> {
  late Future<Uint8List> _bytes = widget.controller.faceImageBytes(widget.image.objectId);

  // 保存到本机：把云盘里的原图导出成公共下载目录里的 JPEG 文件。
  Future<void> _save() async {
    try {
      await widget.controller.saveFaceImage(widget.image.objectId);
      if (!mounted) return;
      await showCampusNotice(context, '已保存到下载目录');
    } on ChaoxingFailure catch (failure) {
      if (mounted) await showCampusNotice(context, failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=face_save errorType=${failure.runtimeType}\n$stack');
      if (mounted) await showCampusNotice(context, '保存失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final image = widget.image;
    return CampusSurface(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      radius: 16,
      onTap: widget.onPick,
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 64,
              height: 64,
              child: FutureBuilder<Uint8List>(
                future: _bytes,
                builder: (context, snapshot) => switch (snapshot) {
                  AsyncSnapshot(hasData: true, :final data?) => Image.memory(data, fit: BoxFit.cover),
                  AsyncSnapshot(hasError: true) => IconButton(
                    tooltip: '重新加载照片',
                    onPressed: () => setState(() {
                      _bytes = widget.controller.faceImageBytes(image.objectId);
                    }),
                    icon: const CampusIcon(CampusIcons.sync),
                  ),
                  _ => const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                },
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('用过 ${image.useCount} 次', style: TextStyle(fontSize: 14, color: palette.onSurface)),
                if (image.failedBefore)
                  Text('曾经没通过人脸识别', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
              ],
            ),
          ),
          if (widget.onPick != null) const CampusIcon(CampusIcons.next),
          IconButton(tooltip: '保存到本机', onPressed: _save, icon: const CampusIcon(CampusIcons.download)),
          if (widget.onRemove != null)
            IconButton(tooltip: '删除这张照片', onPressed: widget.onRemove, icon: const CampusIcon(CampusIcons.delete)),
        ],
      ),
    );
  }
}
