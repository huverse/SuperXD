import 'dart:async';
import 'dart:isolate';
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
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';

// 一局的进度：档位、这一局的题、计时与完成。每个游戏的对局页持有一个，自己管棋盘状态。
// 自由模式按登记项的 clock 开始计时：看题就能推理的题一出现就走表（出题、换题、从头来时），扫雷第一下、舒尔特与记忆闪光按自己的「开始」才走；
// 切到后台暂停，完成即停；记录写进 PlaygroundStore。
// [人工决策-2026-11-17 20:13:19] 用户选「推理类题一出现就计时」（取代原来一律从第一步算）：以前可以不碰棋盘先把题想好，成绩只剩点几下的时间；
// 各游戏的归类写在 playground_catalog.dart 文件头。挑战模式以服务器计时为准，不看它。
// 挑战模式（给了 challenge）：题面与档位是服务器给的，不出题、不换档、不记本机成绩；判对错与完成都交服务器核对（人工决策见 challenge/challenge_rules.dart）。
// [人工决策-2026-11-17 19:19:39] 用户要求把「乱点、全点、穷举就能通关或刷出快成绩」的路子都堵上（全游戏审查结论见 lib/playground/CLAUDE.md）。框架里的三条：
// 1. 同一道题从头来，用时与罚时接着算（表停在原处、下一步接着走），同挑战里服务器的计时不因从头来归零：不然乱试几轮、从头来再碰对的那一轮，
//    或者解开、判错看过标记后从头来照着走一遍，成绩只算最后那几秒（冰面入门乱滑一轮成功率中位 17%，碰对的那一轮约 1.4 秒）。换一道题才清零。
// 2. 罚时 penalize：自由模式点错（舒尔特）、判错（骑士与无赖、逻辑网格、天平称球的指认）加的时间，算进用时与成绩；挑战模式由服务器计错交，不罚时。
// 3. 看过答案 spoiled：答案整个亮出来过的题（扫雷踩雷揭开全部雷），之后再解开也不记成绩。
// [人工决策-2026-11-17 20:13:19] 用户选「快得不正常的不记纪录」：自由模式解开时用时（含罚时）不到这题预计用时的 playTooFastRatio、也不到 playTooFastFloor，
// 就不进最好成绩（tooFast），结果写「解得太快，不记成绩」。堵的是换一道题接着蒙：骑士入门第一次就蒙对是 1/8、冰面入门乱滑一轮约 1/5，
// 换几道题就能碰出一两秒的纪录。舒尔特与记忆闪光（clock 是 start）不套：开始前看不到题、没有蒙的捷径，拼的就是快（闪光的用时大半是固定的亮灭）。
const playTooFastRatio = .15;
const playTooFastFloor = Duration(seconds: 30);

class PlaySession<P, A> extends ChangeNotifier {
  // first：外壳在后台出好的第一道题（档位对得上才用，没给就当场出）。
  PlaySession({required this.game, required this.rules, required this.store, int Function()? seeds, PlayFirst? first, this.challenge})
    : _seeds = seeds ?? (() => math.Random().nextInt(1 << 32)),
      _apart = seeds == null && challenge == null && game.challengeable,
      tier = challenge == null ? store.tierOf(game.id) : PuzzleTier.named(challenge.level.tier)! {
    if (challenge == null) {
      if (first case (:final seed, tier: final drawn, draw: final PuzzleDraw<P, A> draw) when drawn == tier) {
        _seed = seed;
        _puzzle = draw.puzzle;
        _reference = draw.solution;
      } else {
        _draw(_seed = _seeds());
      }
      _prepare(tier);
      if (_onSight) _run();
    } else {
      // 题面在建 PlayChallenge 时已按这个游戏的规则解好（认不得的那一关挑战那一页就拦下了）。
      _puzzle = challenge!.puzzle as P;
    }
  }

  final PlaygroundGame game;
  final PuzzleRules<P, A> rules;
  final PlaygroundStore store;
  final PlayChallenge? challenge;
  final int Function() _seeds;
  // 自由模式的下一道题先在另一个 isolate 里出好（专家档出一道要几十到上百毫秒，在界面线程出会卡一下）：每档最多备一道，种子先取好；
  // 「换一道题」「再来一局」「换到下一档」时出好了就直接用，没出好就用同一个种子当场出（题一样）。只给能进挑战的游戏备：它们的规则是纯 Dart 整数运算，
  // 在别的 isolate 里出题安全；画线入杯用 forge2d 的原生世界（全局的世界表不是线程安全的），舒尔特出题瞬间完成，都当场出。测试注入种子时也当场出（种子序列由测试定）。
  final bool _apart;
  final _upcoming = <PuzzleTier, _Upcoming<P, A>>{};
  PuzzleTier tier;
  late P _puzzle;
  A? _reference;
  late int _seed;
  final _watch = Stopwatch();
  bool _paused = false;
  // 表在走：题一出现（或第一步）起到解开或结束为止（切后台时 _watch 停着、这里不变，回来接着走）；
  // 从头来时题一出现就计时的接着走，其余停在原处、下一步接着走。
  bool _ticking = false;
  // 这道题动过（走过一步）：换档前要不要先确认看它，换一道题才清。
  bool _touched = false;
  // 罚时与看过答案（见类上的人工决策）：同一道题从头来都留着，换一道题才清。
  var _penalty = Duration.zero;
  bool _spoiled = false;
  // 这一次解开得快得不正常、没记成绩（见类上 11-17 20:13:19 那条）；从头来、换题清掉。
  bool _tooFast = false;
  bool finished = false;
  // 挑战模式：服务器判过对的那一次，与完成时交出去的那份答案（连不上时原样重交）。
  PlayVerdict? _passed;
  Object? _submitted;
  Future<PlayVerdict>? submission;
  // 正在等服务器判定（判对错类的游戏这时不再接受确认）。
  bool judging = false;
  // 对局页已关（如挑战到点退回）：之后才回来的服务器判定不再通知。
  bool _disposed = false;

  P get puzzle => _puzzle;
  // 出题时的参考解（页面拿它算「最少几步」）；挑战模式没有（服务器不给），页面就不写最少几步。
  A? get reference => _reference;
  int get seed => _seed;

  void _draw(int seed) {
    final draw = rules.generate(seed, tier);
    _puzzle = draw.puzzle;
    _reference = draw.solution;
  }

  // 给这一档备下一道题（已经备着就不再备）。
  void _prepare(PuzzleTier tier) {
    if (!_apart || _upcoming.containsKey(tier)) return;
    final upcoming = _upcoming[tier] = _Upcoming<P, A>(_seeds());
    upcoming.done = playGenerateApart(rules, upcoming.seed, tier).then<void>((draw) => upcoming.draw = draw, onError: (Object error, StackTrace stack) => campusLog('[Playground] action=prefetch errorType=${error.runtimeType}\n$stack'));
  }

  // 测试用：这一档备着的下一道题出好时完成，没备为空。
  @visibleForTesting
  Future<void>? upcoming(PuzzleTier tier) => _upcoming[tier]?.done;

  // 这道题走过一步（换档前先确认）。题一出现就计时的游戏表早就在走，动没动看这个。
  bool get started => _touched;
  // 表在走（对局页据此刷新用时）。
  bool get running => _ticking;
  // 用时含罚时（成绩也按它记）。
  Duration get elapsed => _watch.elapsed + _penalty;
  Duration get penalty => _penalty;
  bool get spoiled => _spoiled;
  bool get tooFast => _tooFast;

  // 测试用：测试一下子就走完一局、用的又是真实时间，快得不正常的门槛在测试里默认关掉（test/flutter_test_config.dart），专门测它的用例自己打开。
  @visibleForTesting
  static bool tooFastGuard = true;

  // 题一出现就计时（自由模式、登记项的 clock 是 sight）。
  bool get _onSight => challenge == null && game.clock == PlayClock.sight;

  void _run() {
    _ticking = true;
    if (!_paused) _watch.start();
  }

  // 一步：记下动过；表没走就开始走（第一步、从头来之后的第一步）。
  void moved() {
    if (finished || (_touched && _ticking)) return;
    _touched = true;
    if (!_ticking) _run();
    notifyListeners();
  }

  void pause() {
    _paused = true;
    _watch.stop();
  }

  void resume() {
    _paused = false;
    if (_ticking) _watch.start();
  }

  // 罚时（自由模式点错、判错）：加进用时，状态行原地写一下加了几秒（PlayFrame）。挑战模式不罚（服务器计错交）。
  void penalize(Duration amount) {
    if (challenge != null || finished) return;
    _penalty += amount;
    notifyListeners();
  }

  // 判错一次的罚时：这道题预计用时的四分之一，按 5 秒取整、至少 5 秒（按题缓存）。
  // 量法（build 下的作弊摸底）：骑士与无赖不看题挨个试、或只翻标出来的人，入门到专家要判错 4–7 次，罚四分之一时这样碰对的用时都不比预计用时短；
  // 也约等于挑战里错交一次扣一成分的分量（参考用时是预计用时的 1.5 倍）。
  Duration get wrongPenalty => Duration(seconds: math.max(5, (_expectedSeconds / 20).round() * 5));
  // 这道题的预计用时（按题缓存：有的游戏要跑一遍求解器）。
  int get _expectedSeconds => _expected ??= rules.expectedSeconds(puzzle);
  int? _expected;

  // 快得不正常（见类上 11-17 20:13:19 那条）：先比 30 秒（多数局到不了这一步就不用算预计用时）。
  bool get _tooFastNow => tooFastGuard && game.clock != PlayClock.start && elapsed < playTooFastFloor && elapsed.inMilliseconds < _expectedSeconds * 1000 * playTooFastRatio;

  // 同一道题从头来（见类上的人工决策第 1 条）：棋盘由对局页清，用时与罚时接着算；题一出现就计时的表接着走，其余停到下一步再走。
  void restart() {
    _ticking = false;
    _watch.stop();
    if (_onSight) _run();
    _tooFast = false;
    finished = false;
    notifyListeners();
  }

  // 换了一道题：用时、罚时与看过答案都清掉；题一出现就计时的从这一刻走表。
  void _fresh() {
    _ticking = false;
    _touched = false;
    _watch
      ..stop()
      ..reset();
    _penalty = Duration.zero;
    _expected = null;
    _spoiled = false;
    _tooFast = false;
    finished = false;
    if (_onSight) _run();
    notifyListeners();
  }

  // 换一道题，可同时换档（换档记住，下次打开这个游戏还是这一档）。
  void next({PuzzleTier? tier}) {
    if (tier != null && tier != this.tier) {
      this.tier = tier;
      unawaited(store.chooseTier(game.id, tier).catchError((Object error, StackTrace stack) => campusLog('[Playground] action=tier_save errorType=${error.runtimeType}\n$stack')));
    }
    final upcoming = _upcoming.remove(this.tier);
    if (upcoming?.draw case final draw?) {
      _seed = upcoming!.seed;
      _puzzle = draw.puzzle;
      _reference = draw.solution;
    } else {
      _draw(_seed = upcoming?.seed ?? _seeds());
    }
    _fresh();
    _prepare(this.tier);
  }

  // 结束但不记成绩（如扫雷踩雷）：停表、置为结束并通知对局页停走表，之后只能从头来或换一道题。
  // revealed：答案整个亮出来了（扫雷揭开全部雷），这一题之后再解开也不记成绩（见类上的人工决策第 3 条）。
  void end({bool revealed = false}) {
    _ticking = false;
    _watch.stop();
    if (revealed) _spoiled = true;
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
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // 解开了：停表、记成绩（用时含罚时），返回是不是这一档的新纪录；看过答案的题与快得不正常的不记（返回 false）。
  // 挑战模式不记本机成绩，把答案交服务器核对（submission，结果弹层等它），返回 false。
  Future<bool> finish({int? moves, A? answer}) async {
    _ticking = false;
    _watch.stop();
    finished = true;
    notifyListeners();
    final challenge = this.challenge;
    if (challenge == null) {
      // 结果弹层里有「换到下一档」：下一档也先备一道。
      if (tier.index + 1 < PuzzleTier.values.length) _prepare(PuzzleTier.values[tier.index + 1]);
      if (_spoiled || (_tooFast = _tooFastNow)) return false;
      return store.finish(game.id, tier, millis: elapsed.inMilliseconds, moves: moves, at: DateTime.now());
    }
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

// 备着的下一道题：种子先取好，另一个 isolate 出好后填上 draw。
class _Upcoming<P, A> {
  _Upcoming(this.seed);
  final int seed;
  PuzzleDraw<P, A>? draw;
  late final Future<void> done;
}

// 在另一个 isolate 里出一道题（下一道题与外壳的第一道题共用）：只把规则、种子与档位带过去（顶层函数，闭包里没有页面上的任何东西）。
// 只给纯 Dart 的规则用：画线入杯的 forge2d 原生世界表不是线程安全的。
Future<PuzzleDraw<P, A>> playGenerateApart<P, A>(PuzzleRules<P, A> rules, int seed, PuzzleTier tier) => Isolate.run(() => rules.generate(seed, tier));

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

class _PlayFrameState extends State<PlayFrame> with WidgetsBindingObserver {
  // 用时按秒刷新：只在走表且在前台时，用一次性计时器对到下一次秒数变化再刷新（不逐帧出帧，棋盘不动时不画）。
  // 挑战模式改写这一局剩下的时间（服务器计时、不暂停），一直走，到点退回挑战那一页。
  Timer? _clock;
  var _shownSeconds = 0;
  var _timeUp = false;
  var _foreground = true;
  // 刚加的罚时：状态行末尾用警示色写「+1 秒」，停一会儿收起（连着加就合在一起、重新计时）。
  var _seenPenalty = Duration.zero, _added = Duration.zero;
  Timer? _addedFade;
  static const _addedShown = Duration(milliseconds: 1500);

  int get _seconds => switch (widget.session.challenge) {
    final challenge? => math.max(0, challenge.deadline.difference(DateTime.now()).inSeconds),
    null => widget.session.elapsed.inSeconds,
  };

  // 到下一次显示的秒数变化还有多久（多等 1 毫秒，落在变化之后）：自由模式看这一局的用时，挑战看离到点还有多久，到点了马上。
  Duration get _untilNextSecond {
    const second = Duration.microsecondsPerSecond;
    final micros = switch (widget.session.challenge) {
      final challenge? => challenge.deadline.difference(DateTime.now()).inMicroseconds,
      null => second - widget.session.elapsed.inMicroseconds % second,
    };
    if (widget.session.challenge != null) return micros <= 0 ? Duration.zero : Duration(microseconds: micros % second + 1000);
    return Duration(microseconds: micros + 1000);
  }

  void _tick() {
    _clock = null;
    if (!mounted) return;
    final seconds = _seconds;
    if (seconds != _shownSeconds) setState(() => _shownSeconds = seconds);
    if (widget.session.challenge != null && seconds <= 0 && !_timeUp) {
      _timeUp = true;
      showCampusToast(context, '时间到了');
      // 上面开着的弹层（玩法、选数、选值、结果弹层）一起收掉，再退回挑战那一页。
      final navigator = Navigator.of(context), page = ModalRoute.of(context);
      navigator.popUntil((route) => route == page);
      unawaited(navigator.maybePop());
    }
    _syncClock();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(_sessionChanged);
    _shownSeconds = _seconds;
    _syncClock();
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
    _clock?.cancel();
    _addedFade?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      widget.session.resume();
    } else {
      widget.session.pause();
    }
    _sessionChanged();
  }

  // 走表的时候排下一次刷新，停了就撤掉；用时有变（换题、从头来）时重排。
  void _syncClock({bool reset = false}) {
    final session = widget.session;
    final running = _foreground && (session.challenge != null ? !_timeUp : session.running);
    if (!running || reset) {
      _clock?.cancel();
      _clock = null;
    }
    if (running) _clock ??= Timer(_untilNextSecond, _tick);
  }

  void _sessionChanged() {
    _syncClock(reset: true);
    final penalty = widget.session.penalty;
    if (penalty > _seenPenalty) {
      _added += penalty - _seenPenalty;
      _addedFade?.cancel();
      _addedFade = Timer(_addedShown, () {
        if (mounted) setState(() => _added = Duration.zero);
      });
    } else if (penalty < _seenPenalty) {
      _addedFade?.cancel();
      _added = Duration.zero;
    }
    _seenPenalty = penalty;
    if (mounted) setState(() => _shownSeconds = _seconds);
  }

  // 换档：这一局走了几步还没解开时先确认（换档会换一道题）。
  Future<void> _chooseTier(BuildContext anchor) async {
    final session = widget.session;
    final tier = await showCampusMenu<PuzzleTier>(anchor, selected: session.tier, items: [for (final tier in PuzzleTier.values) CampusMenuItem(value: tier, label: tier.label)]);
    if (tier == null || tier == session.tier || !mounted) return;
    if (session.started && !session.finished && !await showCampusConfirm(context, title: '换成${tier.label}？', message: '这一局的进度不保留', action: '换难度')) return;
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
    final status = [challenge == null ? clock : '还有 $clock', ?widget.status].join(' · ');
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
              label: Row(mainAxisSize: MainAxisSize.min, children: [PlayTierDot(session.tier), const SizedBox(width: 8), Text(session.tier.label)]),
            ))
          else ...[
            PlayTierDot(session.tier),
            const SizedBox(width: 8),
            Text('${challenge.name} · ${session.tier.label}', style: Theme.of(context).textTheme.titleSmall),
          ],
          const SizedBox(width: 12),
          Expanded(child: DotSeparatedText(status, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]))),
          // 刚加的罚时原地写在用时这一行（读屏随即播报），停一会儿收起；用时本身已经含罚时。
          if (_added > Duration.zero) ...[
            const SizedBox(width: CampusGap.small),
            Semantics(liveRegion: true, child: Text('+${_added.inSeconds} 秒', style: TextStyle(fontSize: CampusFontSize.secondary, fontWeight: FontWeight.w600, color: palette.danger, fontFeatures: const [FontFeature.tabularFigures()]))),
          ],
        ])),
        // 收碎片的关：写明被改写的那一处怎么算（玩家自己算）；要最少步数的写明几步内算过。
        if (challenge != null)
          for (final (icon, line) in [
            if (challengeConsumeText(challenge.level) case final consume?) (CampusIcons.key, consume),
            if (challengeStepsText(challenge.level) case final steps?) (CampusIcons.flag, steps),
          ])
            Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CampusIcon(icon, size: 18, color: palette.onSurfaceVariant),
              const SizedBox(width: 8),
              // 算式在「=」前后分两段：窄屏放不下一行时在等号处换行，不把「余数」拆开。
              Expanded(child: Wrap(spacing: 6, children: [
                for (final (index, part) in line.split(' = ').indexed) Text(index == 0 ? part : '= $part', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
              ])),
            ])),
        // 棋盘单独一层：状态行每秒换字时不重画棋盘，棋盘的动画也不带着顶栏与底部操作一起重画。
        Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 12), child: RepaintBoundary(child: widget.board))),
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

// 五档难度各一种色调（自由模式的档位、挑战卡与关卡图处处一样）：入门绿、简单青、普通蓝、困难橙、专家红，深色下提亮。
// 只当辨认档位的小色块用，不用来写字或当按钮色（主色只留给按钮与图标）。
Color playTierColor(CampusPalette palette, PuzzleTier tier) {
  const hues = {PuzzleTier.entry: 145.0, PuzzleTier.easy: 185.0, PuzzleTier.normal: 215.0, PuzzleTier.hard: 28.0, PuzzleTier.expert: 355.0};
  return HSLColor.fromAHSL(1, hues[tier]!, .62, palette.isDark ? .62 : .46).toColor();
}

// 档位前的小圆点。
class PlayTierDot extends StatelessWidget {
  const PlayTierDot(this.tier, {super.key, this.size = 10});
  final PuzzleTier tier;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: size, child: DecoratedBox(decoration: BoxDecoration(color: playTierColor(CampusPalette.of(context), tier), shape: BoxShape.circle)));
}

// 所有游戏共用的触感（设计语言第 8 节）：落子、挪动用选择触感，违规用重震（同学习通签到码输错），解开用成功触感（见 showPlayResult）。
void playTick() => HapticFeedback.selectionClick();
void playRejected() => HapticFeedback.heavyImpact();
