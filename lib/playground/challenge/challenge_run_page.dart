import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/playground/challenge/challenge_run.dart';
import 'package:superxd/playground/challenge/play_challenge.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 一局挑战的总览（人工决策见 challenge_rules.dart 的 11-14 23:11 那条）：上面是剩下的时间，下面是关卡流程图（同参考页的大厅）——
// 每道门一段：给碎片的几关并排，箭头上写门上的数怎么来（「A × B」），下面是门后那一关；最后是终章（全部碎片相加）。
// 开着的点进去做，门前的点了输门上的数，过了的点了重做一遍再看碎片；底下一块本机笔记记碎片。结算后上面换成成绩。
// 回到前台、到点时拉一次局面（到点的服务器顺手结算）。
class ChallengeRunPage extends StatefulWidget {
  const ChallengeRunPage({super.key, required this.controller, required this.games, required this.store});
  final ChallengeRunController controller;
  final List<PlaygroundGame> games;
  final PlaygroundStore store;

  @override
  State<ChallengeRunPage> createState() => _ChallengeRunPageState();
}

class _ChallengeRunPageState extends State<ChallengeRunPage> with WidgetsBindingObserver {
  ChallengeRunController get _controller => widget.controller;
  late final _notes = TextEditingController(text: widget.store.notesOf(_controller.run.runId));
  Timer? _saving;
  // 倒计时：一次性计时器对到下一次秒数变化再刷新（不逐帧出帧，只重建那一行字）；到点只拉一次局面，没拉到等回前台再拉（不在这里反复重试）。
  Timer? _clock;
  final _left = ValueNotifier(Duration.zero);
  var _expired = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_changed);
    _clock?.cancel();
    _left.dispose();
    _saving?.cancel();
    _save(_notes.text);
    _notes.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _controller.run.running) unawaited(_controller.refresh());
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _clock?.cancel();
    _tick();
  }

  void _tick() {
    _clock = null;
    final remaining = _controller.remaining;
    _left.value = remaining.isNegative ? Duration.zero : Duration(seconds: remaining.inSeconds);
    if (!_controller.run.running) return;
    if (remaining > Duration.zero) {
      _expired = false;
      _clock = Timer(Duration(microseconds: remaining.inMicroseconds % Duration.microsecondsPerSecond + 1000), _tick);
    } else if (!_expired) {
      // 到点：拉一次局面，服务器那边结算。
      _expired = true;
      unawaited(_controller.refresh());
    }
  }

  // 笔记停手半秒再存（只留最近一局）；写不进只记日志。
  void _noted(String text) {
    _saving?.cancel();
    _saving = Timer(const Duration(milliseconds: 500), () => _save(text));
  }

  void _save(String text) => unawaited(widget.store.saveNotes(_controller.run.runId, text).catchError((Object error, StackTrace stack) => campusLog('[Challenge] action=notes_save errorType=${error.runtimeType}\n$stack')));

  PlaygroundGame? _game(String id) => widget.games.where((game) => game.id == id).firstOrNull;

  Future<void> _tap(ChallengeLevel level) async {
    if (!_controller.run.running) return;
    switch (level.state) {
      case ChallengeLevelState.open:
        await _play(level);
      case ChallengeLevelState.solved:
        if (level.extraOf == null && await showCampusConfirm(context, title: '重做${challengeLevelName(level)}？', message: '再看一次碎片，计时照走', action: '重做') && mounted) await _play(level);
      case ChallengeLevelState.gated:
        await _enter(level);
      case ChallengeLevelState.locked || ChallengeLevelState.failed:
        return;
    }
  }

  // 进一关：题面、档位或改写的那一处这个版本认不得（服务器换了写法、应用没更新）时不进，提示更新应用。
  Future<void> _play(ChallengeLevel level) async {
    final game = _game(level.game);
    if (game == null) return;
    final PlayChallenge challenge;
    try {
      challenge = _controller.challengeFor(level.id);
    } on FormatException catch (error, stack) {
      campusLog('[Challenge] action=open_level game=${level.game} errorType=${error.runtimeType}\n$stack');
      showCampusToast(context, '这一关的题看不懂，请更新应用后再试');
      return;
    }
    await Navigator.of(context).push(CampusPageRoute<void>(builder: (context) => game.builder(context, game, widget.store, challenge)));
  }

  // 门：输门上的数；终章：输全部碎片之和。输错扣时间、不说哪个碎片错了。
  Future<void> _enter(ChallengeLevel? level) async {
    final run = _controller.run;
    final letters = [for (final id in level?.inputs ?? const <String>[]) run.level(id).letter];
    final title = level == null ? '终章' : '${challengeLevelName(level)}的门';
    final hint = level == null ? '全部碎片相加' : letters.join(level.gate!.product ? ' × ' : ' + ');
    final opened = await showChallengeKeypad(context, title: title, hint: hint, submit: (value) => level == null ? _controller.finale(value) : _controller.gate(level.id, value));
    if (opened && mounted && level != null) showCampusToast(context, '门开了');
  }

  Future<void> _end() async {
    if (!await showCampusConfirm(context, title: '提前结束这一局？', message: '按已过的关结算', action: '结束', destructive: true) || !mounted) return;
    final error = await _controller.end();
    if (error != null && mounted) showCampusToast(context, error.message);
  }

  Future<void> _more(BuildContext anchor) async {
    final choice = await showCampusMenu<String>(anchor, items: const [CampusMenuItem(value: 'end', label: '提前结束', icon: CampusIcons.stop)]);
    if (choice == 'end') await _end();
  }

  // 长文案：「玩法」弹层，点了才看，三条规则各一行。
  static const _rules = '过关给一次碎片，自己记下。\n收碎片的关先开门，输错扣 20 秒。\n全部过了，输终章的最终密码。';

  @override
  Widget build(BuildContext context) {
    final run = _controller.run;
    final palette = CampusPalette.of(context);
    final inset = MediaQuery.paddingOf(context).bottom;
    final counted = run.levels.where((level) => level.extraOf == null);
    final solved = counted.where((level) => level.state == ChallengeLevelState.solved).length;
    final extras = [for (final level in run.levels) if (level.extraOf != null) level];
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.maybePop(context), icon: const CampusIcon(CampusIcons.back)),
        title: Text('${run.label} · ${run.title}'),
        actions: [
          CampusGlassCircleButton(label: '玩法', size: 44, onPressed: () => showCampusNotice(context, _rules, title: '挑战的玩法'), icon: const CampusIcon(CampusIcons.info)),
          if (run.running) ...[
            const SizedBox(width: 4),
            Builder(builder: (anchor) => CampusGlassCircleButton(label: '更多操作', size: 44, onPressed: () => _more(anchor), icon: const CampusIcon(CampusIcons.manage))),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: CampusScrollFade(bottom: inset, child: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + inset),
        children: [
          if (run.result case final result?)
            _ResultCard(result: result, solved: solved, total: counted.length)
          else
            CampusSurface(padding: const EdgeInsets.all(20), child: Row(children: [
              CampusIcon(CampusIcons.timer, size: 28, color: palette.primary),
              const SizedBox(width: 16),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ValueListenableBuilder(valueListenable: _left, builder: (context, left, _) => Text('还有 ${playDuration(left)}',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: palette.onSurface, fontFeatures: const [FontFeature.tabularFigures()]))),
                DotSeparatedText(['已过 $solved/${counted.length} 关', if (run.penalty > Duration.zero) '罚时 ${run.penalty.inSeconds} 秒'].join(' · '), style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
              ])),
            ])),
          const SizedBox(height: 16),
          for (final section in challengeSections(run)) ...[
            _Section(section: section, run: run, games: widget.games, running: run.running, onTap: (level) => unawaited(_tap(level))),
            const SizedBox(height: 4),
          ],
          if (extras.isNotEmpty) ...[
            _Arrow(label: '加试'),
            _TileGrid(levels: extras, run: run, games: widget.games, running: run.running, onTap: (level) => unawaited(_tap(level))),
            const SizedBox(height: 4),
          ],
          _Arrow(label: '全部碎片相加'),
          _FinalTile(state: run.ending, running: run.running, onTap: () => unawaited(_enter(null))),
          if (run.running) ...[
            const SizedBox(height: 24),
            TextField(
              controller: _notes,
              onChanged: _noted,
              minLines: 3,
              maxLines: 8,
              maxLength: PlaygroundStore.playgroundNotesLimit,
              style: const TextStyle(fontSize: 16),
              decoration: const InputDecoration(labelText: '笔记', hintText: 'A = ?', counterText: ''),
            ),
          ],
        ],
      )),
    );
  }
}

// 关卡图的一段：收碎片的那一关与给它碎片的几关（inputs，其中前面段里已经画过的写成小卡）；没有门的关放在 inputs、consumer 为空。
class ChallengeSection {
  const ChallengeSection({required this.inputs, required this.sources, required this.consumer, required this.carried, required this.aim});
  // 这一段并排画的几关（上一段收碎片的关紧接着给这一段碎片时，排在第一个、只在这里画一次）。
  final List<ChallengeLevel> inputs;
  // 门上的数由哪几关的碎片来（箭头上写它们的字母）。
  final List<ChallengeLevel> sources;
  final ChallengeLevel? consumer;
  // 收碎片的这一关不画在箭头下面，而是排进下一段的第一个（它紧接着给下一段碎片）。
  final bool carried;
  // 箭头对准下一段第一列（那一段并排不止一关时，指明门在哪一关前）。
  final bool aim;
}

// 把关卡图排成一段段（每关只有一条出边）：按收碎片的关的串联深度排，同深度按模板顺序；不给也不收碎片的关（模板里没有边时）先放一段。
// 收碎片的关紧接着给下一段碎片时不单独画，排进下一段那一行的第一个，箭头对准它；隔着几段才用到的只在箭头上写字母，不再画一张。加试题不在这里。
List<ChallengeSection> challengeSections(ChallengeRun run) {
  final levels = [for (final level in run.levels) if (level.extraOf == null) level];
  final depth = <String, int>{};
  int depthOf(ChallengeLevel level) => depth[level.id] ??= level.inputs.isEmpty ? 0 : 1 + level.inputs.map((id) => depthOf(run.level(id))).reduce((left, right) => left > right ? left : right);
  final consumers = [for (final level in levels) if (level.inputs.isNotEmpty) level]..sort((left, right) => depthOf(left).compareTo(depthOf(right)));
  final loose = [for (final level in levels) if (level.inputs.isEmpty && level.output == null) level];
  final rows = [
    for (final (index, consumer) in consumers.indexed)
      [
        if (index > 0 && consumer.inputs.contains(consumers[index - 1].id)) consumers[index - 1],
        for (final id in consumer.inputs) if (!consumers.any((other) => other.id == id)) run.level(id),
      ],
  ];
  return [
    if (loose.isNotEmpty) ChallengeSection(inputs: loose, sources: const [], consumer: null, carried: false, aim: false),
    for (final (index, consumer) in consumers.indexed)
      () {
        final carried = index + 1 < consumers.length && rows[index + 1].firstOrNull == consumer;
        return ChallengeSection(
          inputs: rows[index],
          sources: [for (final id in consumer.inputs) run.level(id)],
          consumer: consumer,
          carried: carried,
          aim: carried && rows[index + 1].length > 1,
        );
      }(),
  ];
}

class _Section extends StatelessWidget {
  const _Section({required this.section, required this.run, required this.games, required this.running, required this.onTap});
  final ChallengeSection section;
  final ChallengeRun run;
  final List<PlaygroundGame> games;
  final bool running;
  final ValueChanged<ChallengeLevel> onTap;

  @override
  Widget build(BuildContext context) {
    final consumer = section.consumer;
    final letters = [for (final level in section.sources) level.letter];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (section.inputs.isNotEmpty) _TileGrid(levels: section.inputs, run: run, games: games, running: running, onTap: onTap),
      if (consumer != null) ...[
        LayoutBuilder(builder: (context, constraints) {
          final arrow = _Arrow(label: letters.join(consumer.gate!.product ? ' × ' : ' + '), value: consumer.gate!.value);
          if (!section.aim) return arrow;
          // 对准下一段第一列的中线（同 _TileGrid 的列宽）。
          final columns = constraints.maxWidth >= 600 ? 3 : 2;
          final column = (constraints.maxWidth - 8 * (columns - 1)) / columns;
          return Align(alignment: Alignment.centerLeft, child: SizedBox(width: column, child: arrow));
        }),
        if (!section.carried) _LevelTile(level: consumer, game: games.where((game) => game.id == consumer.game).firstOrNull, running: running, onTap: () => onTap(consumer)),
      ],
    ]);
  }
}

// 一段里并排的几关：手机上两列，宽屏放得下三列就三列。前面段里已经画过的（收碎片的关又给别的关碎片）同样画一张，点了一样能进。
class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.levels, required this.run, required this.games, required this.running, required this.onTap});
  final List<ChallengeLevel> levels;
  final ChallengeRun run;
  final List<PlaygroundGame> games;
  final bool running;
  final ValueChanged<ChallengeLevel> onTap;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final columns = levels.length == 1 ? 1 : constraints.maxWidth >= 600 ? 3 : 2;
    final width = (constraints.maxWidth - 8 * (columns - 1)) / columns;
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final level in levels)
        SizedBox(width: width, child: _LevelTile(level: level, game: games.where((game) => game.id == level.game).firstOrNull, running: running, onTap: () => onTap(level))),
    ]);
  });
}

// 箭头：门上的数怎么来（开了门写出门上的数）。
class _Arrow extends StatelessWidget {
  const _Arrow({required this.label, this.value});
  final String label;
  final int? value;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      CampusIcon(CampusIcons.arrowDown, size: 18, color: palette.onSurfaceVariant),
      const SizedBox(width: 6),
      Flexible(child: Text(value == null ? label : '$label = $value', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant))),
    ]));
  }
}

// 一关：档位色调的字母徽章、游戏名、状态图标（锁着、门前、开着、过了、没过）。
class _LevelTile extends StatelessWidget {
  const _LevelTile({required this.level, required this.game, required this.running, required this.onTap});
  final ChallengeLevel level;
  final PlaygroundGame? game;
  final bool running;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final tier = PuzzleTier.named(level.tier) ?? PuzzleTier.entry;
    final color = playTierColor(palette, tier);
    final active = running && (level.state == ChallengeLevelState.open || level.state == ChallengeLevelState.gated);
    final (icon, status) = switch (level.state) {
      ChallengeLevelState.open => (CampusIcons.next, running ? '进入' : '没做完'),
      ChallengeLevelState.gated => (CampusIcons.key, '开门'),
      ChallengeLevelState.solved => (CampusIcons.success, '过了'),
      ChallengeLevelState.failed => (CampusIcons.failed, '没过'),
      ChallengeLevelState.locked => (CampusIcons.locked, '锁着'),
    };
    return Semantics(
      button: running && level.state != ChallengeLevelState.locked && level.state != ChallengeLevelState.failed,
      label: '${challengeLevelName(level)}，${game?.name ?? level.game}，${tier.label}，$status',
      excludeSemantics: true,
      child: CampusSurface(
        onTap: running ? onTap : null,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Row(children: [
          SizedBox.square(dimension: 36, child: DecoratedBox(
            decoration: BoxDecoration(color: color.withValues(alpha: .18), shape: BoxShape.circle),
            child: Center(child: Text(level.letter ?? '+', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: palette.onSurface))),
          )),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(game?.name ?? level.game, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
            Row(children: [PlayTierDot(tier, size: 8), const SizedBox(width: 6), Flexible(child: Text(tier.label, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)))]),
          ])),
          CampusIcon(icon, size: 22, color: active ? palette.primary : palette.onSurfaceVariant),
        ]),
      ),
    );
  }
}

class _FinalTile extends StatelessWidget {
  const _FinalTile({required this.state, required this.running, required this.onTap});
  final ChallengeFinal state;
  final bool running;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final ready = running && state == ChallengeFinal.ready;
    return CampusSurface(
      onTap: ready ? onTap : null,
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        CampusIcon(CampusIcons.trophy, size: 28, color: ready ? palette.primary : palette.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(child: Text('终章', style: Theme.of(context).textTheme.titleMedium)),
        CampusIcon(switch (state) { ChallengeFinal.cleared => CampusIcons.success, ChallengeFinal.ready => CampusIcons.key, ChallengeFinal.locked => CampusIcons.locked }, size: 22, color: ready ? palette.primary : palette.onSurfaceVariant),
      ]),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result, required this.solved, required this.total});
  final ChallengeResult result;
  final int solved, total;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final title = switch (result.ending) {
      'cleared' => '全部过关',
      'timeout' => '时间到了',
      'stuck' => '剩下的关开不了了',
      _ => '这一局结束了',
    };
    return CampusSurface(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        CampusIcon(result.ending == 'cleared' ? CampusIcons.trophy : CampusIcons.flag, size: 28, color: palette.accentText),
        const SizedBox(width: 12),
        Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
      ]),
      const SizedBox(height: 12),
      Text('${result.points} 分', style: TextStyle(fontSize: 36, fontWeight: FontWeight.w600, height: 1.15, color: palette.onSurface)),
      const SizedBox(height: 4),
      DotSeparatedText(['过了 $solved/$total 关', result.awarded > 0 ? '积分 +${result.awarded}' : '未超过最好成绩'].join(' · '), style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
    ]));
  }
}

// 数字键盘弹层（门上的数、终章的最终密码）：点数字输入（能点就不让手打），确认交服务器；错了原地写扣了时间、清空再输，对了关掉返回 true。
Future<bool> showChallengeKeypad(BuildContext context, {required String title, required String hint, required Future<bool> Function(int value) submit}) async {
  var entered = '';
  String? message;
  var busy = false;
  final opened = await showCampusSheet<bool>(context: context, builder: (context) => StatefulBuilder(builder: (context, setState) {
    final palette = CampusPalette.of(context);
    Future<void> confirm() async {
      final value = int.tryParse(entered);
      if (value == null || busy) return;
      setState(() => busy = true);
      try {
        if (await submit(value)) {
          if (context.mounted) Navigator.pop(context, true);
          return;
        }
        unawaited(HapticFeedback.heavyImpact());
        setState(() {
          entered = '';
          message = '不对 · 扣 20 秒';
        });
      } on ChallengeException catch (error) {
        setState(() => message = error.message);
      } finally {
        if (context.mounted) setState(() => busy = false);
      }
    }

    Widget key(String label, VoidCallback? onPressed, {IconData? icon}) => SizedBox(height: 56, child: FilledButton.tonal(
      onPressed: busy ? null : onPressed,
      child: icon == null ? Text(label, style: const TextStyle(fontSize: 20, fontFeatures: [FontFeature.tabularFigures()])) : Semantics(label: label, child: CampusIcon(icon)),
    ));

    return CampusSheetPanel(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 4),
      Text(hint, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
      const SizedBox(height: 16),
      Text(entered.isEmpty ? ' ' : entered, textAlign: TextAlign.center, style: TextStyle(fontSize: 36, fontWeight: FontWeight.w600, color: palette.onSurface, fontFeatures: const [FontFeature.tabularFigures()])),
      SizedBox(height: 24, child: Center(child: Text(message ?? '', style: TextStyle(fontSize: 14, color: palette.danger)))),
      const SizedBox(height: 8),
      GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 2.2,
        children: [
          for (final digit in ['1', '2', '3', '4', '5', '6', '7', '8', '9']) key(digit, entered.length < 8 ? () => setState(() => entered += digit) : null),
          key('退格', entered.isEmpty ? null : () => setState(() => entered = entered.substring(0, entered.length - 1)), icon: CampusIcons.backspace),
          key('0', entered.length < 8 && entered.isNotEmpty ? () => setState(() => entered += '0') : null),
          key('确认', entered.isEmpty ? null : () => unawaited(confirm()), icon: CampusIcons.check),
        ],
      ),
    ])));
  }));
  return opened ?? false;
}
