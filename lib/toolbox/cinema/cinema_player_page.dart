import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/curve_geometry.dart';
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
import 'package:superxd/toolbox/cinema/cinema_rule.dart';
import 'package:superxd/toolbox/cinema/cinema_service.dart';

// 播放页（media_kit，libmpv）：竖屏上面是画面、下面是选集与换源；全屏是自己的页面，横的片子把画面转 90 度铺满
// （应用锁竖屏，[人工决策] 在清单的 MainActivity；这里不改方向设置，同样适用 iOS）。
// 首帧常要 10–20 秒（交接实测，腾讯系首屏要缓冲两三个分片），缓冲超过 15 秒才提示可以换源，不早报失败。
// 看片记录（只在找片里看的记，解析的不记）：每 10 秒、换集、离开时记一次看到哪。
class CinemaPlayerPage extends StatefulWidget {
  const CinemaPlayerPage.title({super.key, required this.service, required CinemaTitle this.title, required CinemaSourceRef this.source, required this.road, required this.episode, this.start = Duration.zero})
    : parser = null,
      target = null,
      parsed = null;
  const CinemaPlayerPage.parsed({super.key, required this.service, required this.parser, required String this.target, required CinemaParsed this.parsed})
    : title = null,
      source = null,
      road = 0,
      episode = 0,
      start = Duration.zero;
  final CinemaService service;
  final CinemaTitle? title;
  final CinemaSourceRef? source;
  final int road;
  final int episode;
  final Duration start;
  // 云解析的结果（重新载入时用 parser 与 target 重新解析，解出来的地址几分钟就失效）。
  final CinemaParser? parser;
  final String? target;
  final CinemaParsed? parsed;

  @override
  State<CinemaPlayerPage> createState() => _CinemaPlayerPageState();
}

// libmpv 每个进程只要初始化一次。
var _mediaKitReady = false;

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
    _parsed = widget.parsed;
    _subscriptions
      ..add(_player.stream.buffering.listen(_buffering))
      ..add(_player.stream.error.listen((message) {
        campusLog('[CinemaPlayer] action=error message=${message.length > 120 ? message.substring(0, 120) : message}');
        if (mounted) setState(() => _error = '播放出错，可以重新载入或换个源');
      }))
      ..add(_player.stream.position.listen((position) {
        if (position > Duration.zero && mounted && _opening) {
          setState(() => _opening = false);
          _watchSlow();
        }
      }))
      ..add(_player.stream.completed.listen((done) {
        if (done && mounted) unawaited(_next());
      }));
    _saveTimer = Timer.periodic(const Duration(seconds: 10), (_) => unawaited(_save()));
    unawaited(_open(start: widget.start));
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

  CinemaEpisode? get _current {
    final roads = _roads;
    if (roads == null || _road >= roads.length || _episode >= roads[_road].episodes.length) return null;
    return roads[_road].episodes[_episode];
  }

  Future<void> _open({Duration start = Duration.zero, bool fresh = false}) async {
    final generation = ++_generation;
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
        final roads = _roads ??= await widget.service.chapters(rule, _source!.source);
        if (generation != _generation) return;
        _road = _road.clamp(0, roads.length - 1);
        _episode = _episode.clamp(0, roads[_road].episodes.length - 1);
        playable = await widget.service.playable(roads[_road].episodes[_episode].url, rule: rule);
      } else {
        final parser = widget.parser;
        final parsed = _parsed = fresh && parser != null ? await widget.service.cloud.parse(parser, widget.target!, fresh: true) : _parsed!;
        playable = await widget.service.playable(parsed.url, playlist: parsed.type == 'm3u8');
      }
      if (generation != _generation || !mounted) return;
      await _player.open(Media(playable.uri.toString(), httpHeaders: playable.headers, start: start > Duration.zero ? start : null));
      if (mounted) setState(() {});
    } on CinemaRuleException catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.message);
    } on CinemaHttpException catch (error) {
      if (mounted && generation == _generation) setState(() => _error = '这个源${error.message}，换一个源试试');
    } on CinemaParseException catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.message);
    } catch (error, stack) {
      campusLog('[CinemaPlayer] action=open errorType=${error.runtimeType}\n$stack');
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
    await _save();
    _road = road;
    _episode = episode;
    await _open();
  }

  Future<void> _next() async {
    final roads = _roads;
    if (roads == null || _episode + 1 >= roads[_road].episodes.length) return;
    await _pickEpisode(_road, _episode + 1);
  }

  // 换源：按集名在新源里找同一集（先找同序号的线路，再找全部线路），找不到就留在原来的源。
  Future<void> _pickSource(CinemaSourceRef source) async {
    final rule = widget.service.rule(source.ruleId);
    final name = _current?.name;
    if (rule == null) {
      showCampusToast(context, '这个源已经下架');
      return;
    }
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final roads = await widget.service.chapters(rule, source.source);
      final order = [if (_road < roads.length) _road, for (var index = 0; index < roads.length; index++) if (index != _road) index];
      for (final road in order) {
        final episode = roads[road].episodes.indexWhere((item) => item.name == name);
        if (episode < 0) continue;
        await _save();
        if (!mounted) return;
        _source = source;
        _rule = rule;
        _roads = roads;
        _road = road;
        _episode = episode;
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
    }
  }

  Future<void> _fullscreen() async {
    final width = _player.state.width ?? 16, height = _player.state.height ?? 9;
    await Navigator.push<void>(context, CampusPageRoute(builder: (_) => _CinemaFullscreen(video: _video, landscape: width > height)));
  }

  @override
  void dispose() {
    _generation++;
    _saveTimer?.cancel();
    _slowTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_save().whenComplete(() => _player.dispose()).catchError((Object error, StackTrace stack) => campusLog('[CinemaPlayer] action=dispose errorType=${error.runtimeType}\n$stack')));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final text = Theme.of(context).textTheme;
    final title = widget.title;
    final roads = _roads;
    final heading = title?.name ?? (_parsed?.title.isNotEmpty == true ? _parsed!.title : '解析播放');
    return Scaffold(
      appBar: AppBar(
        title: Text(heading, maxLines: 1, overflow: TextOverflow.ellipsis),
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ColoredBox(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _CinemaVideo(video: _video, onFullscreen: _fullscreen),
                    // 画面底色是黑的（片子的底，不跟配色），加载圈用白色。
                    if ((_opening || _stalled) && _error == null) const IgnorePointer(child: Center(child: CampusLoader(curve: CampusCurve.infinity, size: 40, color: Colors.white))),
                  ],
                ),
              ),
            ),
            Expanded(
              child: CampusScrollFade(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(_titleMode ? (_current?.name ?? '') : (_parsed?.title ?? ''), style: text.titleMedium),
                    if (_error ?? (_slow ? '还在缓冲，可以换个源试试' : null) case final message?) ...[
                      const SizedBox(height: CampusGap.small),
                      Text(message, style: text.bodyMedium?.copyWith(color: _error == null ? palette.onSurfaceVariant : palette.danger)),
                    ],
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
                        padding: EdgeInsets.fromLTRB(16, campusFieldGap(context), 16, 16),
                        child: CampusMenuField<CinemaSourceRef>(
                          label: '片源',
                          value: _source!,
                          items: [
                            for (final ref in title.sources) CampusMenuItem(value: ref, label: [widget.service.rule(ref.ruleId)?.name ?? ref.ruleId, if (ref.remarks.isNotEmpty) ref.remarks].join(' · ')),
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
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 画面与控件：底栏只留进度与全屏（全屏是自己的页面，不用 media_kit 自带的：它会改屏幕方向）。
class _CinemaVideo extends StatelessWidget {
  const _CinemaVideo({required this.video, required this.onFullscreen});
  final VideoController video;
  final VoidCallback onFullscreen;

  @override
  Widget build(BuildContext context) {
    final theme = MaterialVideoControlsThemeData(
      seekBarPositionColor: CampusPalette.of(context).accent,
      seekBarThumbColor: CampusPalette.of(context).accent,
      bottomButtonBar: [
        const MaterialPositionIndicator(),
        const Spacer(),
        MaterialCustomButton(icon: const CampusIcon(CampusIcons.fullscreen, color: Colors.white), onPressed: onFullscreen),
      ],
    );
    return MaterialVideoControlsTheme(
      normal: theme,
      fullscreen: theme,
      child: Video(controller: video, controls: MaterialVideoControls),
    );
  }
}

class _CinemaFullscreen extends StatefulWidget {
  const _CinemaFullscreen({required this.video, required this.landscape});
  final VideoController video;
  final bool landscape;
  @override
  State<_CinemaFullscreen> createState() => _CinemaFullscreenState();
}

class _CinemaFullscreenState extends State<_CinemaFullscreen> {
  @override
  void initState() {
    super.initState();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
  }

  @override
  void dispose() {
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = MaterialVideoControlsThemeData(
      seekBarPositionColor: CampusPalette.of(context).accent,
      seekBarThumbColor: CampusPalette.of(context).accent,
      bottomButtonBar: [
        const MaterialPositionIndicator(),
        const Spacer(),
        MaterialCustomButton(icon: const CampusIcon(CampusIcons.close, color: Colors.white), onPressed: () => Navigator.pop(context)),
      ],
    );
    return Scaffold(
      backgroundColor: Colors.black,
      body: RotatedBox(
        quarterTurns: widget.landscape ? 1 : 0,
        child: MaterialVideoControlsTheme(normal: theme, fullscreen: theme, child: Video(controller: widget.video, controls: MaterialVideoControls)),
      ),
    );
  }
}
