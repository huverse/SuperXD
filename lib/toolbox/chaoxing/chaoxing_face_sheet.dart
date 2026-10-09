import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:superxd/toolbox/chaoxing/chaoxing_image_pick.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 人脸照片：每个账号最多 5 张，照片本身在学习通云盘，这里显示预览、用过几次、有没有被判失败过。
// pick 为真时点一张就返回它的 objectId（签到时选这次用哪张）；否则是管理模式，可以删。
Future<String?> showChaoxingFaceSheet(
  BuildContext context, {
  required ChaoxingController controller,
  required ChaoxingAccountRecord record,
  required ToolboxImagePick? pickImage,
  bool pick = false,
}) => showCampusSheet<String>(
  context: context,
  builder: (context) => _ChaoxingFaceSheet(controller: controller, record: record, pickImage: pickImage, pick: pick),
);

class _ChaoxingFaceSheet extends StatefulWidget {
  const _ChaoxingFaceSheet({required this.controller, required this.record, required this.pickImage, required this.pick});
  final ChaoxingController controller;
  final ChaoxingAccountRecord record;
  final ToolboxImagePick? pickImage;
  final bool pick;
  @override
  State<_ChaoxingFaceSheet> createState() => _ChaoxingFaceSheetState();
}

class _ChaoxingFaceSheetState extends State<_ChaoxingFaceSheet> {
  List<ChaoxingFaceImage>? _images;
  String? _error;
  bool _working = false;
  // 正在处理的是哪一个来源（学习通默认照片、拍摄、相册）：忙碌状态只显示在点的那个按钮上。
  String? _busySource;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final images = await widget.controller.faces.faceImages(widget.record);
      if (mounted) setState(() => _images = images);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=face_list errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '人脸照片没读到，请重试');
    }
  }

  Future<void> _run(Future<void> Function() action, String fallback, {String? source}) async {
    if (_working) return;
    setState(() {
      _working = true;
      _busySource = source;
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
      if (mounted) {
        setState(() {
          _working = false;
          _busySource = null;
        });
      }
    }
  }

  Future<void> _upload(ImageSource source) => _run(() async {
    // 相册或现场拍摄都进 3:4 裁剪页（可旋转翻转，对齐参考项目）再上传。
    final bytes = await pickChaoxingFacePhoto(widget.pickImage, source: source);
    if (bytes == null || !mounted) return;
    await widget.controller.faces.uploadFaceImage(widget.record, bytes);
  }, '人脸照片上传失败，请重试', source: source.name);

  Future<void> _fromProfile() => _run(() async {
    final objectId = await widget.controller.faces.importProfileFace(widget.record);
    if (objectId == null) throw const ChaoxingFailure(ChaoxingFailureCode.faceRequired, '学习通里还没有存人脸照片');
  }, '学习通里的人脸照片没取到，请重试', source: 'profile');

  Future<void> _remove(ChaoxingFaceImage image) async {
    final agreed = await showCampusConfirm(
      context,
      title: '删除这张人脸照片？',
      message: '只删本机的记录，学习通云盘里的照片不受影响。',
      action: '删除',
      destructive: true,
    );
    if (!agreed || !mounted) return;
    await _run(() => widget.controller.faces.removeFaceImage(widget.record, image.objectId), '删除没完成，请重试');
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
                        key: ValueKey(image.objectId),
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
                      // 处理中只在点的那个按钮上原地转（取图、裁剪与上传都算），其余按钮一起禁用。
                      for (final (source, icon, label, action) in [
                        ('profile', CampusIcons.scanFace, '用学习通里存的那张', _fromProfile),
                        (ImageSource.camera.name, CampusIcons.camera, '现拍一张', () => _upload(ImageSource.camera)),
                        (ImageSource.gallery.name, CampusIcons.image, '相册选一张', () => _upload(ImageSource.gallery)),
                      ])
                        OutlinedButton(
                          onPressed: _working || full ? null : action,
                          child: CampusBusyContent(busy: _busySource == source, label: label, busyLabel: '处理中', icon: CampusIcon(icon)),
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
  const _FaceTile({super.key, required this.controller, required this.image, this.onPick, this.onRemove});
  final ChaoxingController controller;
  final ChaoxingFaceImage image;
  final VoidCallback? onPick;
  final VoidCallback? onRemove;
  @override
  State<_FaceTile> createState() => _FaceTileState();
}

class _FaceTileState extends State<_FaceTile> {
  late Future<Uint8List> _bytes = _fetch();

  // 预览取图失败时格子里给重试，日志里留原因。
  Future<Uint8List> _fetch() async {
    try {
      return await widget.controller.faces.faceImageBytes(widget.image.objectId);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=face_preview errorType=${failure is ChaoxingFailure ? failure.code.name : failure.runtimeType}\n$stack');
      rethrow;
    }
  }

  @override
  void didUpdateWidget(_FaceTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 行按 objectId 定键，正常不会换照片；万一换了要重取，不能接着显示上一张。
    if (oldWidget.image.objectId != widget.image.objectId) _bytes = _fetch();
  }

  Future<void> _menu(BuildContext anchor) async {
    final onRemove = widget.onRemove;
    final action = await showCampusMenu<String>(anchor, items: [
      const CampusMenuItem(value: 'save', label: '保存到本机', icon: CampusIcons.download),
      if (onRemove != null) const CampusMenuItem(value: 'remove', label: '删除这张照片', icon: CampusIcons.delete, destructive: true),
    ]);
    if (!mounted) return;
    if (action == 'save') await _save();
    if (action == 'remove') onRemove?.call();
  }

  // 保存到本机：把云盘里的原图导出成公共下载目录里的 JPEG 文件。
  Future<void> _save() async {
    try {
      await widget.controller.faces.saveFaceImage(widget.image.objectId);
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
      padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
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
                      _bytes = _fetch();
                    }),
                    icon: const CampusIcon(CampusIcons.sync),
                  ),
                  _ => const Center(child: CampusLoader(size: 20, delay: Duration.zero)),
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
          // 同课程管理卡片：低频操作收进右上⋯，删除标警示色并确认；选照片时整卡点按即选。
          Builder(
            builder: (anchor) => IconButton(tooltip: '照片操作', onPressed: () => _menu(anchor), icon: const CampusIcon(CampusIcons.manage)),
          ),
          if (widget.onPick != null) const CampusIcon(CampusIcons.next),
        ],
      ),
    );
  }
}
