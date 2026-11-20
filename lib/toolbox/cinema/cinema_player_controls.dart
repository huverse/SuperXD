import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:screen_brightness/screen_brightness.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/curve_geometry.dart';
import 'package:superxd/toolbox/cinema/cinema_poster.dart';

// [人工决策-2026-11-20 16:40:37] 播放器整体重做（用户嫌原来单调、别扭、黑边大，要求深度借鉴 Kazumi 与主流流媒体平台；用户选定双击暂停或继续、全屏真横屏）：
// 控件全部自己画（不用 media_kit 自带的，它的转圈会和我们的加载动画叠在一起），手势与布局照 Kazumi（GPL-3.0，与本项目同许可，出处见 assets/third_party_notices.txt）
// 的 player_item.dart 与 B 站、爱奇艺的常见做法：
// - 单击显示或收起控件（播放中 cinemaControlsHide 后自动收起），双击暂停或继续，长按 cinemaLongPressSpeed 倍速、松手恢复；
// - 左右滑动调进度（滑满屏宽是 3 分钟，同 Kazumi），中间写目标时刻与跨度，松手才跳；左半边上下滑调亮度（只改本应用窗口），右半边调音量（播放器音量）；
// - 锁定后只认单击、只露出锁；上栏返回、片名、倍速与画面比例，下栏播放暂停、下一集、进度（含已缓冲的一段）、选集、全屏；
// - 画面比例同 Kazumi 的 PlayerAspectRatio（自动、裁切填充、拉伸填充、16:9、4:3），倍速 0.5–3 倍；
// - 片头 5 分钟内给「跳过片头」（往后 cinemaSkipIntro，同 Kazumi 的 buttonSkipTime）；接着看的给「从头播放」；播完有下一集时倒数 cinemaAutoNext 自动连播，可取消。

// 画面比例（同 Kazumi）：ratio 不为空时按这个比例铺满给定区域（拉伸到这个比例）。
enum CinemaFit {
  automatic('自动', BoxFit.contain, null),
  crop('裁切填充', BoxFit.cover, null),
  stretch('拉伸填充', BoxFit.fill, null),
  ratio16x9('16:9', BoxFit.contain, 16 / 9),
  ratio4x3('4:3', BoxFit.contain, 4 / 3);

  const CinemaFit(this.label, this.fit, this.ratio);
  final String label;
  final BoxFit fit;
  final double? ratio;
}

const cinemaSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
const cinemaLongPressSpeed = 2.0;
const cinemaSkipIntro = Duration(seconds: 80);
const cinemaControlsHide = Duration(seconds: 4);
const cinemaAutoNext = Duration(seconds: 5);
// 左右滑满一屏宽跳多少（Kazumi 是 180000 毫秒）。
const _seekPerScreen = Duration(minutes: 3);

String cinemaSpeedLabel(double speed) => speed == speed.roundToDouble() ? '${speed.toInt()}×' : '$speed×';

enum _Panel { speed, fit, episodes }

enum _Adjust { brightness, volume }

class CinemaPlayerControls extends StatefulWidget {
  const CinemaPlayerControls({
    super.key,
    required this.player,
    required this.title,
    required this.subtitle,
    required this.fullscreen,
    required this.busy,
    required this.fit,
    required this.onFit,
    required this.onBack,
    required this.onFullscreen,
    this.error,
    this.hint,
    this.onReload,
    this.reloadLabel = '重新载入',
    this.onNext,
    this.episodes = const [],
    this.episode = 0,
    this.onEpisode,
    this.resumedFrom,
  });
  final Player player;
  final String title;
  final String subtitle;
  final bool fullscreen;
  // 打开中或卡住缓冲：画加载动画。
  final bool busy;
  final CinemaFit fit;
  final ValueChanged<CinemaFit> onFit;
  final VoidCallback onBack;
  final VoidCallback onFullscreen;
  // 出错的说明：画在画面中间并给「重新载入」，不画加载动画。
  final String? error;
  // 等太久的提示：写在加载动画下面。
  final String? hint;
  final VoidCallback? onReload;
  final String reloadLabel;
  // 有下一集才有。
  final VoidCallback? onNext;
  // 当前线路的集名（全屏时右侧选集面板用），episode 是正在播的那集。
  final List<String> episodes;
  final int episode;
  final ValueChanged<int>? onEpisode;
  // 从上次的位置接着看时给，画「从头播放」。
  final Duration? resumedFrom;

  @override
  State<CinemaPlayerControls> createState() => _CinemaPlayerControlsState();
}

class _CinemaPlayerControlsState extends State<CinemaPlayerControls> {
  final _subscriptions = <StreamSubscription<Object?>>[];
  var _visible = true;
  var _locked = false;
  Timer? _hide;
  _Panel? _panel;
  // 双击后在中间闪一下的图标。
  IconData? _flash;
  Timer? _flashTimer;
  // 左右滑动调进度：起点、目标。
  Duration? _seekFrom, _seekTo;
  // 长按倍速前的倍速。
  double? _boostFrom;
  // 上下滑动调亮度或音量：哪一种、现在的值（0–1）。
  _Adjust? _adjust;
  double _adjustValue = 0;
  Timer? _adjustTimer;
  double? _brightness;
  // 播完自动连播的倒数（秒），为空是没在倒数。
  int? _countdown;
  Timer? _countdownTimer;
  var _resumeShown = false;
  Timer? _resumeTimer;
  // 选的倍速（长按倍速松手后回到它）。
  var _rate = 1.0;

  Player get _player => widget.player;

  @override
  void initState() {
    super.initState();
    _subscriptions
      ..add(_player.stream.playing.listen((playing) {
        if (!mounted) return;
        if (playing) {
          _scheduleHide();
        } else {
          _hide?.cancel();
          setState(() => _visible = true);
        }
      }))
      ..add(_player.stream.completed.listen((done) {
        if (done && mounted && widget.onNext != null) _startCountdown();
      }));
    _rate = _player.state.rate;
    _showResume();
    unawaited(ScreenBrightness.instance.application.then((value) => _brightness = value).catchError((Object error, StackTrace stack) {
      campusLog('[CinemaPlayer] action=brightness errorType=${error.runtimeType}\n$stack');
      return 0.5;
    }));
  }

  @override
  void didUpdateWidget(CinemaPlayerControls old) {
    super.didUpdateWidget(old);
    // 换了一集：收起倒数与上一集的「从头播放」。
    if (old.subtitle != widget.subtitle || old.title != widget.title) {
      _cancelCountdown();
      _showResume();
    }
    if (old.busy && !widget.busy) {
      _scheduleHide();
      _expireResume();
    }
  }

  // 接着看的给「从头播放」：开播后停 8 秒（首屏缓冲常要十几秒，打开中不计时）。
  void _showResume() {
    _resumeTimer?.cancel();
    final from = widget.resumedFrom;
    _resumeShown = from != null && from > const Duration(seconds: 5);
    if (!widget.busy) _expireResume();
  }

  void _expireResume() {
    if (!_resumeShown) return;
    _resumeTimer?.cancel();
    _resumeTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _resumeShown = false);
    });
  }

  void _scheduleHide() {
    _hide?.cancel();
    if (!_player.state.playing || _panel != null || widget.busy) return;
    _hide = Timer(cinemaControlsHide, () {
      if (mounted && _player.state.playing && _panel == null) setState(() => _visible = false);
    });
  }

  void _show() {
    setState(() => _visible = true);
    _scheduleHide();
  }

  void _toggle() {
    if (_panel != null) return _closePanel();
    if (_visible) {
      _hide?.cancel();
      setState(() => _visible = false);
    } else {
      _show();
    }
  }

  void _playOrPause() {
    final playing = _player.state.playing;
    unawaited(_player.playOrPause());
    _flashTimer?.cancel();
    setState(() => _flash = playing ? CampusIcons.pause : CampusIcons.resume);
    _flashTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  void _openPanel(_Panel panel) {
    _hide?.cancel();
    setState(() {
      _panel = panel;
      _visible = true;
    });
  }

  void _closePanel() {
    setState(() => _panel = null);
    _scheduleHide();
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    setState(() {
      _countdown = cinemaAutoNext.inSeconds;
      _visible = true;
    });
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final left = (_countdown ?? 1) - 1;
      if (!mounted) return timer.cancel();
      if (left > 0) return setState(() => _countdown = left);
      _cancelCountdown();
      widget.onNext?.call();
    });
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    if (_countdown != null && mounted) setState(() => _countdown = null);
  }

  // 左右滑动：滑满屏宽 _seekPerScreen，松手才跳。
  void _seekStart(DragStartDetails _) {
    if (_locked) return;
    setState(() => _seekFrom = _seekTo = _player.state.position);
  }

  void _seekUpdate(DragUpdateDetails details, double width) {
    final from = _seekFrom, to = _seekTo;
    if (from == null || to == null) return;
    final duration = _player.state.duration;
    final moved = to + Duration(milliseconds: (details.delta.dx / width * _seekPerScreen.inMilliseconds).round());
    setState(() => _seekTo = moved < Duration.zero ? Duration.zero : (duration > Duration.zero && moved > duration ? duration : moved));
  }

  void _seekEnd() {
    final to = _seekTo;
    if (to != null) unawaited(_player.seek(to));
    setState(() => _seekFrom = _seekTo = null);
  }

  // 上下滑动：左半边亮度、右半边音量，向上调大；滑过区域高度的八成从 0 到满。
  void _adjustStart(DragStartDetails details, double width) {
    if (_locked) return;
    final adjust = details.localPosition.dx < width / 2 ? _Adjust.brightness : _Adjust.volume;
    _adjustTimer?.cancel();
    setState(() {
      _adjust = adjust;
      _adjustValue = adjust == _Adjust.brightness ? (_brightness ?? 0.5) : (_player.state.volume / 100).clamp(0.0, 1.0);
    });
  }

  void _adjustUpdate(DragUpdateDetails details, double height) {
    final adjust = _adjust;
    if (adjust == null) return;
    final value = (_adjustValue - details.delta.dy / (height * 0.8)).clamp(0.0, 1.0);
    setState(() => _adjustValue = value);
    if (adjust == _Adjust.brightness) {
      _brightness = value;
      unawaited(ScreenBrightness.instance.setApplicationScreenBrightness(value).catchError((Object error, StackTrace stack) => campusLog('[CinemaPlayer] action=brightness errorType=${error.runtimeType}\n$stack')));
    } else {
      unawaited(_player.setVolume(value * 100));
    }
  }

  void _adjustEnd() {
    _adjustTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _adjust = null);
    });
  }

  void _boostStart() {
    if (_locked || !_player.state.playing) return;
    _boostFrom = _rate;
    unawaited(_player.setRate(cinemaLongPressSpeed));
    setState(() {});
  }

  void _boostEnd() {
    final from = _boostFrom;
    if (from == null) return;
    unawaited(_player.setRate(from));
    setState(() => _boostFrom = null);
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _hide?.cancel();
    _flashTimer?.cancel();
    _adjustTimer?.cancel();
    _countdownTimer?.cancel();
    _resumeTimer?.cancel();
    unawaited(ScreenBrightness.instance.resetApplicationScreenBrightness().catchError((Object error, StackTrace stack) => campusLog('[CinemaPlayer] action=brightness_reset errorType=${error.runtimeType}\n$stack')));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final shown = _visible && !_locked;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth, height = constraints.maxHeight;
        return Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _locked ? _show : _toggle,
              onDoubleTap: _locked ? null : _playOrPause,
              onLongPressStart: _locked ? null : (_) => _boostStart(),
              onLongPressEnd: _locked ? null : (_) => _boostEnd(),
              onHorizontalDragStart: _locked ? null : _seekStart,
              onHorizontalDragUpdate: _locked ? null : (details) => _seekUpdate(details, width),
              onHorizontalDragEnd: _locked ? null : (_) => _seekEnd(),
              onHorizontalDragCancel: _locked ? null : () => setState(() => _seekFrom = _seekTo = null),
              onVerticalDragStart: _locked ? null : (details) => _adjustStart(details, width),
              onVerticalDragUpdate: _locked ? null : (details) => _adjustUpdate(details, height),
              onVerticalDragEnd: _locked ? null : (_) => _adjustEnd(),
              onVerticalDragCancel: _locked ? null : _adjustEnd,
            ),
            // 画面底色是黑的（片子的底，不跟配色），加载动画与文字用白色。
            if (widget.busy && widget.error == null)
              IgnorePointer(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CampusLoader(curve: CampusCurve.infinity, size: 44, color: Colors.white),
                      if (widget.hint case final hint?) ...[const SizedBox(height: CampusGap.small), Text(hint, style: text.bodyMedium?.copyWith(color: Colors.white70))],
                    ],
                  ),
                ),
              ),
            if (widget.error case final error?) Center(child: _MessageCard(message: error, action: widget.reloadLabel, onAction: widget.onReload)),
            if (_flash case final icon?) IgnorePointer(child: Center(child: _Bubble(child: CampusIcon(icon, color: Colors.white, size: 36)))),
            if (_seekTo case final to?)
              IgnorePointer(
                child: Center(
                  child: _Bubble(
                    child: Text(
                      '${formatCinemaDuration(to)} / ${formatCinemaDuration(_player.state.duration)}\n${to >= _seekFrom! ? '+' : '-'}${(to - _seekFrom!).abs().inSeconds} 秒',
                      textAlign: TextAlign.center,
                      style: text.titleMedium?.copyWith(color: Colors.white),
                    ),
                  ),
                ),
              ),
            if (_boostFrom != null)
              IgnorePointer(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(top: CampusGap.section),
                    child: _Bubble(
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const CampusIcon(CampusIcons.skipIntro, color: Colors.white),
                        const SizedBox(width: CampusGap.tight),
                        Text('倍速播放中 ${cinemaSpeedLabel(cinemaLongPressSpeed)}', style: text.bodyMedium?.copyWith(color: Colors.white)),
                      ]),
                    ),
                  ),
                ),
              ),
            if (_adjust case final adjust?) IgnorePointer(child: Center(child: _AdjustHud(adjust: adjust, value: _adjustValue))),
            _fade(shown, Align(alignment: Alignment.topCenter, child: _topBar(context))),
            _fade(shown, Align(alignment: Alignment.bottomCenter, child: _bottomBar(context))),
            if (widget.fullscreen && (_visible || _locked))
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: CampusGap.section),
                  child: _RoundButton(
                    icon: _locked ? CampusIcons.lock : CampusIcons.unlock,
                    tooltip: _locked ? '解锁' : '锁定',
                    onPressed: () {
                      setState(() => _locked = !_locked);
                      _scheduleHide();
                    },
                  ),
                ),
              ),
            if (shown && _player.state.position < const Duration(minutes: 5) && _player.state.duration > const Duration(minutes: 10) && !widget.busy)
              Positioned(
                right: CampusGap.large,
                bottom: widget.fullscreen ? 104 : 56,
                child: _PillButton(icon: CampusIcons.skipIntro, label: '跳过片头', onPressed: () => unawaited(_player.seek(_player.state.position + cinemaSkipIntro))),
              ),
            if (_resumeShown && !_locked)
              Positioned(
                left: CampusGap.large,
                bottom: widget.fullscreen ? 104 : 56,
                child: _PillButton(
                  icon: CampusIcons.undo,
                  label: '已从 ${formatCinemaDuration(widget.resumedFrom!)} 继续 · 从头播放',
                  onPressed: () {
                    unawaited(_player.seek(Duration.zero));
                    setState(() => _resumeShown = false);
                  },
                ),
              ),
            if (_countdown case final seconds?)
              Center(
                child: _MessageCard(
                  message: '$seconds 秒后播放下一集',
                  action: '立即播放',
                  actionIcon: CampusIcons.skipNext,
                  onAction: () {
                    _cancelCountdown();
                    widget.onNext?.call();
                  },
                  secondary: '取消',
                  onSecondary: _cancelCountdown,
                ),
              ),
            if (_panel case final panel?) ...[
              GestureDetector(behavior: HitTestBehavior.opaque, onTap: _closePanel),
              Align(alignment: Alignment.centerRight, child: _panelView(context, panel, width)),
            ],
          ],
        );
      },
    );
  }

  Widget _fade(bool shown, Widget child) => IgnorePointer(ignoring: !shown, child: AnimatedOpacity(opacity: shown ? 1 : 0, duration: const Duration(milliseconds: 200), child: child));

  Widget _topBar(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black54, Colors.transparent])),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(CampusGap.tight, CampusGap.tight, CampusGap.small, CampusGap.section),
          child: Row(
            children: [
              IconButton(tooltip: widget.fullscreen ? '退出全屏' : '返回', onPressed: widget.onBack, icon: const CampusIcon(CampusIcons.back, color: Colors.white)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleMedium?.copyWith(color: Colors.white)),
                    if (widget.subtitle.isNotEmpty) Text(widget.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium?.copyWith(color: Colors.white70)),
                  ],
                ),
              ),
              _PillButton(icon: CampusIcons.speed, label: _rate == 1 ? '倍速' : cinemaSpeedLabel(_rate), onPressed: () => _openPanel(_Panel.speed)),
              IconButton(tooltip: '画面比例', onPressed: () => _openPanel(_Panel.fit), icon: const CampusIcon(CampusIcons.aspectRatio, color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    final playing = StreamBuilder<bool>(
      stream: _player.stream.playing,
      initialData: _player.state.playing,
      builder: (context, snapshot) => IconButton(
        tooltip: snapshot.data == true ? '暂停' : '播放',
        onPressed: _playOrPause,
        icon: CampusIcon(snapshot.data == true ? CampusIcons.pause : CampusIcons.resume, color: Colors.white),
      ),
    );
    final next = widget.onNext == null ? null : IconButton(tooltip: '下一集', onPressed: widget.onNext, icon: const CampusIcon(CampusIcons.skipNext, color: Colors.white));
    final fullscreen = IconButton(
      tooltip: widget.fullscreen ? '退出全屏' : '全屏',
      onPressed: widget.onFullscreen,
      icon: CampusIcon(widget.fullscreen ? CampusIcons.exitFullscreen : CampusIcons.fullscreen, color: Colors.white),
    );
    final progress = _CinemaProgress(player: _player, onSeekStart: () => _hide?.cancel(), onSeekEnd: _scheduleHide);
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black54, Colors.transparent])),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(CampusGap.tight, CampusGap.section, CampusGap.tight, CampusGap.tight),
          child: widget.fullscreen
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(padding: const EdgeInsets.symmetric(horizontal: CampusGap.medium), child: progress),
                    Row(
                      children: [
                        playing,
                        ?next,
                        const Spacer(),
                        if (widget.episodes.length > 1) _PillButton(icon: CampusIcons.episodes, label: '选集', onPressed: () => _openPanel(_Panel.episodes)),
                        fullscreen,
                      ],
                    ),
                  ],
                )
              : Row(children: [playing, ?next, Expanded(child: progress), fullscreen]),
        ),
      ),
    );
  }

  Widget _panelView(BuildContext context, _Panel panel, double width) {
    final text = Theme.of(context).textTheme;
    final accent = CampusPalette.of(context).accent;
    final (String title, List<(String, bool, VoidCallback)> items) = switch (panel) {
      _Panel.speed => (
        '倍速',
        [
          for (final speed in cinemaSpeeds)
            (cinemaSpeedLabel(speed), _rate == speed, () {
              _rate = speed;
              unawaited(_player.setRate(speed));
              _closePanel();
            }),
        ],
      ),
      _Panel.fit => (
        '画面比例',
        [
          for (final fit in CinemaFit.values)
            (fit.label, widget.fit == fit, () {
              widget.onFit(fit);
              _closePanel();
            }),
        ],
      ),
      _Panel.episodes => (
        '选集',
        [
          for (final (index, name) in widget.episodes.indexed)
            (name, widget.episode == index, () {
              _closePanel();
              widget.onEpisode?.call(index);
            }),
        ],
      ),
    };
    return Container(
      width: (width * 0.7).clamp(0, 320).toDouble(),
      color: Colors.black87,
      child: SafeArea(
        left: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(CampusGap.large, CampusGap.large, CampusGap.large, CampusGap.small), child: Text(title, style: text.titleMedium?.copyWith(color: Colors.white))),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: CampusGap.large),
                children: [
                  for (final (label, selected, onTap) in items)
                    TextButton(
                      style: TextButton.styleFrom(
                        alignment: Alignment.centerLeft,
                        foregroundColor: selected ? accent : Colors.white,
                        // 列表行不要主题的胶囊底（主题经 backgroundBuilder 画，单设底色盖不住）。
                        backgroundBuilder: (context, states, child) => ColoredBox(color: states.contains(WidgetState.pressed) ? Colors.white12 : Colors.transparent, child: child),
                        shape: const RoundedRectangleBorder(),
                        padding: const EdgeInsets.symmetric(horizontal: CampusGap.large, vertical: CampusGap.medium),
                      ),
                      onPressed: onTap,
                      child: Row(
                        children: [
                          Expanded(child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodyLarge?.copyWith(color: selected ? accent : Colors.white))),
                          if (selected) CampusIcon(CampusIcons.check, color: accent, size: CampusFontSize.body),
                        ],
                      ),
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

// 进度：已播的一段用激活色、已缓冲的一段淡白、其余更淡；按住拖动只预览，松手才跳；两边写时刻。
class _CinemaProgress extends StatefulWidget {
  const _CinemaProgress({required this.player, required this.onSeekStart, required this.onSeekEnd});
  final Player player;
  final VoidCallback onSeekStart;
  final VoidCallback onSeekEnd;
  @override
  State<_CinemaProgress> createState() => _CinemaProgressState();
}

class _CinemaProgressState extends State<_CinemaProgress> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final accent = CampusPalette.of(context).accent;
    final text = Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white, fontFeatures: const [FontFeature.tabularFigures()]);
    final player = widget.player;
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, snapshot) {
        final duration = player.state.duration;
        final total = duration.inMilliseconds;
        final played = total == 0 ? 0.0 : ((snapshot.data ?? Duration.zero).inMilliseconds / total).clamp(0.0, 1.0);
        final buffered = total == 0 ? 0.0 : (player.state.buffer.inMilliseconds / total).clamp(0.0, 1.0);
        final value = _dragging ?? played;
        Duration at(double fraction) => Duration(milliseconds: (fraction * total).round());
        return Row(
          children: [
            Text(formatCinemaDuration(at(value)), style: text),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  double fractionOf(double dx) => (dx / constraints.maxWidth).clamp(0.0, 1.0);
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: total == 0 ? null : (details) => unawaited(player.seek(at(fractionOf(details.localPosition.dx)))),
                    onHorizontalDragStart: total == 0
                        ? null
                        : (details) {
                            widget.onSeekStart();
                            setState(() => _dragging = fractionOf(details.localPosition.dx));
                          },
                    onHorizontalDragUpdate: total == 0 ? null : (details) => setState(() => _dragging = fractionOf(details.localPosition.dx)),
                    onHorizontalDragEnd: total == 0
                        ? null
                        : (_) {
                            final target = _dragging;
                            setState(() => _dragging = null);
                            if (target != null) unawaited(player.seek(at(target)));
                            widget.onSeekEnd();
                          },
                    child: SizedBox(
                      height: 44,
                      child: CustomPaint(painter: _ProgressPainter(played: value, buffered: buffered, accent: accent, dragging: _dragging != null)),
                    ),
                  );
                },
              ),
            ),
            Text(formatCinemaDuration(duration), style: text),
          ],
        );
      },
    );
  }
}

class _ProgressPainter extends CustomPainter {
  _ProgressPainter({required this.played, required this.buffered, required this.accent, required this.dragging});
  final double played;
  final double buffered;
  final Color accent;
  final bool dragging;

  @override
  void paint(Canvas canvas, Size size) {
    const inset = 10.0;
    final width = size.width - inset * 2, middle = size.height / 2, thickness = dragging ? 5.0 : 3.0;
    RRect bar(double fraction) => RRect.fromLTRBR(inset, middle - thickness / 2, inset + width * fraction, middle + thickness / 2, Radius.circular(thickness));
    canvas
      ..drawRRect(bar(1), Paint()..color = Colors.white24)
      ..drawRRect(bar(buffered), Paint()..color = Colors.white54)
      ..drawRRect(bar(played), Paint()..color = accent)
      ..drawCircle(Offset(inset + width * played, middle), dragging ? 9 : 7, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_ProgressPainter old) => old.played != played || old.buffered != buffered || old.accent != accent || old.dragging != dragging;
}

class _AdjustHud extends StatelessWidget {
  const _AdjustHud({required this.adjust, required this.value});
  final _Adjust adjust;
  final double value;

  @override
  Widget build(BuildContext context) {
    final accent = CampusPalette.of(context).accent;
    final icon = adjust == _Adjust.brightness ? CampusIcons.brightness : (value == 0 ? CampusIcons.mute : CampusIcons.volume);
    return _Bubble(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CampusIcon(icon, color: Colors.white),
          const SizedBox(width: CampusGap.medium),
          SizedBox(
            width: 120,
            height: 4,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(CampusGap.hairline),
              child: Stack(fit: StackFit.expand, children: [const ColoredBox(color: Colors.white24), FractionallySizedBox(alignment: Alignment.centerLeft, widthFactor: value, child: ColoredBox(color: accent))]),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(CampusGap.medium)),
    child: Padding(padding: const EdgeInsets.symmetric(horizontal: CampusGap.large, vertical: CampusGap.medium), child: child),
  );
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.message, required this.action, this.actionIcon = CampusIcons.sync, this.onAction, this.secondary, this.onSecondary});
  final String message;
  final String action;
  final IconData actionIcon;
  final VoidCallback? onAction;
  final String? secondary;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return _Bubble(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center, style: text.bodyLarge?.copyWith(color: Colors.white)),
          if (onAction != null) ...[
            const SizedBox(height: CampusGap.small),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (secondary case final label?) ...[_PillButton(icon: CampusIcons.close, label: label, onPressed: onSecondary), const SizedBox(width: CampusGap.small)],
                _PillButton(icon: actionIcon, label: action, onPressed: onAction),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.tooltip, required this.onPressed});
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
    child: IconButton(tooltip: tooltip, onPressed: onPressed, icon: CampusIcon(icon, color: Colors.white)),
  );
}

class _PillButton extends StatelessWidget {
  const _PillButton({required this.icon, required this.label, required this.onPressed});
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => TextButton.icon(
    style: TextButton.styleFrom(foregroundColor: Colors.white, backgroundColor: Colors.black54),
    onPressed: onPressed,
    icon: CampusIcon(icon, color: Colors.white, size: CampusFontSize.body),
    label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
  );
}
