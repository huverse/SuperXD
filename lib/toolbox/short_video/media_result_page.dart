import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/toolbox/download/download_status.dart';
import 'package:superxd/toolbox/download/downloads_page.dart';
import 'package:superxd/toolbox/download/toolbox_download_manager.dart';
import 'package:superxd/toolbox/media_resource.dart';
import 'package:superxd/toolbox/short_video/media_preview.dart';
import 'package:superxd/toolbox/short_video/media_image.dart';
import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/domain/campus_log.dart';

class MediaResultPage extends StatefulWidget {
  const MediaResultPage({
    super.key,
    required this.runtime,
    required this.outcome,
  });
  final ToolboxRuntime runtime;
  final ParseOutcome outcome;
  @override
  State<MediaResultPage> createState() => _MediaResultPageState();
}

class _MediaResultPageState extends State<MediaResultPage> {
  bool _enqueuing = false;
  bool _expanded = false;
  final _busy = <String>{};
  ParseResult get result => widget.outcome.result;
  ToolboxDownloadManager get _manager => widget.runtime.downloads;
  // forTool已按进行中优先、再按新旧排序；倒序覆盖后每个资源只留最该展示的一条。
  Map<String, ToolboxDownload> _latest() => {
    for (final item in _manager.forTool('short_video').reversed)
      if (item.identity == result.identity && item.resourceId != null)
        item.resourceId!: item,
  };
  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _operate(String id, Future<void> Function() action) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await action();
    } catch (error, stack) {
      campusLog(
        '[MediaResult] action=manage errorType=${error.runtimeType}\n$stack',
      );
      _notice(error is ToolboxException ? error.message : '操作未完成，请重试');
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _download(List<MediaResource> media) async {
    if (_enqueuing) return;
    setState(() => _enqueuing = true);
    try {
      await _manager.downloadMedia(
        title: result.title,
        identity: result.identity,
        sourceUrl: result.sourceUrl,
        providerId: result.providerId,
        media: media,
      );
    } catch (error, stack) {
      campusLog(
        '[MediaResult] action=download errorType=${error.runtimeType}\n$stack',
      );
      _notice(error is ToolboxException ? error.message : '下载未启动，请稍后重试');
    } finally {
      if (mounted) setState(() => _enqueuing = false);
    }
  }

  Future<void> _copy(Uri uri) async {
    try {
      await Clipboard.setData(ClipboardData(text: uri.toString()));
      _notice('已复制，媒体直链可能过期');
    } catch (error, stack) {
      campusLog(
        '[MediaResult] action=copy errorType=${error.runtimeType}\n$stack',
      );
      _notice('复制未完成');
    }
  }

  // 未下载或已取消给下载入口；下载后同一位置原地切换为进度、暂停继续、打开，不再只留一行提示。
  Widget _controls(
    MediaResource media,
    ToolboxDownload? latest,
    String downloadLabel,
  ) {
    final item = latest?.state == ToolboxDownloadState.cancelled
        ? null
        : latest;
    final failed = item?.state == ToolboxDownloadState.failed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (item != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: DownloadProgress(item: item),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (item == null || failed)
              FilledButton.icon(
                onPressed: _enqueuing ? null : () => _download([media]),
                icon: CampusIcon(
                  failed ? CampusIcons.sync : CampusIcons.download,
                ),
                label: Text(failed ? '重新下载' : downloadLabel),
              )
            else
              ...downloadActions(
                item: item,
                manager: _manager,
                busy: _busy.contains(item.id),
                operate: _operate,
              ),
            if (media.kind == MediaKind.video &&
                item?.state != ToolboxDownloadState.saved)
              TextButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => MediaPreview(media: media),
                  ),
                ),
                icon: const CampusIcon(CampusIcons.video),
                label: const Text('预览'),
              ),
            TextButton.icon(
              onPressed: () => _copy(media.url),
              icon: const CampusIcon(CampusIcons.paste),
              label: const Text('复制链接'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _tileAction(MediaResource image, int index, ToolboxDownload? item) {
    final palette = CampusPalette.of(context);
    final number = index + 1;
    VoidCallback? run(String id, Future<void> Function() action) =>
        _busy.contains(id) ? null : () => _operate(id, action);
    return switch (item) {
      null ||
      ToolboxDownload(state: ToolboxDownloadState.cancelled) => IconButton(
        tooltip: '下载第$number张',
        onPressed: _enqueuing ? null : () => _download([image]),
        icon: const CampusIcon(CampusIcons.download),
      ),
      ToolboxDownload(state: ToolboxDownloadState.failed) => IconButton(
        tooltip: '重新下载第$number张',
        onPressed: _enqueuing ? null : () => _download([image]),
        icon: CampusIcon(CampusIcons.sync, color: palette.danger),
      ),
      ToolboxDownload(state: ToolboxDownloadState.saved, :final id) =>
        IconButton(
          tooltip: '打开第$number张',
          onPressed: run(id, () => _manager.open(id)),
          icon: CampusIcon(CampusIcons.success, color: palette.primary),
        ),
      ToolboxDownload(saveFailed: true, :final id) => IconButton(
        tooltip: '重试保存第$number张',
        onPressed: run(id, () => _manager.save(id)),
        icon: CampusIcon(CampusIcons.warning, color: palette.danger),
      ),
      ToolboxDownload(state: ToolboxDownloadState.paused, :final id) =>
        IconButton(
          tooltip: '继续下载第$number张',
          onPressed: run(id, () => _manager.resumeTask(id)),
          icon: const CampusIcon(CampusIcons.resume),
        ),
      final item => IconButton(
        tooltip: '取消下载第$number张',
        onPressed:
            item.canCancel || item.state == ToolboxDownloadState.cancelling
            ? run(item.id, () => _manager.cancel(item.id))
            : null,
        icon: SizedBox.square(
          dimension: 24,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value:
                    item.state == ToolboxDownloadState.downloading &&
                        item.totalBytes > 0
                    ? item.progress
                    : null,
                strokeWidth: 2.5,
              ),
              const CampusIcon(CampusIcons.close, size: 12),
            ],
          ),
        ),
      ),
    };
  }

  Widget _gallerySummary(
    List<MediaResource> images,
    Map<String, ToolboxDownload> latest,
  ) {
    final items = [for (final image in images) latest[image.id]];
    final saved = items
        .where((item) => item?.state == ToolboxDownloadState.saved)
        .length;
    final failed = items
        .where((item) => item?.state == ToolboxDownloadState.failed)
        .length;
    final remaining = [
      for (final (index, image) in images.indexed)
        if (items[index] == null ||
            items[index]!.state == ToolboxDownloadState.cancelled ||
            items[index]!.state == ToolboxDownloadState.failed)
          image,
    ];
    // [人工决策-2026-10-01 22:31:55] 汇总“进行中”含排队等下载与等待保存的项，不拆成“下载中/排队”；逐张状态已能区分，汇总保持简短。下载管理页同口径。
    final active = images.length - saved - remaining.length;
    final progress =
        items.fold<double>(
          0,
          (sum, item) =>
              sum +
              switch (item?.state) {
                ToolboxDownloadState.saved => 1,
                ToolboxDownloadState.failed ||
                ToolboxDownloadState.cancelled ||
                null => 0,
                _ => item!.progress,
              },
        ) /
        images.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '图片 ${images.length} 张',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (remaining.length < images.length)
                    Text(
                      [
                        '已保存 $saved/${images.length}',
                        if (active > 0) '进行中 $active',
                        if (failed > 0) '未完成 $failed',
                      ].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            if (remaining.isNotEmpty)
              FilledButton.icon(
                onPressed: _enqueuing ? null : () => _download(remaining),
                icon: const CampusIcon(CampusIcons.download),
                label: Text(
                  remaining.length == images.length
                      ? '全部下载'
                      : '下载其余${remaining.length}张',
                ),
              ),
          ],
        ),
        if (active > 0) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: progress,
            borderRadius: BorderRadius.circular(4),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final images = result.images.toList();
    final videos = result.videos.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('解析结果'),
        leading: IconButton(
          tooltip: '返回',
          onPressed: () => Navigator.pop(context),
          icon: const CampusIcon(CampusIcons.back),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: CampusGlassCircleButton(
              label: '下载管理',
              size: 44,
              onPressed: () async {
                final task = await Navigator.push<ToolboxDownload>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => DownloadsPage(runtime: widget.runtime),
                  ),
                );
                if (task != null && context.mounted) {
                  Navigator.pop(context, task);
                }
              },
              icon: const CampusIcon(CampusIcons.download),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListenableBuilder(
              listenable: _manager,
              builder: (context, _) {
                final latest = _latest();
                return CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.all(16),
                      sliver: SliverList.list(
                        children: [
                          CampusSurface(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  result.title.isEmpty ? '解析成功' : result.title,
                                  maxLines: _expanded ? null : 3,
                                  overflow: _expanded
                                      ? null
                                      : TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                                if (result.title.length > 60)
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton(
                                      onPressed: () => setState(
                                        () => _expanded = !_expanded,
                                      ),
                                      child: Text(_expanded ? '收起' : '展开'),
                                    ),
                                  ),
                                if (result.author.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Text(result.author),
                                  ),
                                const SizedBox(height: 8),
                                Text(
                                  '来源：${widget.runtime.coordinator.providers[result.providerId]!.source.name}${widget.outcome.fromCache ? ' · 最近缓存' : ''}',
                                  style: TextStyle(
                                    color: CampusPalette.of(context)
                                        .onSurfaceVariant,
                                  ),
                                ),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  children: [
                                    TextButton.icon(
                                      onPressed: () => _copy(result.sourceUrl),
                                      icon: const CampusIcon(CampusIcons.paste),
                                      label: const Text('复制作品链接'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      icon: const CampusIcon(CampusIcons.sync),
                                      label: const Text('重新解析'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (result.cover case final cover?) ...[
                            const SizedBox(height: 16),
                            CampusSurface(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  AspectRatio(
                                    aspectRatio: 16 / 9,
                                    child: MediaImage(
                                      url: cover.url,
                                      width: 900,
                                    ),
                                  ),
                                  _controls(cover, latest[cover.id], '下载封面'),
                                ],
                              ),
                            ),
                          ],
                          for (final media in [...videos, ...result.audio])
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: CampusSurface(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      media.label,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium,
                                    ),
                                    _controls(
                                      media,
                                      latest[media.id],
                                      media.kind == MediaKind.audio
                                          ? '下载音乐'
                                          : '下载视频',
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (images.isNotEmpty) ...[
                            const SizedBox(height: 20),
                            _gallerySummary(images, latest),
                            const SizedBox(height: 12),
                          ],
                        ],
                      ),
                    ),
                    if (images.isNotEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        sliver: SliverGrid.builder(
                          itemCount: images.length,
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 280,
                                childAspectRatio: .8,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                              ),
                          itemBuilder: (context, index) {
                            final image = images[index];
                            return CampusSurface(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                children: [
                                  Expanded(
                                    child: InkWell(
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute<void>(
                                          builder: (_) => GalleryPreview(
                                            images: images,
                                            initialIndex: index,
                                          ),
                                        ),
                                      ),
                                      child: MediaImage(
                                        url: image.url,
                                        width: 500,
                                      ),
                                    ),
                                  ),
                                  Wrap(
                                    children: [
                                      _tileAction(
                                        image,
                                        index,
                                        latest[image.id],
                                      ),
                                      IconButton(
                                        tooltip: '复制图片链接',
                                        onPressed: () => _copy(image.url),
                                        icon: const CampusIcon(
                                          CampusIcons.paste,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
