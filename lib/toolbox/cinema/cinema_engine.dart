import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/cinema/cinema_playback_truth.dart';

// [人工决策-2026-11-21 19:50:59] 电影院的播放内核（用户选「安卓默认改用 ExoPlayer」并加「允许用户自己切换播放内核」，说按最佳实践做）：
// 11-21 真机对照（华为，硬解）：跳到没看过的位置 mpv 中位 7.1 秒、ExoPlayer 3.3 秒（6 次全快）；往前、往回小段拖动两边都在 1 秒内；
// 回到很早看过的位置 mpv 0.8 秒、ExoPlayer 2.8 秒（ExoPlayer 只留 backBuffer 那么长的回看）。mpv 慢在 FFmpeg 的 HLS 跳转按清单时间找分片、
// 再按分片里的时间戳往后读到目标（这类片源两者差十几秒，多读好几个分片）。按此：
// - 安卓默认系统播放器（video_player 的 ExoPlayer，回看缓冲 backBuffer），iOS 默认 mpv（系统播放器 AVPlayer 没在 iPhone 上验过）；
// - 播放页「播放内核」可以换，记在本机（设备级，清除数据时删）；换了立即在当前位置用新内核重开；
// - 系统播放器在出首帧之前打不开（格式不支持、初始化失败、首帧前报错）时，这一页自动退回 mpv 再开一次，不打扰用户（日志记 engine_fallback）。
// 控件、手势、本机代理、换源与续播不变，只换底下的内核；两边按同一个 CinemaEngine 接口（字段名照 media_kit，播放页与控件只换类型）。

enum CinemaEngineKind {
  system,
  mpv;

  // 菜单里写的名字：安卓上系统播放器就是 ExoPlayer。
  String get label => switch (this) {
    CinemaEngineKind.system => defaultTargetPlatform == TargetPlatform.iOS ? '系统播放器' : 'ExoPlayer',
    CinemaEngineKind.mpv => 'mpv',
  };
}

// 没选过时用哪个：安卓系统播放器，其余 mpv。
CinemaEngineKind get cinemaDefaultEngine => defaultTargetPlatform == TargetPlatform.android ? CinemaEngineKind.system : CinemaEngineKind.mpv;

// 本机记下的选择（CinemaService.enginePreference）→ 内核；没记过或认不出用默认。
CinemaEngineKind cinemaEngineOf(String? saved) => CinemaEngineKind.values.where((kind) => kind.name == saved).firstOrNull ?? cinemaDefaultEngine;

// 测试用：换掉真的内核（真的要 libmpv 或系统播放器的原生实现），同 Flutter 的 debugDefaultTargetPlatformOverride。
@visibleForTesting
CinemaEngine Function(CinemaEngineKind kind)? debugCinemaEngineFactory;

CinemaEngine createCinemaEngine(CinemaEngineKind kind) => debugCinemaEngineFactory?.call(kind) ?? (kind == CinemaEngineKind.system ? CinemaSystemEngine() : CinemaMpvEngine());

// 系统播放器打不开（播放页据此退回 mpv）。
class CinemaEngineException implements Exception {
  const CinemaEngineException(this.message);
  final String message;
  @override
  String toString() => 'CinemaEngineException: $message';
}

// 某一刻的状态（字段名与含义照 media_kit 的 PlayerState：音量 0–100，buffer 是往前缓冲到哪）。
class CinemaEngineState {
  const CinemaEngineState({this.position = Duration.zero, this.duration = Duration.zero, this.buffer = Duration.zero, this.playing = false, this.volume = 100, this.rate = 1, this.width, this.height});
  final Duration position;
  final Duration duration;
  final Duration buffer;
  final bool playing;
  final double volume;
  final double rate;
  final int? width;
  final int? height;
}

class CinemaEngineStreams {
  const CinemaEngineStreams({required this.position, required this.duration, required this.playing, required this.buffering, required this.completed, required this.error, required this.width, required this.height});
  final Stream<Duration> position;
  final Stream<Duration> duration;
  final Stream<bool> playing;
  final Stream<bool> buffering;
  final Stream<bool> completed;
  final Stream<String> error;
  final Stream<int?> width;
  final Stream<int?> height;
}

abstract class CinemaEngine {
  CinemaEngineKind get kind;
  CinemaEngineState get state;
  CinemaEngineStreams get stream;
  // 正在放的媒体地址（播放页据此认事件是不是这一次交出去的，换集、重新载入时旧视频晚到的事件不算）。
  String? get currentUri;
  // 真实能本地跳转的缓存段（明确没有为空列表，读不到为 null，见 cinema_playback_truth.dart）。
  ValueListenable<List<(Duration, Duration)>?> get seekable;
  // 网络层最近的下载速率（字节每秒），问不到为空（系统播放器不报）；开发者模式下卡顿时记。
  int? get inputRate;
  // 打开一个媒体，start 大于零从那里开始；playlist 是 HLS 清单（本机代理的地址没有 .m3u8 后缀，系统播放器要明说）。
  Future<void> open(String uri, Map<String, String> headers, {Duration start = Duration.zero, bool playlist = false});
  Future<void> seek(Duration target);
  Future<void> playOrPause();
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
  // 画面：fit 是铺法，ratio 不为空时按这个比例铺满（画面比例菜单）。
  Widget view({required BoxFit fit, double? ratio});
  // 开发者模式的跳转计时（命令交出前调，见 CinemaPlaybackTruth.begin）；换媒体时 resetSeeks 放弃还在等的。
  Future<CinemaSeekResult> beginSeek(Duration target);
  void resetSeeks();
  // 开发者模式首帧时记一次：哪个内核、解码器与版本。
  Future<String> describe();
  Future<void> dispose();
}

// libmpv 每个进程只要初始化一次。
var _mediaKitReady = false;

// mpv（media_kit）：原来的播放器，跳转与缓存的真实状态经 CinemaPlaybackTruth 问 libmpv。
class CinemaMpvEngine implements CinemaEngine {
  factory CinemaMpvEngine() {
    if (!_mediaKitReady) {
      MediaKit.ensureInitialized();
      _mediaKitReady = true;
    }
    final player = Player();
    return CinemaMpvEngine._(player, VideoController(player));
  }

  // 测试用：接一个已有的播放器（测试替身没有画面）。
  @visibleForTesting
  CinemaMpvEngine.wrap(Player player) : this._(player, null);

  CinemaMpvEngine._(this._player, this._video) : _truth = CinemaPlaybackTruth(_player) {
    final source = _player.stream;
    stream = CinemaEngineStreams(position: source.position, duration: source.duration, playing: source.playing, buffering: source.buffering, completed: source.completed, error: source.error, width: source.width, height: source.height);
  }

  final Player _player;
  final VideoController? _video;
  final CinemaPlaybackTruth _truth;

  @override
  CinemaEngineKind get kind => CinemaEngineKind.mpv;

  @override
  late final CinemaEngineStreams stream;

  @override
  CinemaEngineState get state {
    final value = _player.state;
    return CinemaEngineState(position: value.position, duration: value.duration, buffer: value.buffer, playing: value.playing, volume: value.volume, rate: value.rate, width: value.width, height: value.height);
  }

  @override
  String? get currentUri {
    final playlist = _player.state.playlist;
    return playlist.index >= 0 && playlist.index < playlist.medias.length ? playlist.medias[playlist.index].uri : null;
  }

  @override
  ValueListenable<List<(Duration, Duration)>?> get seekable => _truth.seekable;

  @override
  int? get inputRate => _truth.inputRate;

  @override
  Future<void> open(String uri, Map<String, String> headers, {Duration start = Duration.zero, bool playlist = false}) =>
      _player.open(Media(uri, httpHeaders: headers, start: start > Duration.zero ? start : null));

  @override
  Future<void> seek(Duration target) => _player.seek(target);

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Widget view({required BoxFit fit, double? ratio}) {
    final video = _video;
    if (video == null) return const ColoredBox(color: Colors.black);
    return Video(controller: video, controls: NoVideoControls, fit: fit, aspectRatio: ratio, fill: Colors.black);
  }

  @override
  Future<CinemaSeekResult> beginSeek(Duration target) => _truth.begin(target);

  @override
  void resetSeeks() => _truth.reset();

  @override
  Future<String> describe() async => 'engine=mpv ${await _truth.decoder()}';

  @override
  Future<void> dispose() async {
    _truth.dispose();
    await _player.dispose();
  }
}

// 系统播放器的请求头：video_player 只认首字母大写的 User-Agent（小写的会被当成普通头、UA 却用它自己的默认值），
// 片源的 CDN 按 UA 掐断非浏览器请求，所以把常见的两个改成标准写法，其余原样。
Map<String, String> cinemaSystemHeaders(Map<String, String> headers) => {
  for (final entry in headers.entries)
    switch (entry.key.toLowerCase()) {
      'user-agent' => 'User-Agent',
      'referer' => 'Referer',
      _ => entry.key,
    }: entry.value,
};

// 系统播放器（video_player：安卓 ExoPlayer、iOS AVPlayer）：每个媒体一个控制器，换媒体时丢掉旧的（旧的事件随之不再来）。
// 回看缓冲 backBuffer（ExoPlayer 默认不留看过的，真机回看 8 秒要 0.8 秒、不留要约 3 秒）；进度每 tick 问一次（video_player 自己半秒一次，进度条会一顿一顿）。
// 缓存段问不到（video_player 的 buffered 只给零到往前缓冲的末端），seekable 一直是读不到；跳转计时只有「目标处走起来」，没有原生恢复。
class CinemaSystemEngine implements CinemaEngine {
  static const backBuffer = Duration(minutes: 2);
  static const tick = Duration(milliseconds: 250);

  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _playings = StreamController<bool>.broadcast();
  final _bufferings = StreamController<bool>.broadcast();
  final _completions = StreamController<bool>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _widths = StreamController<int?>.broadcast();
  final _heights = StreamController<int?>.broadcast();
  final _shown = ValueNotifier<VideoPlayerController?>(null);

  @override
  final ValueNotifier<List<(Duration, Duration)>?> seekable = ValueNotifier(null);

  @override
  int? get inputRate => null;

  VideoPlayerController? _controller;
  // 各控制器还没回来的 play（释放前等它，见 _drop）。
  final _playing = Expando<Future<void>>();
  String? _uri;
  var _value = const VideoPlayerValue.uninitialized();
  var _position = Duration.zero;
  Timer? _poll;
  var _rate = 1.0;
  var _volume = 100.0;
  var _seekId = 0;
  _SystemSeek? _pending;
  var _disposed = false;

  @override
  CinemaEngineKind get kind => CinemaEngineKind.system;

  @override
  late final CinemaEngineStreams stream = CinemaEngineStreams(
    position: _positions.stream,
    duration: _durations.stream,
    playing: _playings.stream,
    buffering: _bufferings.stream,
    completed: _completions.stream,
    error: _errors.stream,
    width: _widths.stream,
    height: _heights.stream,
  );

  @override
  CinemaEngineState get state {
    final value = _value;
    final size = value.size;
    return CinemaEngineState(
      position: _position,
      duration: value.duration,
      buffer: value.buffered.isEmpty ? Duration.zero : value.buffered.last.end,
      playing: value.isPlaying,
      volume: _volume,
      rate: _rate,
      width: size.width > 0 ? size.width.round() : null,
      height: size.height > 0 ? size.height.round() : null,
    );
  }

  @override
  String? get currentUri => _uri;

  @override
  Future<void> open(String uri, Map<String, String> headers, {Duration start = Duration.zero, bool playlist = false}) async {
    _drop();
    _uri = uri;
    final controller = _controller = VideoPlayerController.networkUrl(
      Uri.parse(uri),
      formatHint: playlist ? VideoFormat.hls : null,
      httpHeaders: cinemaSystemHeaders(headers),
      videoPlayerOptions: VideoPlayerOptions(backBufferDurationMs: backBuffer.inMilliseconds),
    );
    controller.addListener(_changed);
    try {
      await controller.initialize();
      if (!identical(_controller, controller)) return;
      await controller.setPlaybackSpeed(_rate);
      await controller.setVolume(_volume / 100);
      if (start > Duration.zero) await controller.seekTo(start);
      await _play(controller);
    } catch (error, stack) {
      campusLog('[CinemaPlayer] action=system_open errorType=${error.runtimeType}\n$stack');
      if (identical(_controller, controller)) throw const CinemaEngineException('系统播放器打不开这个片源');
      return;
    }
    if (!identical(_controller, controller) || _disposed) return;
    _shown.value = controller;
    _poll = Timer.periodic(tick, (_) => unawaited(_tick(controller)));
  }

  // video_player（2.14.1，即 pub.dev 最新版）的 play 先等平台调用，回来才起每 100 毫秒问一次位置的定时器；中间被 dispose 的话定时器照起、
  // 之后永远不取消（回调见已释放就返回），控制器一直留在内存里、一直定时唤醒（11-22 Codex 复核）。所以 play 都经这里记下，释放前等它回来（见 _drop）。
  Future<void> _play(VideoPlayerController controller) => _playing[controller] = controller.play();

  // 丢掉上一个媒体的控制器（不再听它的事件）；还有没回来的 play 时等它回来再释放（见 _play）。
  void _drop() {
    _poll?.cancel();
    final old = _controller;
    _controller = null;
    _shown.value = null;
    _value = const VideoPlayerValue.uninitialized();
    _position = Duration.zero;
    if (old == null) return;
    old.removeListener(_changed);
    final playing = _playing[old] ?? Future<void>.value();
    unawaited(
      playing
          .then<void>((_) {}, onError: (Object _) {})
          .then((_) => old.dispose())
          .catchError((Object error, StackTrace stack) => campusLog('[CinemaPlayer] action=system_dispose errorType=${error.runtimeType}\n$stack')),
    );
  }

  void _changed() {
    final controller = _controller;
    if (controller == null || _disposed) return;
    final old = _value, value = _value = controller.value;
    if (value.duration != old.duration) _durations.add(value.duration);
    if (value.isPlaying != old.isPlaying) _playings.add(value.isPlaying);
    if (value.isBuffering != old.isBuffering) _bufferings.add(value.isBuffering);
    if (value.isCompleted != old.isCompleted) _completions.add(value.isCompleted);
    if (value.size != old.size) {
      final size = state;
      _widths.add(size.width);
      _heights.add(size.height);
    }
    if (value.hasError && value.errorDescription != old.errorDescription) _errors.add(value.errorDescription ?? '系统播放器出错');
    _moved(value.position);
  }

  Future<void> _tick(VideoPlayerController controller) async {
    final Duration? position;
    try {
      position = await controller.position;
    } catch (error, stack) {
      // 换媒体或离开时控制器刚释放，最后一次问可能落空。
      if (identical(_controller, controller)) campusLog('[CinemaPlayer] action=system_position errorType=${error.runtimeType}\n$stack');
      return;
    }
    if (position != null && identical(_controller, controller) && !_disposed) _moved(position);
  }

  void _moved(Duration position) {
    if (position == _position) return;
    _position = position;
    _positions.add(position);
    final pending = _pending;
    if (pending != null && position >= pending.target + CinemaPlaybackTruth.playingLead && position <= pending.target + CinemaPlaybackTruth.playingWindow) {
      pending.playingMs ??= pending.watch.elapsedMilliseconds;
      pending.finish('ok');
    }
  }

  @override
  Future<void> seek(Duration target) async {
    final controller = _controller;
    if (controller == null) return;
    await controller.seekTo(target);
    _moved(target);
  }

  @override
  Future<void> playOrPause() async {
    final controller = _controller;
    if (controller == null) return;
    await (controller.value.isPlaying ? controller.pause() : _play(controller));
  }

  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
    await _controller?.setPlaybackSpeed(rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    await _controller?.setVolume(volume / 100);
  }

  @override
  Widget view({required BoxFit fit, double? ratio}) => ValueListenableBuilder<VideoPlayerController?>(
    valueListenable: _shown,
    builder: (context, controller, _) {
      if (controller == null) return const ColoredBox(color: Colors.black);
      final size = controller.value.size;
      final video = SizedBox(width: size.width, height: size.height, child: VideoPlayer(controller));
      return ColoredBox(
        color: Colors.black,
        child: ClipRect(
          child: ratio == null
              ? SizedBox.expand(child: FittedBox(fit: fit, child: video))
              : Center(child: AspectRatio(aspectRatio: ratio, child: FittedBox(fit: BoxFit.fill, child: video))),
        ),
      );
    },
  );

  // 跳转计时：发出时目标在往前缓冲里是 true、超过往前缓冲的末端是 false，往回的看不出（回看缓冲不报）记 null；只有「目标处走起来」。
  @override
  Future<CinemaSeekResult> beginSeek(Duration target) {
    _pending?.finish('superseded');
    final now = state;
    final cached = target >= now.position && target <= now.buffer ? true : (target > now.buffer ? false : null);
    final pending = _pending = _SystemSeek(id: ++_seekId, target: target, cached: cached);
    pending.timer = Timer(CinemaPlaybackTruth.seekLimit, () => pending.finish('timeout'));
    return pending.done.future;
  }

  @override
  void resetSeeks() => _pending?.finish('cancelled');

  @override
  Future<String> describe() async => 'engine=${defaultTargetPlatform == TargetPlatform.iOS ? 'avplayer' : 'exoplayer'} backBufferMs=${backBuffer.inMilliseconds}';

  @override
  Future<void> dispose() async {
    _disposed = true;
    _pending?.finish('cancelled');
    _drop();
    _shown.dispose();
    seekable.dispose();
    for (final controller in [_positions, _durations, _playings, _bufferings, _completions, _errors, _widths, _heights]) {
      await controller.close();
    }
  }
}

class _SystemSeek {
  _SystemSeek({required this.id, required this.target, required this.cached});
  final int id;
  final Duration target;
  final bool? cached;
  final watch = Stopwatch()..start();
  final done = Completer<CinemaSeekResult>();
  Timer? timer;
  int? playingMs;

  void finish(String result) {
    timer?.cancel();
    if (!done.isCompleted) done.complete(CinemaSeekResult(id: id, target: target, cached: cached, result: result, restartMs: null, playingMs: playingMs));
  }
}
