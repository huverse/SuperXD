import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/cinema/cinema_cloud_parse.dart';
import 'package:superxd/toolbox/cinema/cinema_http.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_player_controls.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';
import 'package:superxd/toolbox/cinema/cinema_service.dart';

// 播放页（media_kit，libmpv；控件与手势在 cinema_player_controls.dart，人工决策在那里）：竖屏上面是画面、下面是选集与换源，
// 画面区的高度跟片子的真实比例走（横片按比例、竖片最多占屏高的 cinemaPortraitMaxHeight），不再一律 16:9 留大黑边；
// 全屏在同一页里切（画面与控件经 GlobalKey 挪过去，不重建纹理、不丢锁定与倍速），横片转成真横屏（左右两种横向都行），竖片保持竖屏，
// 退出全屏回到竖屏（应用平时锁竖屏，[人工决策] 在清单的 MainActivity 与 ios/Runner/Info.plist）。
// 首帧常要 10–20 秒（交接实测，腾讯系首屏要缓冲两三个分片），缓冲超过 15 秒才提示可以换源，不早报失败。
// 看片记录（只在找片里看的记，解析的不记）：每 10 秒、换集、离开时记一次看到哪。
// 选集页取到的选集直接带过来（roads），不再请求一次；「重新载入」才强制重取。每次打开记一次这个源能不能播（CinemaService.recordPlayback），
// 一集剩最后 2 分钟时预取下一集（CinemaService.warm）。换集、换源、离开时取消还在等的请求，并把上一路交回本机代理。
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

// libmpv 每个进程只要初始化一次。
var _mediaKitReady = false;

// 竖屏时画面区最多占屏高的这么多（竖片）。
const cinemaPortraitMaxHeight = 0.6;

class _CinemaPlayerPageState extends State<CinemaPlayerPage> {
  late final Player _player;
  late final VideoController _video;
  final _subscriptions = <StreamSubscription<Object?>>[];
  Timer? _saveTimer;
  Timer? _slowTimer;
  CinemaSourceRef? _source;
  CinemaRule? _rule;
  List<CinemaRoad>? _roads;
  var _road = 0;
  var _episode = 0;
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
  // 片源菜单的顺序（按本机播放记录排一次）。
  late final List<CinemaSourceRef> _sources = widget.title == null ? const [] : rankCinemaSources(widget.title!.sources, widget.service.knownStats);

  bool get _titleMode => widget.title != null;

  @override
  void initState() {
    super.initState();
    if (!_mediaKitReady) {
      MediaKit.ensureInitialized();
      _mediaKitReady = true;
    }
    _player = Player();
    _video = VideoController(_player);
    _source = widget.source;
    _rule = widget.source == null ? null : widget.service.rule(widget.source!.ruleId);
    _road = widget.road;
    _episode = widget.episode;
    _roads = widget.roads;
    _parsed = widget.parsed;
    _resumedFrom = widget.start > Duration.zero ? widget.start : null;
    _subscriptions
      ..add(_player.stream.buffering.listen(_buffering))
      ..add(_player.stream.width.listen((_) => _measure()))
      ..add(_player.stream.height.listen((_) => _measure()))
      ..add(_player.stream.error.listen((message) {
        campusLog('[CinemaPlayer] action=error message=${message.length > 120 ? message.substring(0, 120) : message}');
        _record(ok: false);
        if (mounted) setState(() => _error = '播放出错，可以重新载入或换个源');
      }))
      ..add(_player.stream.position.listen((position) {
        if (position > Duration.zero && mounted && _opening) {
          _record(ok: true);
          setState(() => _opening = false);
          _watchSlow();
        }
        _warmNext(position);
      }));
    _saveTimer = Timer.periodic(const Duration(seconds: 10), (_) => unawaited(_save()));
    unawaited(_open(start: widget.start));
  }

  void _measure() {
    final width = _player.state.width, height = _player.state.height;
    if (width == null || height == null || width <= 0 || height <= 0 || !mounted) return;
    final aspect = width / height;
    if (aspect != _aspect) setState(() => _aspect = aspect);
  }

  void _buffering(bool buffering) {
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

  // 一集剩最后 2 分钟时预取下一集（人工决策见 cinema_service.dart 的 warm）。
  void _warmNext(Duration position) {
    final roads = _roads, duration = _player.state.duration;
    if (_warmedNext || !_titleMode || !_hasNext || roads == null || duration <= Duration.zero || duration - position > const Duration(minutes: 2)) return;
    _warmedNext = true;
    unawaited(widget.service.warm(roads[_road].episodes[_episode + 1].url, rule: _rule));
  }

  CinemaEpisode? get _current {
    final roads = _roads;
    if (roads == null || _road >= roads.length || _episode >= roads[_road].episodes.length) return null;
    return roads[_road].episodes[_episode];
  }

  Future<void> _open({Duration start = Duration.zero, bool fresh = false}) async {
    final generation = ++_generation;
    _cancel?.complete();
    final cancel = _cancel = Completer<void>();
    _openWatch
      ..reset()
      ..start();
    _recorded = false;
    _warmedNext = false;
    setState(() {
      _opening = true;
      _slow = false;
      _error = null;
    });
    _watchSlow();
    try {
      final CinemaPlayable playable;
      if (_titleMode) {
        final rule = _rule;
        if (rule == null) throw const CinemaRuleException('这个源已经下架，换一个源试试');
        final roads = _roads = fresh || _roads == null ? await widget.service.chapters(rule, _source!.source, fresh: fresh, cancel: cancel.future) : _roads!;
        if (generation != _generation) return;
        _road = _road.clamp(0, roads.length - 1);
        _episode = _episode.clamp(0, roads[_road].episodes.length - 1);
        playable = await widget.service.playable(roads[_road].episodes[_episode].url, rule: rule);
      } else {
        final parser = widget.parser;
        final parsed = _parsed = fresh && parser != null ? await widget.service.cloud.parse(parser, widget.target!, fresh: true) : _parsed!;
        playable = await widget.service.playable(parsed.url, playlist: parsed.type == 'm3u8');
      }
      if (generation != _generation || !mounted) {
        widget.service.release(playable);
        return;
      }
      await _player.open(Media(playable.uri.toString(), httpHeaders: playable.headers, start: start > Duration.zero ? start : null));
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
    } catch (error, stack) {
      campusLog('[CinemaPlayer] action=open errorType=${error.runtimeType}\n$stack');
      if (generation == _generation) _record(ok: false);
      if (mounted && generation == _generation) setState(() => _error = '没能打开，可以重新载入或换个源');
    } finally {
      if (mounted && generation == _generation && _error != null) setState(() => _opening = false);
    }
  }

  // 记下看到哪（只在找片里）；出错只记日志，不打扰播放。进度还没动（打开中、没打开成）时不记，免得接着看的位置被 0 盖掉。
  Future<void> _save() async {
    final title = widget.title, source = _source, episode = _current;
    if (title == null || source == null || episode == null || _opening) return;
    final state = _player.state;
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
    } catch (error, stack) {
      campusLog('[CinemaPlayer] action=save errorType=${error.runtimeType}\n$stack');
    }
  }

  Future<void> _pickEpisode(int road, int episode) async {
    if (road == _road && episode == _episode && _error == null) return;
    _abandon();
    await _save();
    _road = road;
    _episode = episode;
    _resumedFrom = null;
    await _open();
  }

  bool get _hasNext {
    final roads = _roads;
    return roads != null && _road < roads.length && _episode + 1 < roads[_road].episodes.length;
  }

  // 换源：按集名在新源里找同一集（先找同序号的线路，再找全部线路），找不到就留在原来的源。
  Future<void> _pickSource(CinemaSourceRef source) async {
    final rule = widget.service.rule(source.ruleId);
    final name = _current?.name;
    if (rule == null) {
      showCampusToast(context, '这个源已经下架');
      return;
    }
    _cancel?.complete();
    final cancel = _cancel = Completer<void>();
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final roads = await widget.service.chapters(rule, source.source, cancel: cancel.future);
      final order = [if (_road < roads.length) _road, for (var index = 0; index < roads.length; index++) if (index != _road) index];
      for (final road in order) {
        final episode = roads[road].episodes.indexWhere((item) => item.name == name);
        if (episode < 0) continue;
        _abandon();
        await _save();
        if (!mounted) return;
        _source = source;
        _rule = rule;
        _roads = roads;
        _road = road;
        _episode = episode;
        _resumedFrom = null;
        await _open(start: _player.state.position);
        return;
      }
      if (mounted) {
        setState(() => _opening = false);
        showCampusToast(context, '这个源没有「$name」');
      }
    } on CinemaRuleException catch (error) {
      if (mounted) {
        setState(() => _opening = false);
        showCampusToast(context, error.message);
      }
    } on CinemaHttpException catch (error) {
      if (mounted) {
        setState(() => _opening = false);
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
    _abandon();
    _generation++;
    _cancel?.complete();
    if (_playable case final playable?) widget.service.release(playable);
    if (_fullscreen) {
      unawaited(_applyOrientation(on: false, landscape: false).catchError((Object error, StackTrace stack) => campusLog('[CinemaPlayer] action=fullscreen_exit errorType=${error.runtimeType}\n$stack')));
    }
    _saveTimer?.cancel();
    _slowTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_save().whenComplete(() => _player.dispose()).catchError((Object error, StackTrace stack) => campusLog('[CinemaPlayer] action=dispose errorType=${error.runtimeType}\n$stack')));
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
            Video(controller: _video, controls: NoVideoControls, fit: _fit.fit, aspectRatio: _fit.ratio, fill: Colors.black),
            CinemaPlayerControls(
              player: _player,
              title: heading,
              subtitle: _titleMode ? (_current?.name ?? '') : '',
              fullscreen: _fullscreen,
              busy: (_opening || _stalled) && _error == null,
              error: _error,
              hint: _slow ? '还在缓冲，可以换个源试试' : null,
              onReload: () => unawaited(_open(start: _player.state.position, fresh: true)),
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
                onPressed: () => unawaited(_open(start: _player.state.position, fresh: true)),
                icon: const CampusIcon(CampusIcons.sync),
                label: Text(_titleMode ? '重新载入' : '重新解析'),
              ),
            ],
          ),
          if (title != null && title.sources.length > 1) ...[
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
          if (roads != null) ...[
            const SizedBox(height: CampusGap.large),
            if (roads.length > 1 && roads.length <= 3) ...[
              CampusSegmented<int>(
                values: [for (var index = 0; index < roads.length; index++) index],
                label: (index) => roads[index].name,
                selected: _road,
                onSelected: (index) => setState(() => _road = index),
              ),
              const SizedBox(height: CampusGap.medium),
            ],
            Wrap(
              spacing: CampusGap.small,
              runSpacing: CampusGap.small,
              children: [
                for (final (index, episode) in roads[_road.clamp(0, roads.length - 1)].episodes.indexed)
                  CampusGlassChip(label: episode.name, selected: index == _episode, onSelected: (_) => unawaited(_pickEpisode(_road, index))),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
