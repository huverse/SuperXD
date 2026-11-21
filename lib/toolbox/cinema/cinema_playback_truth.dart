import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'package:superxd/domain/campus_log.dart';

// 播放器的真实状态（11-21 Codex 总交接第 12.5 节）：media_kit 的 seek 一交出命令就返回（0–1 毫秒）、position 立刻报成目标，
// 都不代表画面恢复了（如意《交锋2026》跳 20:00，模拟器上 seeking 5.9 秒后才变回 no）；缓存也只给一个末端（demuxer-cache-time），
// 实际能本地跳转的缓存常是好几段不连续的（[0,49]、[1198,1283]…），从零画到末端会让人以为中间都缓存好了。
// 这里直接问 libmpv：seeking 从 yes 变回 no 是跳转真正恢复的时刻，demuxer-cache-state 的 seekable-ranges 是真实能本地跳转的几段。
// 不是 libmpv 的播放器（测试替身）问不到：缓存段为空（进度条退回只画当前位置到缓存末端），跳转不计时。
class CinemaPlaybackTruth {
  CinemaPlaybackTruth(Player player) : _native = player.platform is NativePlayer ? player.platform as NativePlayer : null {
    if (_native case final native?) {
      unawaited(native.observeProperty('demuxer-cache-state', (value) async => _ranges(cinemaSeekableRanges(value))).catchError(_observeFailed));
      unawaited(native.observeProperty('seeking', (value) async => _seeking(value)).catchError(_observeFailed));
    }
  }

  // 跳转迟迟不恢复时最多等这么久，到点记 timeout。
  static const seekLimit = Duration(seconds: 20);

  // 真实能本地跳转的缓存段，按起点排好；问不到为空。
  final seekable = ValueNotifier<List<(Duration, Duration)>>(const []);

  final NativePlayer? _native;
  var _seekId = 0;
  _PendingSeek? _pending;
  var _disposed = false;

  // 发出一次跳转（命令交给播放器之前调）：记下目标当时在不在缓存段里，等 seeking 变回 no 时回报这一次用了多久。
  // 连着跳只回报最后一次，前面没等到的记 superseded。
  Future<CinemaSeekResult> begin(Duration target) {
    _pending?.finish('superseded');
    final pending = _pending = _PendingSeek(id: ++_seekId, target: target, cached: seekable.value.any((range) => range.$1 <= target && target <= range.$2));
    pending.timer = Timer(seekLimit, () => pending.finish('timeout'));
    return pending.done.future;
  }

  void _seeking(String value) {
    // seeking 一闪而过（命中缓存时 yes、no 挨得很近）时两次通知读到的可能都是 no：跳转发出后来了 seeking 的通知、当前是 no，就算恢复了。
    if (value != 'no') return;
    _pending?.finish('ok');
  }

  void _ranges(List<(Duration, Duration)> ranges) {
    // 播放器在离开页面后才释放，晚到的通知不写已经释放的 seekable。
    if (!_disposed && !listEquals(ranges, seekable.value)) seekable.value = ranges;
  }

  void _observeFailed(Object error, StackTrace stack) => campusLog('[CinemaPlayer] action=observe errorType=${error.runtimeType}\n$stack');

  // 开发者模式下首帧时记一次解码器与内核版本（Codex 第 12.6 节：真机上缓存命中了回看还慢，先看是不是硬解没开、解码慢）；问不到为空。
  // 值里的空格换成下划线，日志照旧是 key=value。
  Future<String> decoder() async {
    final native = _native;
    if (native == null) return '';
    final values = await Future.wait([for (final name in const ['hwdec-current', 'mpv-version', 'ffmpeg-version']) native.getProperty(name)]);
    String plain(String value) => value.trim().replaceAll(RegExp(r'\s+'), '_');
    return 'hwdec=${plain(values[0])} mpv=${plain(values[1])} ffmpeg=${plain(values[2])}';
  }

  // 测试替身不是 libmpv：直接喂 seeking 与 demuxer-cache-state 的字符串。
  @visibleForTesting
  void notify({String? seeking, String? cacheState}) {
    if (cacheState != null) _ranges(cinemaSeekableRanges(cacheState));
    if (seeking != null) _seeking(seeking);
  }

  void dispose() {
    _disposed = true;
    _pending?.finish('cancelled');
    seekable.dispose();
  }
}

class CinemaSeekResult {
  const CinemaSeekResult({required this.id, required this.target, required this.cached, required this.result, required this.ms});
  final int id;
  final Duration target;
  // 跳转发出时目标在不在缓存段里（真机上「回看还慢」先看这一项）。
  final bool cached;
  // ok、timeout、superseded、cancelled。
  final String result;
  final int ms;
}

class _PendingSeek {
  _PendingSeek({required this.id, required this.target, required this.cached});
  final int id;
  final Duration target;
  final bool cached;
  final watch = Stopwatch()..start();
  final done = Completer<CinemaSeekResult>();
  Timer? timer;

  void finish(String result) {
    timer?.cancel();
    if (!done.isCompleted) done.complete(CinemaSeekResult(id: id, target: target, cached: cached, result: result, ms: watch.elapsedMilliseconds));
  }
}

// demuxer-cache-state 的字符串（libmpv 把节点写成 JSON）→ 能本地跳转的缓存段，按起点排、起点不小于零、精确到 100 毫秒（少一点无谓的重画）。
// 是播放器给的外部输入：读不懂或缺字段的段不要，整份读不懂为空。
List<(Duration, Duration)> cinemaSeekableRanges(String raw) {
  final Object? state;
  try {
    state = jsonDecode(raw);
  } on FormatException {
    return const [];
  }
  final list = state is Map ? state['seekable-ranges'] : null;
  if (list is! List) return const [];
  Duration at(num seconds) => Duration(milliseconds: (seconds * 10).round() * 100);
  final ranges = [
    for (final item in list)
      if (item is Map && item['start'] is num && item['end'] is num && (item['end'] as num) > (item['start'] as num))
        (at(((item['start'] as num) < 0 ? 0 : item['start'] as num)), at(item['end'] as num)),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return ranges;
}
