import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/toolbox/download/downloads_page.dart';
import 'package:superxd/toolbox/media_resource.dart';
import 'package:superxd/toolbox/short_video/media_preview.dart';
import 'package:superxd/toolbox/short_video/media_image.dart';
import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';
import 'package:superxd/toolbox/toolbox_models.dart';

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
  bool _busy = false;
  bool _expanded = false;
  String? _message;
  ParseResult get result => widget.outcome.result;
  ToolboxDownload? _saved(MediaResource media) => widget.runtime.downloads
      .forTool('short_video')
      .where(
        (item) =>
            item.identity == result.identity &&
            item.resourceId == media.id &&
            item.state == ToolboxDownloadState.saved,
      )
      .firstOrNull;
  Future<void> _preview(MediaResource media) async {
    final saved = _saved(media);
    if (saved != null) {
      try {
        await widget.runtime.downloads.open(saved.id);
      } catch (error, stack) {
        debugPrint(
          '[MediaResult] action=open_saved errorType=${error.runtimeType}\n$stack',
        );
        if (mounted) setState(() => _message = '本地文件无法打开，可从下载管理移除记录后重新下载');
      }
    } else if (mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => MediaPreview(media: media)),
      );
    }
  }

  Future<void> _download(List<MediaResource> media) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ids = await widget.runtime.downloads.downloadMedia(
        title: result.title,
        identity: result.identity,
        sourceUrl: result.sourceUrl,
        providerId: result.providerId,
        media: media,
      );
      if (mounted) setState(() => _message = '已加入下载，共${ids.length}项');
    } catch (error, stack) {
      debugPrint(
        '[MediaResult] action=download errorType=${error.runtimeType}\n$stack',
      );
      if (mounted) setState(() => _message = '下载未启动，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(Uri uri) async {
    try {
      await Clipboard.setData(ClipboardData(text: uri.toString()));
      if (mounted) setState(() => _message = '已复制，媒体直链可能过期');
    } catch (error, stack) {
      debugPrint(
        '[MediaResult] action=copy errorType=${error.runtimeType}\n$stack',
      );
      if (mounted) setState(() => _message = '复制未完成');
    }
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
          IconButton(
            tooltip: '下载管理',
            onPressed: () async {
              final task = await Navigator.push<ToolboxDownload>(
                context,
                MaterialPageRoute(
                  builder: (_) => DownloadsPage(runtime: widget.runtime),
                ),
              );
              if (task != null && context.mounted) Navigator.pop(context, task);
            },
            icon: const CampusIcon(CampusIcons.download),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: CustomScrollView(
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
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            if (result.title.length > 60)
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: () =>
                                      setState(() => _expanded = !_expanded),
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
                              children: [
                                TextButton(
                                  onPressed: () => _copy(result.sourceUrl),
                                  child: const Text('复制作品链接'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('重新解析'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (_message != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(_message!),
                        ),
                      if (result.cover case final cover?) ...[
                        const SizedBox(height: 16),
                        CampusSurface(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              AspectRatio(
                                aspectRatio: 16 / 9,
                                child: MediaImage(url: cover.url, width: 900),
                              ),
                              Wrap(
                                spacing: 8,
                                children: [
                                  TextButton(
                                    onPressed: () => _copy(cover.url),
                                    child: const Text('复制封面链接'),
                                  ),
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _download([cover]),
                                    child: const Text('下载封面'),
                                  ),
                                ],
                              ),
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
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  media.label,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  children: [
                                    if (media.kind == MediaKind.video)
                                      TextButton.icon(
                                        onPressed: () => _preview(media),
                                        icon: const CampusIcon(
                                          CampusIcons.video,
                                        ),
                                        label: Text(
                                          _saved(media) == null
                                              ? '预览'
                                              : '打开已保存视频',
                                        ),
                                      ),
                                    FilledButton.icon(
                                      onPressed: _busy
                                          ? null
                                          : () => _download([media]),
                                      icon: const CampusIcon(
                                        CampusIcons.download,
                                      ),
                                      label: Text(
                                        media.kind == MediaKind.audio
                                            ? '下载音乐'
                                            : '下载视频',
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () => _copy(media.url),
                                      child: const Text('复制链接'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (images.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '图片 ${images.length} 张',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            FilledButton(
                              onPressed: _busy ? null : () => _download(images),
                              child: const Text('全部下载'),
                            ),
                          ],
                        ),
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
                                  child: MediaImage(url: image.url, width: 500),
                                ),
                              ),
                              Wrap(
                                children: [
                                  IconButton(
                                    tooltip: '下载第${index + 1}张',
                                    onPressed: _busy
                                        ? null
                                        : () => _download([image]),
                                    icon: const CampusIcon(
                                      CampusIcons.download,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '复制图片链接',
                                    onPressed: () => _copy(image.url),
                                    icon: const CampusIcon(CampusIcons.paste),
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
            ),
          ),
        ),
      ),
    );
  }
}
