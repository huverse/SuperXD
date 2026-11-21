import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/toolbox_image.dart';
import 'package:superxd/toolbox/cinema/cinema_cloud_parse.dart';
import 'package:superxd/toolbox/cinema/cinema_engine.dart';
import 'package:superxd/toolbox/cinema/cinema_episodes.dart';
import 'package:superxd/toolbox/cinema/cinema_http.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_playback_truth.dart';
import 'package:superxd/toolbox/cinema/cinema_player_controls.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';
import 'package:superxd/toolbox/cinema/cinema_service.dart';

// 播放页（播放内核见 cinema_engine.dart：安卓默认系统播放器 ExoPlayer、iOS 默认 mpv，可在「播放内核」里换；控件与手势在 cinema_player_controls.dart，人工决策在那里）：竖屏上面是画面、下面是选集与换源，
// 画面区的高度跟片子的真实比例走（横片按比例、竖片最多占屏高的 cinemaPortraitMaxHeight），不再一律 16:9 留大黑边；
// 全屏在同一页里切（画面与控件经 GlobalKey 挪过去，不重建纹理、不丢锁定与倍速），横片转成真横屏（左右两种横向都行），竖片保持竖屏，
// 退出全屏回到竖屏（应用平时锁竖屏，[人工决策] 在清单的 MainActivity 与 ios/Runner/Info.plist）。
// 首帧常要 10–20 秒（交接实测，腾讯系首屏要缓冲两三个分片），缓冲超过 15 秒才提示可以换源，不早报失败。
// 看片记录（只在找片里看的记，解析的不记）：每 10 秒、换集、离开时记一次看到哪。
// 选集页取到的选集直接带过来（roads），不再请求一次；「重新载入」才强制重取。每次打开记一次这个源能不能播（CinemaService.recordPlayback），
// 一集剩最后 2 分钟时预取下一集（CinemaService.warm）。换集、换源、离开时取消还在等的请求，并把上一路交回本机代理。
// 片源菜单：打开以后又来的源接在末尾；「找其他片源」点了才按片名补搜（人工决策见 CinemaService.findMoreSources）；换源按 cinemaMatchEpisode 找同一集。
class CinemaPlayerPage extends StatefulWidget {
  const CinemaPlayerPage.title({super.key, required this.service, required CinemaTitle this.title, required CinemaSourceRef this.source, required this.road, required this.episode, this.start = Duration.zero, this.roads})
    : parser = null,
      target = null,
      parsed = null;
  const CinemaPlayerPage.parsed({super.key, required this.service, required this.parser, required String this.target, required CinemaParsed this.parsed})
    : title = null,
      source = null,
      road = 0,
      episode = 0,
      start = Duration.zero,
      roads = null;
  final CinemaService service;
  final CinemaTitle? title;
  final CinemaSourceRef? source;
  final int road;
  final int episode;
  final Duration start;
  // 选集页已经取到的这个源的选集（没有就自己取）。
  final List<CinemaRoad>? roads;
  // 云解析的结果（重新载入时用 parser 与 target 重新解析，解出来的地址几分钟就失效）。
  final CinemaParser? parser;
  final String? target;
  final CinemaParsed? parsed;

  @override
  State<CinemaPlayerPage> createState() => _CinemaPlayerPageState();
}

// 竖屏时画面区最多占屏高的这么多（竖片）。
const cinemaPortraitMaxHeight = 0.6;

class _CinemaPlayerPageState extends State<CinemaPlayerPage> {
  // 播放内核（人工决策见 cinema_engine.dart 文件头）：换内核或退回 mpv 时换掉，事件订阅跟着重挂（_attach）。
  late CinemaEngine _engine;
  final _subscriptions = <StreamSubscription<Object?>>[];
  // 系统播放器在这一页退回过 mpv（首帧前打不开），之后不再自动退。
  var _fellBack = false;
  // 这一次打开从哪里开始，与打开中见过的最早位置（首帧要等时钟越过它们，见 cinemaFirstFrame）。
  var _openStart = Duration.zero;
  Duration? _firstSeen;
  late final CinemaSaveSchedule _saves;
  late final AppLifecycleListener _lifecycle;
  // 开发者模式的诊断：这一次卡住缓冲从什么时候开始。
  DateTime? _stalledAt;
  Timer? _slowTimer;
  CinemaSourceRef? _source;
  CinemaRule? _rule;
  List<CinemaRoad>? _roads;
  var _road = 0;
  var _episode = 0;
  // 下面选集里正在看的线路（只是看它有哪些集，点了某一集才换过去播；为空就是正在播的那条）。
  int? _browsing;
  CinemaParsed? _parsed;
  // 正在取选集、解析或打开。
  // 打开后进度还没动（取选集、解析、首屏缓冲），与播放中卡住缓冲（_stalled）：两者有一个就画加载圈，持续 15 秒提示可以换源。
  var _opening = true;
  var _stalled = false;
  var _slow = false;
  String? _error;
  // 只认最近一次打开：换集、换源快速连点时旧的结果不再写界面。
  var _generation = 0;
  var _fullscreen = false;
  var _fit = CinemaFit.automatic;
  // 片子的宽高比（取到画面尺寸之前为空，按 16:9 排）。
  double? _aspect;
  // 从上次的位置接着看（只在进来的第一集），换集换源后为空。
  Duration? _resumedFrom;
  // 画面与控件：全屏与竖屏之间挪动时保留状态。
  final _stageKey = GlobalKey();
  // 这一次打开还在等的请求（换集、换源、离开时取消）与交给播放器的地址（本机代理的一路，换掉时交回）。
  Completer<void>? _cancel;
  CinemaPlayable? _playable;
  // 这一次打开从什么时候算首帧、播放结果记过没有、下一集预取过没有。
  final _openWatch = Stopwatch();
  var _recorded = true;
  var _warmedNext = false;
  // 这一次交给播放器的媒体地址（交出去之前为空）与下一集预取的取消（离开时完成）。
  String? _mediaUri;
  final _warmCancel = Completer<void>();
  // 片源菜单的顺序（按本机播放记录排一次，之后来的源接在末尾，见 _onSources）。
  late List<CinemaSourceRef> _sources = widget.title == null ? const [] : rankCinemaSources(widget.title!.sources, widget.service.knownStats);
  // 「找其他片源」正在搜（按钮原地转圈），离开时不再等。
  var _finding = false;
  final _findCancel = Completer<void>();
  StreamSubscription<void>? _sourceChanges;
  // 换源前那一集的片长（第几次打开的），新的片长出来后比一次（cinemaCutDiffers）。
  (int, Duration)? _cutFrom;
  // 本机记下的这部片的源有几个（片源只增不减，多了才再记，见 _save）。
  var _savedSources = 0;

  bool get _titleMode => widget.title != null;

  @override
  void initState() {
    super.initState();
    _engine = createCinemaEngine(cinemaEngineOf(widget.service.enginePreference));
    _source = widget.source;
    _rule = widget.source == null ? null : widget.service.rule(widget.source!.ruleId);
    _road = widget.road;
    _episode = widget.episode;
    _roads = widget.roads;
    _parsed = widget.parsed;
    _resumedFrom = widget.start > Duration.zero ? widget.start : null;
    // 每 10 秒记一次看到哪；暂停了等 1 秒合并着记，切到后台立即记（之后可能被系统杀掉）。
    _saves = CinemaSaveSchedule(_save);
    _attach();
    _lifecycle = AppLifecycleListener(onHide: () => unawaited(_saves.now()));
    _sourceChanges = widget.title?.changes.listen((_) => _onSources());
    unawaited(_open(start: widget.start));
  }

  // 挂上播放内核的事件（换内核时先 _detach 再挂新的）。
  void _attach() {
    _subscriptions
      ..add(_engine.stream.buffering.listen(_buffering))
      ..add(_engine.stream.width.listen((_) => _measure()))
      ..add(_engine.stream.duration.listen(_compareCut))
      ..add(_engine.stream.height.listen((_) => _measure()))
      ..add(_engine.stream.error.listen((message) {
        campusLog('[CinemaPlayer] action=error id=$_generation engine=${_engine.kind.name} message=${cinemaLogSafe(message)} current=$_currentMedia');
        // 换集、重新载入时上一个视频晚到的错误不算这一次的（见 _currentMedia）。
        if (!_currentMedia) return;
        // 系统播放器首帧前就报错：这一页退回 mpv 再开一次（人工决策见 cinema_engine.dart 文件头）。
        if (_opening && _canFallBack) return unawaited(_fallBack(message));
        _record(ok: false);
        // 出错就结束这一次打开（首帧前出错也一样）：收起加载与缓冲提示、放开换源；还在等的旧请求照旧由 _cancel 取消。
        _slowTimer?.cancel();
        if (mounted) {
          setState(() {
            _error = '播放出错，可以重新载入或换个源';
            _opening = false;
            _slow = false;
          });
        }
      }))
      ..add(_engine.stream.position.listen((position) {
        // 只认这一次交给播放器的媒体：重新载入时旧视频还在播，它的进度不能把这次记成播成、也不能收起加载动画。
        if (!_currentMedia) return;
        if (_opening) {
          final seen = _firstSeen;
          if (seen == null || position < seen) _firstSeen = position;
        }
        if (cinemaFirstFrame(position, start: _openStart, firstSeen: _firstSeen) && mounted && _opening) {
          _record(ok: true);
          if (campusDiagnostics) {
            campusLog('[CinemaPlayer] action=first_frame id=$_generation ms=${_openWatch.elapsedMilliseconds}');
            final generation = _generation;
            unawaited(_engine.describe().then((info) => campusLog('[CinemaPlayer] action=decoder id=$generation $info')).catchError((Object error, StackTrace stack) => campusLog('[CinemaPlayer] action=decoder errorType=${error.runtimeType}\n$stack')));
          }
          setState(() => _opening = false);
          _watchSlow();
        }
        _warmNext(position);
      }))
      ..add(_engine.stream.playing.listen((playing) {
        if (!playing) _saves.soon();
      }));
  }

  void _detach() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  bool get _canFallBack => _engine.kind == CinemaEngineKind.system && !_fellBack;

  // 系统播放器在首帧前打不开：这一页退回 mpv，在同一个位置再开一次（人工决策见 cinema_engine.dart 文件头）。
  Future<void> _fallBack(String reason) async {
    _fellBack = true;
    campusLog('[CinemaPlayer] action=engine_fallback id=$_generation from=system to=mpv reason=${cinemaLogSafe(reason)}');
    await _switchEngine(CinemaEngineKind.mpv, start: _openStart);
  }

  // 换内核：先挂上新的再释放旧的，倍速与音量带过去，在 start 用新的重开。
  Future<void> _switchEngine(CinemaEngineKind kind, {required Duration start}) async {
    final old = _engine, before = old.state;
    _detach();
    setState(() => _engine = createCinemaEngine(kind));
    _attach();
    unawaited(old.dispose().catchError((Object error, StackTrace stack) => campusLog('[CinemaPlayer] action=engine_dispose errorType=${error.runtimeType}\n$stack')));
    await _engine.setRate(before.rate);
    await _engine.setVolume(before.volume);
    await _open(start: start);
  }

  // 「播放内核」里换了：记在本机，立即在当前位置用新内核重开。
  Future<void> _chooseEngine(CinemaEngineKind kind) async {
    if (kind == _engine.kind) return;
    final start = _opening ? _openStart : _engine.state.position;
    unawaited(_saves.now());
    unawaited(widget.service.chooseEngine(kind.name).catchError((Object error, StackTrace stack) => campusLog('[CinemaPlayer] action=choose_engine errorType=${error.runtimeType}\n$stack')));
    _fellBack = false;
    await _switchEngine(kind, start: start);
  }

  // 打开以后又来的源（搜索晚回来的、「找其他片源」补到的）接在片源菜单末尾，已有的顺序与正在播的不动。
  void _onSources() => setState(() => _sources = appendCinemaSources(_sources, widget.title!.sources));

  // 「找其他片源」（人工决策见 CinemaService.findMoreSources）：点了才按片名搜同意过的源，找到的接进片源菜单，由用户自己换。
  Future<void> _findSources() async {
    setState(() => _finding = true);
    try {
      final added = await widget.service.findMoreSources(widget.title!, cancel: _findCancel.future);
      if (mounted) showCampusToast(context, added == 0 ? '没找到其他片源' : '又找到 $added 个片源，在「片源」里换');
    } on CinemaRuleException catch (error) {
      if (mounted) showCampusToast(context, error.message);
    } catch (error, stack) {
      campusLog('[CinemaPlayer] action=find_sources errorType=${error.runtimeType}\n$stack');
      if (mounted) showCampusToast(context, '没找成，稍后再试');
    } finally {
      if (mounted) setState(() => _finding = false);
    }
  }

  // 每次状态变了都对一下播放优先：打开中或卡住缓冲（没出错）时让小网络图先等等（人工决策见 toolbox_image.dart 的 ToolboxImageGate）。
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _syncGate();
  }

  void _syncGate() => (_opening || _stalled) && _error == null ? ToolboxImageGate.hold(this) : ToolboxImageGate.release(this);

  void _measure() {
    final width = _engine.state.width, height = _engine.state.height;
    if (width == null || height == null || width <= 0 || height <= 0 || !mounted) return;
    final aspect = width / height;
    if (aspect != _aspect) setState(() => _aspect = aspect);
  }

  void _buffering(bool buffering) {
    if (campusDiagnostics && _currentMedia) {
      final started = _stalledAt;
      if (buffering) {
        _stalledAt ??= DateTime.now();
      } else if (started != null) {
        _stalledAt = null;
        if (!_opening) campusLog('[CinemaPlayer] action=rebuffer id=$_generation ms=${DateTime.now().difference(started).inMilliseconds}');
      }
    }
    if (!mounted || buffering == _stalled) return;
    setState(() => _stalled = buffering);
    _watchSlow();
  }

  // 在等（打开中或卡住缓冲）就开始计 15 秒，不等了就收起提示。
  void _watchSlow() {
    _slowTimer?.cancel();
    if (!_opening && !_stalled) {
      if (_slow) setState(() => _slow = false);
      return;
    }
    _slowTimer = Timer(const Duration(seconds: 15), () {
      if (mounted) setState(() => _slow = true);
    });
  }

  // 播放器当前这一项是不是这一次交出去的媒体（事件不带是哪个媒体的，按播放列表的当前项对）。
  bool get _currentMedia {
    final uri = _mediaUri;
    return uri != null && _engine.currentUri == uri;
  }

  // 记一次这个源能不能播（只在找片里、每次打开只记一次）：出了首帧算播成，带首帧用时。
  void _record({required bool ok}) {
    final rule = _rule;
    if (_recorded || rule == null || !_titleMode) return;
    _recorded = true;
    unawaited(widget.service.recordPlayback(rule.id, ok: ok, firstFrame: ok ? _openWatch.elapsed : null).catchError((Object error, StackTrace stack) => campusLog('[CinemaPlayer] action=record errorType=${error.runtimeType}\n$stack')));
  }

  // 换集、换源、离开时：等了 15 秒还没出首帧的算这个源没播成。
  void _abandon() {
    if (_opening && _slow) _record(ok: false);
  }

  // 一集剩最后 2 分钟时预取下一集（人工决策见 cinema_service.dart 的 warm）；打开中或卡住缓冲时先不取（播放优先，播顺了下一次进度再取）。
  void _warmNext(Duration position) {
    final roads = _roads, duration = _engine.state.duration;
    if (_warmedNext || !_titleMode || !_hasNext || roads == null || _opening || _stalled || duration <= Duration.zero || duration - position > const Duration(minutes: 2)) return;
    _warmedNext = true;
    unawaited(widget.service.warm(roads[_road].episodes[_episode + 1].url, rule: _rule, cancel: _warmCancel.future));
  }

  CinemaEpisode? get _current {
    final roads = _roads;
    if (roads == null || _road >= roads.length || _episode >= roads[_road].episodes.length) return null;
    return roads[_road].episodes[_episode];
  }

  Future<void> _open({Duration start = Duration.zero, bool fresh = false}) async {
    final generation = ++_generation;
    // 换了媒体：上一个视频还在等的跳转不再算（媒体归属）。
    _engine.resetSeeks();
    _openStart = start;
    _firstSeen = null;
    _cancel?.complete();
    final cancel = _cancel = Completer<void>();
    _openWatch
      ..reset()
      ..start();
    _recorded = false;
    _warmedNext = false;
    _mediaUri = null;
    setState(() {
      _opening = true;
      _slow = false;
      _error = null;
    });
    _watchSlow();
    // 交给了内核却没打开成的这一路（系统播放器打不开时先交回再退回 mpv）。
    CinemaPlayable? opened;
    try {
      final CinemaPlayable playable;
      if (_titleMode) {
        final rule = _rule;
        if (rule == null) throw const CinemaRuleException('这个源已经下架，换一个源试试');
        final roads = _roads = fresh || _roads == null ? await widget.service.chapters(rule, _source!.source, fresh: fresh, cancel: cancel.future, carried: _source!.carried) : _roads!;
        if (generation != _generation) return;
        _road = _road.clamp(0, roads.length - 1);
        _episode = _episode.clamp(0, roads[_road].episodes.length - 1);
        _browsing = null;
        playable = await widget.service.playable(roads[_road].episodes[_episode].url, rule: rule, fresh: fresh, cancel: cancel.future);
      } else {
        final parser = widget.parser;
        final parsed = _parsed = fresh && parser != null ? await widget.service.cloud.parse(parser, widget.target!, fresh: true) : _parsed!;
        playable = await widget.service.playable(parsed.url, playlist: parsed.type == 'm3u8', fresh: fresh, cancel: cancel.future);
      }
      if (generation != _generation || !mounted) {
        widget.service.release(playable);
        return;
      }
      if (campusDiagnostics) {
        // 一次打开一条（id 是这一页里的第几次打开，stream 对得上本机代理的日志）；不记地址与片名。
        campusLog('[CinemaPlayer] action=open id=$generation engine=${_engine.kind.name} rule=${_rule?.id ?? 'parse'} road=$_road episode=$_episode startMs=${start.inMilliseconds} fresh=$fresh stream=${playable.uri.queryParameters['s'] ?? '-'} ms=${_openWatch.elapsedMilliseconds}');
      }
      opened = playable;
      final uri = _mediaUri = playable.uri.toString();
      await _engine.open(uri, playable.headers, start: start, playlist: playable.playlist);
      // 播放器换上新的之后再交回上一路（先交回的话旧的那一路会报错、误记到这一次）。
      final previous = _playable;
      _playable = playable;
      if (previous != null) widget.service.release(previous);
      if (mounted) setState(() {});
    } on http.RequestAbortedException {
      return;
    } on CinemaRuleException catch (error) {
      if (generation == _generation) _record(ok: false);
      if (mounted && generation == _generation) setState(() => _error = error.message);
    } on CinemaHttpException catch (error) {
      if (generation == _generation) _record(ok: false);
      if (mounted && generation == _generation) setState(() => _error = '这个源${error.message}，换一个源试试');
    } on CinemaParseException catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.message);
    } on CinemaEngineException catch (error) {
      if (opened != null) widget.service.release(opened);
      // 首帧前的报错事件已经让这一页退回了 mpv（见 _attach 的 error）：这是旧内核晚到的异常，不再报错。
      if (!mounted || generation != _generation || _engine.kind != CinemaEngineKind.system) return;
      if (_canFallBack) return _fallBack(error.message);
      _record(ok: false);
      setState(() => _error = '播放出错，可以重新载入或换个源');
    } catch (error, stack) {
      campusLog('[CinemaPlayer] action=open errorType=${error.runtimeType}\n$stack');
      if (generation == _generation) _record(ok: false);
      if (mounted && generation == _generation) setState(() => _error = '没能打开，可以重新载入或换个源');
    } finally {
      if (mounted && generation == _generation && _error != null) setState(() => _opening = false);
    }
  }

  // 记下看到哪（只在找片里）；出错只记日志，不打扰播放。进度还没动（打开中、没打开成、出错了）时不记，免得接着看的位置被 0 盖掉。
  Future<void> _save() async {
    final title = widget.title, source = _source, episode = _current;
    if (title == null || source == null || episode == null || _opening || _error != null) return;
    final state = _engine.state;
    try {
      await widget.service.store.saveHistory(CinemaHistory(
        key: title.key,
        name: title.name,
        cover: title.cover,
        ruleId: source.ruleId,
        source: source.source,
        road: _road,
        episode: _episode,
        episodeName: episode.name,
        position: state.position,
        duration: state.duration,
        updatedAt: DateTime.now().toUtc(),
      ));
      // 这部片的各个源也记下（人工决策见 cinema_page.dart 的 _resume）：下次从「看过的」接着看，源坏了直接换，不用再搜。
      final sources = title.sources;
      if (sources.length != _savedSources) {
        await widget.service.store.saveTitleSources(title.key, sources);
        _savedSources = sources.length;
      }
    } catch (error, stack) {
      campusLog('[CinemaPlayer] action=save errorType=${error.runtimeType}\n$stack');
    }
  }

  // 换源后新的片长出来了：和换源前差得多就提示可能是别的剪辑版本（人工决策见 cinemaCutDiffers）。
  void _compareCut(Duration duration) {
    final from = _cutFrom;
    if (from == null || from.$1 != _generation || !_currentMedia || duration <= Duration.zero || !mounted) return;
    _cutFrom = null;
    final diff = cinemaCutDiffers(from.$2, duration);
    if (diff == null) return;
    showCampusToast(context, '这个源比原来${diff.isNegative ? '短' : '长'} ${diff.abs().inMinutes} 分钟，可能是别的剪辑，进度不一定对得上');
  }

  // 发出跳转（命令交给播放器之前，见 CinemaPlayerControls.onSeek）：等 1 秒合并着记看到哪。开发者模式下等跳转回报（见 cinema_playback_truth.dart）
  // 再记目标、发出时在不在缓存里（true、false、unknown）、原生恢复与目标处走起来各用了多久、结果与落点；连着跳只记最后一次（前面的记 superseded）。
  // 11-21 Codex 总交接第 12.5 节：原来 await seek 之后 1 秒读位置，seek 0–1 毫秒就返回、位置立刻报成目标，记到的是目标本身、不是恢复时间。
  void _seeked(Duration target) {
    _saves.soon();
    // 打开中（还没出首帧）就跳：两个内核在媒体还没就绪时都可能吞掉跳转（11-21 真机：续播打开中点「从头播放」，mpv 那次等满 20 秒没动），
    // 改成在目标位置重开；首帧也就按新的起点算（原来 ExoPlayer 跳回片头后一直等原来起点的首帧，转圈不停、菜单一直不能点）。
    if (_opening && _error == null) {
      if (campusDiagnostics) campusLog('[CinemaPlayer] action=seek_while_opening id=$_generation engine=${_engine.kind.name} targetMs=${target.inMilliseconds}');
      unawaited(_open(start: target));
      return;
    }
    if (!campusDiagnostics) return;
    final generation = _generation;
    unawaited(_engine.beginSeek(target).then((seek) {
      if (mounted && generation == _generation) {
        campusLog('[CinemaPlayer] action=seek id=$generation engine=${_engine.kind.name} seek=${seek.id} targetMs=${target.inMilliseconds} cached=${seek.cached ?? 'unknown'} result=${seek.result} restartMs=${seek.restartMs ?? '-'} playingMs=${seek.playingMs ?? '-'} landedMs=${_engine.state.position.inMilliseconds}');
      }
    }));
  }

  Future<void> _pickEpisode(int road, int episode) async {
    if (road == _road && episode == _episode && _error == null) return;
    _abandon();
    await _saves.now();
    _road = road;
    _episode = episode;
    _resumedFrom = null;
    await _open();
  }

  bool get _hasNext {
    final roads = _roads;
    return roads != null && _road < roads.length && _episode + 1 < roads[_road].episodes.length;
  }

  // 换源：在新源里找同一集（cinemaMatchEpisode：原名、集号、两边都只有一集；先找同序号的线路，再找全部线路），找不到就留在原来的源。
  // 原来的源一直没取到选集（如续播时源已下架）时按第几集找，从记下的位置接着看。
  Future<void> _pickSource(CinemaSourceRef source) async {
    final rule = widget.service.rule(source.ruleId);
    final name = _current?.name;
    final single = _roads != null && _road < _roads!.length && _roads![_road].episodes.length == 1;
    if (rule == null) {
      showCampusToast(context, '这个源已经下架');
      return;
    }
    _cancel?.complete();
    final cancel = _cancel = Completer<void>();
    // 没换成时还原：原来出错的仍显示出错（能重新载入），不留一块既不转圈也不报错的黑屏。
    final previousError = _error;
    void stay() => setState(() {
      _opening = false;
      _error = previousError;
    });
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final roads = await widget.service.chapters(rule, source.source, cancel: cancel.future, carried: source.carried);
      final order = [if (_road < roads.length) _road, for (var index = 0; index < roads.length; index++) if (index != _road) index];
      for (final road in order) {
        final episode = cinemaMatchEpisode(roads[road].episodes, name, index: _episode, single: single);
        if (episode < 0) continue;
        _abandon();
        await _saves.now();
        if (!mounted) return;
        final position = _engine.state.position;
        final start = position > Duration.zero ? position : (_resumedFrom ?? Duration.zero);
        final before = _engine.state.duration;
        _source = source;
        _rule = rule;
        _roads = roads;
        _road = road;
        _episode = episode;
        _resumedFrom = null;
        // 先登记再打开（_open 用下一个序号）：新片长的事件可能在打开返回之前就到。
        _cutFrom = before > Duration.zero ? (_generation + 1, before) : null;
        await _open(start: start);
        return;
      }
      if (mounted) {
        stay();
        showCampusToast(context, name == null ? '这个源没有这一集' : '这个源没有「$name」');
      }
    } on CinemaRuleException catch (error) {
      if (mounted) {
        stay();
        showCampusToast(context, error.message);
      }
    } on CinemaHttpException catch (error) {
      if (mounted) {
        stay();
        showCampusToast(context, '这个源${error.message}');
      }
    } on http.RequestAbortedException {
      return;
    }
  }

  // 进出全屏：横片转真横屏（左右两种都行），竖片与比例未知时按横片；退出回到竖屏并恢复系统栏。
  Future<void> _setFullscreen(bool on) async {
    if (on == _fullscreen) return;
    setState(() => _fullscreen = on);
    try {
      await _applyOrientation(on: on, landscape: (_aspect ?? 16 / 9) >= 1);
    } catch (error, stack) {
      campusLog('[CinemaPlayer] action=fullscreen errorType=${error.runtimeType}\n$stack');
    }
  }

  static Future<void> _applyOrientation({required bool on, required bool landscape}) async {
    await SystemChrome.setEnabledSystemUIMode(on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(on && landscape ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight] : const [DeviceOrientation.portraitUp]);
  }

  @override
  void dispose() {
    ToolboxImageGate.release(this);
    unawaited(_sourceChanges?.cancel());
    _findCancel.complete();
    _abandon();
    _generation++;
    _cancel?.complete();
    _warmCancel.complete();
    if (_playable case final playable?) widget.service.release(playable);
    if (_fullscreen) {
      unawaited(_applyOrientation(on: false, landscape: false).catchError((Object error, StackTrace stack) => campusLog('[CinemaPlayer] action=fullscreen_exit errorType=${error.runtimeType}\n$stack')));
    }
    _saves.dispose();
    _lifecycle.dispose();
    _slowTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_save().whenComplete(() => _engine.dispose()).catchError((Object error, StackTrace stack) => campusLog('[CinemaPlayer] action=dispose errorType=${error.runtimeType}\n$stack')));
    super.dispose();
  }

  // 画面与控件（竖屏与全屏共用一份）。
  Widget _stage(String heading) {
    final roads = _roads;
    final episodes = roads == null || _road >= roads.length ? const <CinemaEpisode>[] : roads[_road].episodes;
    return KeyedSubtree(
      key: _stageKey,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _engine.view(fit: _fit.fit, ratio: _fit.ratio),
            CinemaPlayerControls(
              // 换了内核就换一份控件状态（订阅跟着新内核）；倍速与音量由 _switchEngine 带过去。
              key: ObjectKey(_engine),
              player: _engine,
              title: heading,
              subtitle: _titleMode ? (_current?.name ?? '') : '',
              fullscreen: _fullscreen,
              busy: (_opening || _stalled) && _error == null,
              error: _error,
              hint: _slow ? '还在缓冲，可以换个源试试' : null,
              onReload: () => unawaited(_open(start: _engine.state.position, fresh: true)),
              reloadLabel: _titleMode ? '重新载入' : '重新解析',
              fit: _fit,
              onFit: (fit) => setState(() => _fit = fit),
              onBack: _fullscreen ? () => unawaited(_setFullscreen(false)) : () => Navigator.maybePop(context),
              onFullscreen: () => unawaited(_setFullscreen(!_fullscreen)),
              onNext: _hasNext ? () => unawaited(_pickEpisode(_road, _episode + 1)) : null,
              episodes: [for (final episode in episodes) episode.name],
              episode: _episode,
              onEpisode: (index) => unawaited(_pickEpisode(_road, index)),
              resumedFrom: _resumedFrom,
              onSeek: _seeked,
              seekable: _engine.seekable,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    final heading = title?.name ?? (_parsed?.title.isNotEmpty == true ? _parsed!.title : '解析播放');
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_setFullscreen(false));
      },
      child: _fullscreen
          ? Scaffold(backgroundColor: Colors.black, body: _stage(heading))
          : AnnotatedRegion<SystemUiOverlayStyle>(
              // 画面区在最上面、底是黑的：状态栏用浅色图标。
              value: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent),
              child: Scaffold(
                body: Column(
                  children: [
                    ColoredBox(
                      color: Colors.black,
                      child: SafeArea(
                        bottom: false,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            // 退出全屏的那一帧可能还是横屏尺寸：下限不超过上限。
                            final width = constraints.maxWidth, most = MediaQuery.sizeOf(context).height * cinemaPortraitMaxHeight;
                            final height = (width / (_aspect ?? 16 / 9)).clamp(min(width * 9 / 21, most), most).toDouble();
                            return AnimatedContainer(duration: const Duration(milliseconds: 240), curve: Curves.easeOutCubic, height: height, child: _stage(heading));
                          },
                        ),
                      ),
                    ),
                    Expanded(child: _details(context, heading)),
                  ],
                ),
              ),
            ),
    );
  }

  // 画面下面：片名与这一集、重新载入、片源、线路与选集。
  Widget _details(BuildContext context, String heading) {
    final palette = CampusPalette.of(context);
    final text = Theme.of(context).textTheme;
    final title = widget.title;
    final roads = _roads;
    final subtitle = _titleMode ? (_current?.name ?? '') : '';
    final browsing = roads == null ? 0 : (_browsing ?? _road).clamp(0, roads.length - 1);
    return CampusScrollFade(
      child: ListView(
        padding: const EdgeInsets.all(CampusGap.large),
        children: [
          Text(heading, style: text.titleMedium),
          if (subtitle.isNotEmpty) Text(subtitle, style: text.bodyMedium?.copyWith(color: palette.onSurfaceVariant)),
          const SizedBox(height: CampusGap.medium),
          Wrap(
            spacing: CampusGap.small,
            runSpacing: CampusGap.small,
            children: [
              OutlinedButton.icon(
                onPressed: () => unawaited(_open(start: _engine.state.position, fresh: true)),
                icon: const CampusIcon(CampusIcons.sync),
                label: Text(_titleMode ? '重新载入' : '重新解析'),
              ),
              if (title != null)
                OutlinedButton(
                  onPressed: _finding ? null : () => unawaited(_findSources()),
                  child: CampusBusyContent(busy: _finding, label: '找其他片源', busyLabel: '正在找', icon: const CampusIcon(CampusIcons.search)),
                ),
            ],
          ),
          if (title != null && _sources.length > 1) ...[
            const SizedBox(height: CampusGap.large),
            CampusSurface(
              padding: EdgeInsets.fromLTRB(CampusGap.large, campusFieldGap(context), CampusGap.large, CampusGap.large),
              child: CampusMenuField<CinemaSourceRef>(
                label: '片源',
                value: _source!,
                items: [
                  for (final ref in _sources) CampusMenuItem(value: ref, label: cinemaSourceLabel(widget.service, ref)),
                ],
                onChanged: _opening ? null : (ref) => unawaited(_pickSource(ref)),
              ),
            ),
          ],
          const SizedBox(height: CampusGap.large),
          // 播放内核（人工决策见 cinema_engine.dart 文件头）：显示正在用的（退回过 mpv 时就是 mpv），换了记在本机。
          CampusSurface(
            padding: EdgeInsets.fromLTRB(CampusGap.large, campusFieldGap(context), CampusGap.large, CampusGap.large),
            child: CampusMenuField<CinemaEngineKind>(
              label: '播放内核',
              value: _engine.kind,
              items: [
                for (final kind in CinemaEngineKind.values) CampusMenuItem(value: kind, label: kind == cinemaDefaultEngine ? '${kind.label}（推荐）' : kind.label),
              ],
              onChanged: _opening ? null : (kind) => unawaited(_chooseEngine(kind)),
            ),
          ),
          if (roads != null) ...[
            const SizedBox(height: CampusGap.large),
            if (roads.length > 1 && roads.length <= 3) ...[
              CampusSegmented<int>(
                values: [for (var index = 0; index < roads.length; index++) index],
                label: (index) => roads[index].name,
                selected: browsing,
                onSelected: (index) => setState(() => _browsing = index),
              ),
              const SizedBox(height: CampusGap.medium),
            ],
            CinemaEpisodeGrid(
              episodes: roads[browsing].episodes,
              selected: browsing == _road ? _episode : null,
              onPick: (index) => unawaited(_pickEpisode(browsing, index)),
            ),
          ],
        ],
      ),
    );
  }
}

// 播放器报错的原话进日志前去掉网址（11-21 模拟器上看到 mpv 的原话里有本机代理的口令与上游的完整地址，签名地址会原样进日志）：
// 网址一律换成「<地址>」，主机名留着（解析不了域名时有用），截到 120 字。
String cinemaLogSafe(String message) {
  final text = message.replaceAll(RegExp(r'[a-z][a-z0-9+.-]*://\S+', caseSensitive: false), '<地址>');
  return text.length > 120 ? text.substring(0, 120) : text;
}

// 首帧（11-21 真机诊断发现）：从中途打开时播放器在出画之前就把位置报成起点（原来「位置大于零」把这一刻当首帧，从「看过的」打开记的 2.8 秒并不是真出画）。
// 从头开的照旧看位置动了；从中途开的要等时钟越过起点 playingLead，或越过打开中见过的最早位置 firstSeen（落点比起点早、或打开中跳回了片头，
// 11-21 真机：ExoPlayer 续播到 38 分时点了从头播放，只看起点就永远等不到，转圈不停）。
bool cinemaFirstFrame(Duration position, {required Duration start, required Duration? firstSeen}) {
  if (start <= Duration.zero) return position > Duration.zero;
  const lead = CinemaPlaybackTruth.playingLead;
  return position >= start + lead || (firstSeen != null && position >= firstSeen + lead);
}

// 记看到哪的时机（11-21 Codex 总交接第 6.6 节，用户说按最佳实践做；同主流视频 App 的进度保存）：播放中每 periodic 记一次；
// 暂停、跳转做完时等 settle 再记（连着拖几下只记最后一次）；切到后台、换集换源、离开时立即记（now）。被强杀时，最近一次暂停或跳转已经落库。
class CinemaSaveSchedule {
  CinemaSaveSchedule(this._save, {this.periodic = const Duration(seconds: 10), this.settle = const Duration(seconds: 1)}) {
    _timer = Timer.periodic(periodic, (_) => unawaited(_save()));
  }
  final Future<void> Function() _save;
  final Duration periodic;
  final Duration settle;
  late final Timer _timer;
  Timer? _pending;

  void soon() {
    _pending?.cancel();
    _pending = Timer(settle, () {
      _pending = null;
      unawaited(_save());
    });
  }

  Future<void> now() {
    _pending?.cancel();
    _pending = null;
    return _save();
  }

  void dispose() {
    _timer.cancel();
    _pending?.cancel();
  }
}
