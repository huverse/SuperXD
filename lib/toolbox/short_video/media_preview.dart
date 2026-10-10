import 'dart:async';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/toolbox/short_video/media_resource.dart';
import 'package:superxd/toolbox/short_video/media_image.dart';
import 'package:superxd/domain/campus_log.dart';

class MediaPreview extends StatefulWidget {
  const MediaPreview({super.key, required this.media});
  final MediaResource media;
  @override
  State<MediaPreview> createState() => _MediaPreviewState();
}

class _MediaPreviewState extends State<MediaPreview>
    with WidgetsBindingObserver {
  VideoPlayerController? _video;
  ChewieController? _controls;
  String? _error;
  bool _loading = true;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    final previous = _video;
    _controls?.dispose();
    _controls = null;
    _video = null;
    await previous?.dispose();
    if (!mounted || generation != _generation) return;
    final video = VideoPlayerController.networkUrl(
      widget.media.url,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    _video = video;
    try {
      await video.initialize().timeout(const Duration(seconds: 20));
      if (!mounted || generation != _generation) {
        await video.dispose();
        return;
      }
      _controls = ChewieController(
        videoPlayerController: video,
        autoPlay: false,
        looping: false,
        allowMuting: true,
        allowPlaybackSpeedChanging: true,
        errorBuilder: (context, error) =>
            const Center(child: Text('播放未完成，请重新解析或下载后打开')),
      );
    } catch (error, stack) {
      campusLog(
        '[MediaPreview] action=initialize errorType=${error.runtimeType}\n$stack',
      );
      await video.dispose();
      if (mounted && generation == _generation) {
        _video = null;
        _error = '预览不可用，可重试或返回重新解析';
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _video?.pause().catchError((Object error, StackTrace stack) {
        campusLog(
          '[MediaPreview] action=pause errorType=${error.runtimeType}\n$stack',
        );
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _controls?.dispose();
    _video?.dispose().catchError((Object error, StackTrace stack) {
      campusLog(
        '[MediaPreview] action=dispose errorType=${error.runtimeType}\n$stack',
      );
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.media.label),
      leading: IconButton(
        tooltip: '返回',
        onPressed: () => Navigator.pop(context),
        icon: const CampusIcon(CampusIcons.back),
      ),
    ),
    body: SafeArea(
      child: Center(
        child: _loading
            ? const CampusLoading(label: '正在准备预览')
            : _error != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  TextButton(onPressed: _load, child: const Text('重试')),
                ],
              )
            : AspectRatio(
                aspectRatio: _video!.value.aspectRatio,
                child: Chewie(controller: _controls!),
              ),
      ),
    ),
  );
}

class GalleryPreview extends StatefulWidget {
  const GalleryPreview({
    super.key,
    required this.images,
    required this.initialIndex,
  });
  final List<MediaResource> images;
  final int initialIndex;
  @override
  State<GalleryPreview> createState() => _GalleryPreviewState();
}

class _GalleryPreviewState extends State<GalleryPreview> {
  late final _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('${_index + 1} / ${widget.images.length}'),
      leading: IconButton(
        tooltip: '返回',
        onPressed: () => Navigator.pop(context),
        icon: const CampusIcon(CampusIcons.back),
      ),
    ),
    body: SafeArea(
      child: PageView.builder(
        controller: _pages,
        itemCount: widget.images.length,
        onPageChanged: (index) => setState(() => _index = index),
        itemBuilder: (context, index) => InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Center(
            child: MediaImage(url: widget.images[index].url, width: 1600),
          ),
        ),
      ),
    ),
  );
}
