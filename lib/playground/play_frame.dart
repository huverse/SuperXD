import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/playground/challenge/play_challenge.dart';
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
// 挑战模式（给了 challenge）：题面与档位是服务器给的，不出题、不换档、不记本机成绩；判对错与完成都交服务器核对（人工决策见 challenge/challenge_rules.dart）。
class PlaySession<P, A> extends ChangeNotifier {
  PlaySession({required this.game, required this.rules, required this.store, int Function()? seeds, this.challenge})
    : _seeds = seeds ?? (() => math.Random().nextInt(1 << 32)),
      tier = challenge == null ? store.tierOf(game.id) : PuzzleTier.named(challenge.level.tier)! {
    if (challenge == null) {
      _draw(_seed = _seeds());
    } else {
      _puzzle = rules.decodePuzzle(challenge!.level.puzzle);
    }
  }

  final PlaygroundGame game;
  final PuzzleRules<P, A> rules;
  final PlaygroundStore store;
  final PlayChallenge? challenge;
  final int Function() _seeds;
  PuzzleTier tier;
  late P _puzzle;
  A? _reference;
  late int _seed;
  final _watch = Stopwatch();
  bool _paused = false;
  bool finished = false;
  // 挑战模式：服务器判过对的那一次，与完成时交出去的那份答案（连不上时原样重交）。
  PlayVerdict? _passed;
  Object? _submitted;
  Future<PlayVerdict>? submission;
  // 正在等服务器判定（判对错类的游戏这时不再接受确认）。
  bool judging = false;

  P get puzzle => _puzzle;
  // 出题时的参考解（页面拿它算「最少几步」）；挑战模式没有（服务器不给），页面就不写最少几步。
  A? get reference => _reference;
  int get seed => _seed;

  void _draw(int seed) {
    final draw = rules.generate(seed, tier);
    _puzzle = draw.puzzle;
    _reference = draw.solution;
  }
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
    _draw(_seed = _seeds());
    restart();
  }

  // 结束但不记成绩（如扫雷踩雷）：停表、置为结束并通知对局页停走表，之后只能从头来或换一道题。
  void end() {
    _watch.stop();
    finished = true;
    notifyListeners();
  }

  // 判一次作答（判对错类的游戏在玩家确认时调）：自由模式按规则在本机判；挑战模式交服务器核对，错的计一次错交。
  // 连不上服务器返回 null（这一次不算数，页面提示后可以再确认一次）。
  Future<bool?> judge(A answer) async {
    final challenge = this.challenge;
    if (challenge == null) return rules.solved(puzzle, answer);
    judging = true;
    notifyListeners();
    try {
      final verdict = await challenge.submit(rules.encodeAnswer(answer));
      if (verdict.correct) _passed = verdict;
      return verdict.correct;
    } on ChallengeException catch (error) {
      campusLog('[Playground] action=judge failure=${error.failure.name}');
      return null;
    } finally {
      judging = false;
      notifyListeners();
    }
  }

  // 解开了：停表、记成绩，返回是不是这一档的新纪录。挑战模式不记本机成绩，把答案交服务器核对（submission，结果弹层等它），返回 false。
  Future<bool> finish({int? moves, A? answer}) async {
    _watch.stop();
    finished = true;
    notifyListeners();
    final challenge = this.challenge;
    if (challenge == null) return store.finish(game.id, tier, millis: _watch.elapsedMilliseconds, moves: moves, at: DateTime.now());
    if (_passed case final passed?) {
      submission = Future.value(passed);
    } else {
      _submitted = rules.encodeAnswer(answer as A);
      resubmit();
    }
    return false;
  }

  // 完成时那份答案没交上（连不上服务器）：原样再交一次（号码不变，服务器只算一次）。
  void resubmit() => submission = challenge!.submit(_submitted);
}

// 用时写成 分:秒（一小时以上写 时:分:秒）；tenths 为真时写到 0.1 秒：不满一分钟写「12.3 秒」，满了在分:秒后面接「.3」（1:02.3）。
// 都是向下取整（分:秒舍去不足一秒的，0.1 秒舍去不足 0.1 秒的），59.96 秒写「59.9 秒」而不是进成 60.0。
String playDuration(Duration elapsed, {bool tenths = false}) {
  final seconds = elapsed.inSeconds;
  String two(int value) => value.toString().padLeft(2, '0');
  final whole = seconds >= 3600 ? '${seconds ~/ 3600}:${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}' : '${seconds ~/ 60}:${two(seconds % 60)}';
  if (!tenths) return whole;
  final tenth = elapsed.inMilliseconds ~/ 100 % 10;
  return seconds < 60 ? '$seconds.$tenth 秒' : '$whole.$tenth';
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
  // 用时按秒刷新：只在走表时出帧。挑战模式改写这一局剩下的时间（服务器计时、不暂停），一直走，到点退回挑战那一页。
  late final _ticker = createTicker((_) {
    final seconds = _seconds;
    if (seconds != _shownSeconds) setState(() => _shownSeconds = seconds);
    if (widget.session.challenge != null && seconds <= 0 && !_timeUp) {
      _timeUp = true;
      showCampusToast(context, '时间到了');
      unawaited(Navigator.maybePop(context));
    }
  });
  var _shownSeconds = 0;
  var _timeUp = false;

  int get _seconds => switch (widget.session.challenge) {
    final challenge? => math.max(0, challenge.deadline.difference(DateTime.now()).inSeconds),
    null => widget.session.elapsed.inSeconds,
  };

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
    final running = widget.session.challenge != null || widget.session.started && !widget.session.finished;
    if (running && !_ticker.isActive) unawaited(_ticker.start());
    if (!running && _ticker.isActive) _ticker.stop();
  }

  void _sessionChanged() {
    _syncTicker();
    if (mounted) setState(() => _shownSeconds = _seconds);
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
    final choice = await showCampusMenu<String>(anchor, items: [
      const CampusMenuItem(value: 'restart', label: '这一题从头来', icon: CampusIcons.restore),
      // 挑战的题是服务器给的，不能换。
      if (widget.session.challenge == null) const CampusMenuItem(value: 'new', label: '换一道题', icon: CampusIcons.shuffle),
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
    final challenge = session.challenge;
    final clock = playDuration(Duration(seconds: _shownSeconds));
    final status = [challenge == null ? clock : '剩 $clock', ?widget.status].join(' · ');
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
          // 同下拉字段：名字在前、向下的箭头在后。挑战里档位是定的，只写关名与档位。
          if (challenge == null)
            Builder(builder: (anchor) => TextButton.icon(
              onPressed: () => _chooseTier(anchor),
              iconAlignment: IconAlignment.end,
              icon: const CampusIcon(CampusIcons.expand),
              label: Text(session.tier.label),
            ))
          else
            Text('${challenge.name} · ${session.tier.label}', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(width: 12),
          Expanded(child: DotSeparatedText(status, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]))),
        ])),
        // 收钥匙的关：写明题面里哪几处是前面几关给的钥匙。
        if (challenge != null && challenge.level.keyed.isNotEmpty)
          Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CampusIcon(CampusIcons.key, size: 18, color: palette.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(child: Text(
              '钥匙：${[for (final keyed in challenge.level.keyed) '${challengeSlotName(challenge.level.game, keyed.at, challenge.level.puzzle)}是 ${keyed.key}'].join('，')}',
              style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
            )),
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
