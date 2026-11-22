import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'package:superxd/domain/campus_log.dart';

// 播放器的真实状态（11-21 Codex 总交接第 12.5 节）：media_kit 的 seek 一交出命令就返回（0–1 毫秒）、position 立刻报成目标，
// 都不代表画面恢复了（如意《交锋2026》跳 20:00，模拟器上 seeking 5.9 秒后才变回 no）；缓存也只给一个末端（demuxer-cache-time），
// 实际能本地跳转的缓存常是好几段不连续的（[0,49]、[1198,1283]…），从零画到末端会让人以为中间都缓存好了。
// 这里直接问 libmpv：
// - 跳转分两个指标：原生恢复（seeking 变回 no，且此刻的位置就是这次的目标，挡掉上一次跳转晚到的 no，11-21 Codex 复核时复现过把后一次记成 0 毫秒）；
//   目标处走起来（恢复后播放时钟越过目标 playingLead：mpv 的时钟跟着输出的画面走，算「在目标处出画并播起来」，不是屏幕截帧，media_kit 拿不到逐帧回调）。
// - 缓存分三种：真实的几段、明确没有（播放器给了空的 seekable-ranges）、读不到（null，测试替身或还没收到）；跳转记 cached=true、false、unknown。
class CinemaPlaybackTruth {
  CinemaPlaybackTruth(this._player) : _native = _player.platform is NativePlayer ? _player.platform as NativePlayer : null {
    if (_native case final native?) {
      unawaited(native.observeProperty('demuxer-cache-state', (value) async => _cacheState(value)).catchError(_observeFailed));
      unawaited(native.observeProperty('seeking', (value) async => _seeking(value)).catchError(_observeFailed));
    }
    _positions = _player.stream.position.listen(_position);
  }

  // 跳转迟迟不恢复时最多等这么久，到点记 timeout（没恢复）或 stalled（恢复了但没走起来）。
  static const seekLimit = Duration(seconds: 20);
  // 原生恢复时的位置离目标多远以内算这一次的（mpv 精确跳转落在目标上，晚到的上一次的 no 读到的是上一次的落点）。
  static const seekTolerance = Duration(milliseconds: 1500);
  // 恢复后播放时钟越过目标这么多算走起来了；超出目标 playingWindow 的不算（又被别的跳走了）。
  static const playingLead = Duration(milliseconds: 300);
  static const playingWindow = Duration(seconds: 6);

  final Player _player;
  final NativePlayer? _native;
  late final StreamSubscription<Duration> _positions;

  // 真实能本地跳转的缓存段，按起点排好；明确没有为空列表，读不到为 null。
  final seekable = ValueNotifier<List<(Duration, Duration)>?>(null);
  // 网络层最近的下载速率（字节每秒，demuxer-cache-state 的 raw-input-rate），读不到为空；开发者模式下卡顿时记（11-22 Codex 复核：先分清是线路慢还是缓冲策略）。
  int? inputRate;

  var _seekId = 0;
  _PendingSeek? _pending;
  var _disposed = false;

  // 发出一次跳转（命令交给播放器之前调）：记下目标当时在不在缓存段里，等原生恢复、走起来后回报；连着跳只回报最后一次，前面的记 superseded。
  Future<CinemaSeekResult> begin(Duration target) {
    _pending?.finish('superseded');
    final ranges = seekable.value;
    final pending = _pending = _PendingSeek(id: ++_seekId, target: target, cached: ranges?.any((range) => range.$1 <= target && target <= range.$2));
    pending.timer = Timer(seekLimit, () => pending.finish(pending.restartMs == null ? 'timeout' : 'stalled'));
    return pending.done.future;
  }

  // 换了媒体（换集、换源、重新载入）：还在等的跳转不再算。
  void reset() => _pending?.finish('cancelled');

  void _seeking(String value) {
    final pending = _pending;
    // seeking 一闪而过（命中缓存时 yes、no 挨得很近）时两次通知读到的可能都是 no，所以不要求先看到 yes；归属靠位置核对。
    if (value != 'no' || pending == null || pending.restartMs != null || pending.done.isCompleted) return;
    if ((_player.state.position - pending.target).abs() > seekTolerance) return;
    pending.restartMs = pending.watch.elapsedMilliseconds;
    // 暂停着跳的不会走起来，原生恢复就算完。
    if (!_player.state.playing) return pending.finish('ok');
    _position(_player.state.position);
  }

  void _position(Duration position) {
    final pending = _pending;
    if (pending == null || pending.restartMs == null) return;
    if (position >= pending.target + playingLead && position <= pending.target + playingWindow) {
      pending.playingMs ??= pending.watch.elapsedMilliseconds;
      pending.finish('ok');
    }
  }

  void _cacheState(String raw) {
    final state = _decodeCacheState(raw);
    final rate = state is Map ? state['raw-input-rate'] : null;
    inputRate = rate is num && rate >= 0 ? rate.round() : null;
    _ranges(_seekableRangesOf(state));
  }

  void _ranges(List<(Duration, Duration)>? ranges) {
    // 播放器在离开页面后才释放，晚到的通知不写已经释放的 seekable。
    if (_disposed) return;
    final old = seekable.value;
    if (ranges == null ? old != null : (old == null || !listEquals(ranges, old))) seekable.value = ranges;
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

  // 测试替身不是 libmpv：直接喂 seeking、demuxer-cache-state 的字符串与播放位置（核对归属用的位置照旧读播放器的 state）。
  @visibleForTesting
  void notify({String? seeking, String? cacheState, Duration? position}) {
    if (cacheState != null) _cacheState(cacheState);
    if (seeking != null) _seeking(seeking);
    if (position != null) _position(position);
  }

  void dispose() {
    _disposed = true;
    _pending?.finish('cancelled');
    unawaited(_positions.cancel());
    seekable.dispose();
  }
}

class CinemaSeekResult {
  const CinemaSeekResult({required this.id, required this.target, required this.cached, required this.result, required this.restartMs, required this.playingMs});
  final int id;
  final Duration target;
  // 跳转发出时目标在不在缓存段里；读不到缓存段为 null（日志写 unknown，不当成确定没命中）。
  final bool? cached;
  // ok、timeout（没恢复）、stalled（恢复了没走起来）、superseded、cancelled。
  final String result;
  // 原生恢复（seeking 变回 no 且位置对得上）用时；目标处走起来用时（暂停着跳的、没走起来的为空）。
  final int? restartMs;
  final int? playingMs;
}

class _PendingSeek {
  _PendingSeek({required this.id, required this.target, required this.cached});
  final int id;
  final Duration target;
  final bool? cached;
  final watch = Stopwatch()..start();
  final done = Completer<CinemaSeekResult>();
  Timer? timer;
  int? restartMs;
  int? playingMs;

  void finish(String result) {
    timer?.cancel();
    if (!done.isCompleted) done.complete(CinemaSeekResult(id: id, target: target, cached: cached, result: result, restartMs: restartMs, playingMs: playingMs));
  }
}

// demuxer-cache-state 的字符串（libmpv 把节点写成 JSON）→ 能本地跳转的缓存段，按起点排、起点不小于零、精确到 100 毫秒（少一点无谓的重画）。
// 是播放器给的外部输入：读不懂、没有 seekable-ranges、或列了段却一段都读不懂时为 null（读不到）；给了空列表是明确没有缓存，返回空列表。
List<(Duration, Duration)>? cinemaSeekableRanges(String raw) => _seekableRangesOf(_decodeCacheState(raw));

Object? _decodeCacheState(String raw) {
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}

List<(Duration, Duration)>? _seekableRangesOf(Object? state) {
  final list = state is Map ? state['seekable-ranges'] : null;
  if (list is! List) return null;
  Duration at(num seconds) => Duration(milliseconds: (seconds * 10).round() * 100);
  final ranges = [
    for (final item in list)
      if (item is Map && item['start'] is num && item['end'] is num && (item['end'] as num) > (item['start'] as num))
        (at(((item['start'] as num) < 0 ? 0 : item['start'] as num)), at(item['end'] as num)),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return ranges.isEmpty && list.isNotEmpty ? null : ranges;
}
