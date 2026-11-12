import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';

// 一局的进度：档位、这一局的题、计时与完成。每个游戏的对局页持有一个，自己管棋盘状态。
// 计时从第一步开始（同常见的谜题游戏），切到后台暂停，完成即停；记录写进 PlaygroundStore。
class PlaySession<P, A> extends ChangeNotifier {
  PlaySession({required this.game, required this.rules, required this.store, int Function()? seeds})
    : _seeds = seeds ?? (() => math.Random().nextInt(1 << 32)),
      tier = store.tierOf(game.id) {
    draw = rules.generate(_seed = _seeds(), tier);
  }

  final PlaygroundGame game;
  final PuzzleRules<P, A> rules;
  final PlaygroundStore store;
  final int Function() _seeds;
  PuzzleTier tier;
  late PuzzleDraw<P, A> draw;
  late int _seed;
  final _watch = Stopwatch();
  bool _paused = false;
  bool finished = false;

  P get puzzle => draw.puzzle;
  int get seed => _seed;
  bool get started => _watch.elapsedTicks > 0 || _watch.isRunning;
  Duration get elapsed => _watch.elapsed;

  // 第一步：开始计时。
  void moved() {
    if (finished || _watch.isRunning || _paused) return;
    _watch.start();
    notifyListeners();
  }

  void pause() {
    _paused = true;
    _watch.stop();
  }

  void resume() {
    _paused = false;
    if (started && !finished) _watch.start();
  }

  // 同一道题从头来。
  void restart() {
    _watch
      ..stop()
      ..reset();
    finished = false;
    notifyListeners();
  }

  // 换一道题，可同时换档（换档记住，下次打开这个游戏还是这一档）。
  void next({PuzzleTier? tier}) {
    if (tier != null && tier != this.tier) {
      this.tier = tier;
      unawaited(store.chooseTier(game.id, tier).catchError((Object error, StackTrace stack) => campusLog('[Playground] action=tier_save errorType=${error.runtimeType}\n$stack')));
    }
    draw = rules.generate(_seed = _seeds(), this.tier);
    restart();
  }

  // 解开了：停表、记成绩，返回是不是这一档的新纪录。
  Future<bool> finish({int? moves}) async {
    _watch.stop();
    finished = true;
    notifyListeners();
    return store.finish(game.id, tier, millis: _watch.elapsedMilliseconds, moves: moves, at: DateTime.now());
  }
}

// 用时写成 分:秒（一小时以上写 时:分:秒）。
String playDuration(Duration elapsed) {
  final seconds = elapsed.inSeconds;
  String two(int value) => value.toString().padLeft(2, '0');
  return seconds >= 3600 ? '${seconds ~/ 3600}:${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}' : '${seconds ~/ 60}:${two(seconds % 60)}';
}

// 对局页的骨架：顶栏（返回、游戏名、玩法、⋯）、状态行（难度、用时与游戏自己的状态）、棋盘、底部操作。
// 棋盘占满中间剩下的地方，游戏按给它的尺寸自己排；底部操作是一排色调胶囊（撤销等），没有就不画。
class PlayFrame extends StatefulWidget {
  const PlayFrame({super.key, required this.session, required this.board, required this.onNewGame, required this.onRestart, this.status, this.controls = const []});
  final PlaySession<Object?, Object?> session;
  final Widget board;
  // 游戏自己的状态（如「12 步 · 最少 7 步」），跟在用时后面。
  final String? status;
  final List<Widget> controls;
  // 换一道题（可带新档位）与同一道题从头来：对局页重置自己的棋盘，再调 session 的 next 或 restart。
  final void Function(PuzzleTier? tier) onNewGame;
  final VoidCallback onRestart;

  @override
  State<PlayFrame> createState() => _PlayFrameState();
}

class _PlayFrameState extends State<PlayFrame> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  // 用时按秒刷新：只在走表时出帧。
  late final _ticker = createTicker((_) {
    final seconds = widget.session.elapsed.inSeconds;
    if (seconds != _shownSeconds) setState(() => _shownSeconds = seconds);
  });
  var _shownSeconds = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(_sessionChanged);
    _syncTicker();
  }

  @override
  void didUpdateWidget(PlayFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_sessionChanged);
      widget.session.addListener(_sessionChanged);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.session.removeListener(_sessionChanged);
    _ticker.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.session.resume();
    } else {
      widget.session.pause();
    }
    _sessionChanged();
  }

  void _syncTicker() {
    final running = widget.session.started && !widget.session.finished;
    if (running && !_ticker.isActive) unawaited(_ticker.start());
    if (!running && _ticker.isActive) _ticker.stop();
  }

  void _sessionChanged() {
    _syncTicker();
    if (mounted) setState(() => _shownSeconds = widget.session.elapsed.inSeconds);
  }

  // 换档：这一局走了几步还没解开时先确认（换档会换一道题）。
  Future<void> _chooseTier(BuildContext anchor) async {
    final session = widget.session;
    final tier = await showCampusMenu<PuzzleTier>(anchor, selected: session.tier, items: [for (final tier in PuzzleTier.values) CampusMenuItem(value: tier, label: tier.label)]);
    if (tier == null || tier == session.tier || !mounted) return;
    if (session.started && !session.finished && !await showCampusConfirm(context, title: '换成${tier.label}？', message: '会换一道新题，这一局的进度不保留。', action: '换难度')) return;
    widget.onNewGame(tier);
  }

  Future<void> _more(BuildContext anchor) async {
    final choice = await showCampusMenu<String>(anchor, items: const [
      CampusMenuItem(value: 'restart', label: '这一题从头来', icon: CampusIcons.restore),
      CampusMenuItem(value: 'new', label: '换一道题', icon: CampusIcons.shuffle),
    ]);
    if (!mounted) return;
    switch (choice) {
      case 'restart':
        widget.onRestart();
      case 'new':
        widget.onNewGame(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final palette = CampusPalette.of(context);
    final inset = MediaQuery.paddingOf(context).bottom;
    final status = [playDuration(Duration(seconds: _shownSeconds)), ?widget.status].join(' · ');
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.maybePop(context), icon: const CampusIcon(CampusIcons.back)),
        title: Text(session.game.name),
        actions: [
          CampusGlassCircleButton(label: '玩法', size: 44, onPressed: () => showCampusNotice(context, session.game.howToPlay, title: '玩法'), icon: const CampusIcon(CampusIcons.info)),
          const SizedBox(width: 4),
          Builder(builder: (anchor) => CampusGlassCircleButton(label: '更多操作', size: 44, onPressed: () => _more(anchor), icon: const CampusIcon(CampusIcons.manage))),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(top: false, bottom: false, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0), child: Row(children: [
          // 同下拉字段：名字在前、向下的箭头在后。
          Builder(builder: (anchor) => TextButton.icon(
            onPressed: () => _chooseTier(anchor),
            iconAlignment: IconAlignment.end,
            icon: const CampusIcon(CampusIcons.expand),
            label: Text(session.tier.label),
          )),
          const SizedBox(width: 12),
          Expanded(child: DotSeparatedText(status, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]))),
        ])),
        Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 12), child: widget.board)),
        if (widget.controls.isNotEmpty)
          CampusToastAnchor(child: Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + inset),
            child: Wrap(alignment: WrapAlignment.center, spacing: 12, runSpacing: 8, children: widget.controls),
          ))
        else
          SizedBox(height: inset),
      ])),
    );
  }
}

// 棋盘的通用外框：按给定的宽高比在可用区域里居中放到最大（不超过 maxWidth），游戏在里面按尺寸画。
class PlayBoardBox extends StatelessWidget {
  const PlayBoardBox({super.key, required this.aspectRatio, required this.builder, this.maxWidth = 560});
  final double aspectRatio;
  final double maxWidth;
  final Widget Function(BuildContext context, Size size) builder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    var width = math.min(constraints.maxWidth, maxWidth);
    var height = width / aspectRatio;
    if (height > constraints.maxHeight) {
      height = constraints.maxHeight;
      width = height * aspectRatio;
    }
    return Center(child: SizedBox(width: width, height: height, child: builder(context, Size(width, height))));
  });
}

// 所有游戏共用的触感（设计语言第 8 节）：落子、挪动用选择触感，违规用重震（同学习通签到码输错），解开用成功触感（见 showPlayResult）。
void playTick() => HapticFeedback.selectionClick();
void playRejected() => HapticFeedback.heavyImpact();
