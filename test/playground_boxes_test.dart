import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/play_controls.dart';
import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/boxes/boxes_page.dart';
import 'package:superxd/playground/puzzle/boxes/boxes_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';

const _rules = BoxesRules();

// 手搭的一条走廊：外圈是墙，里面一行 5 格（格号 8–12）：小人、箱子、空、空、目标点。
BoxesPuzzle _corridor({List<int> boxes = const [9], List<int> goals = const [12]}) {
  const width = 7, height = 3;
  return BoxesPuzzle(width: width, height: height, walls: [for (var cell = 0; cell < width * height; cell++) cell < width || cell >= width * 2 || cell % width == 0 || cell % width == width - 1], goals: goals, boxes: boxes, player: 8);
}

// 每档最少推数的区间（同规则文件里的 _tiers）与难度分段。
const _least = {PuzzleTier.entry: (4, 8), PuzzleTier.easy: (9, 13), PuzzleTier.normal: (14, 19), PuzzleTier.hard: (20, 26), PuzzleTier.expert: (27, 40)};
const _scores = {PuzzleTier.entry: (1, 2), PuzzleTier.easy: (3, 3), PuzzleTier.normal: (4, 5), PuzzleTier.hard: (6, 7), PuzzleTier.expert: (8, 10)};

const _verbs = {playUp: '向上走', playRight: '向右走', playDown: '向下走', playLeft: '向左走'};

Future<void> _frames(WidgetTester tester, int millis) async {
  for (var elapsed = 0; elapsed < millis; elapsed += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Finder _status(int pushes) => find.textContaining('推 $pushes 次');

void main() {
  group('推箱子规则', () {
    test('走一步：推得动推一格、前面是墙或另一个箱子推不动、撞墙原地', () {
      final puzzle = _corridor();
      expect(boxesStep(puzzle, [9], 8, playRight), (to: 9, box: 0));
      expect(boxesStep(puzzle, [9], 8, playUp), isNull);
      expect(boxesStep(puzzle, [9], 8, playLeft), isNull);
      expect(boxesStep(puzzle, [12], 11, playRight), isNull);
      expect(boxesStep(puzzle, [9, 10], 8, playRight), isNull);
      // 三推到位；中途撞墙的步原地不动、不算违规。
      final replay = boxesReplay(puzzle, [playRight, playUp, playRight, playRight]);
      expect((replay.player, replay.pushes), (11, 3));
      expect(replay.boxes, [12]);
      expect(_rules.solved(puzzle, [playRight, playUp, playRight, playRight]), isTrue);
      // 推到位以后又走开不影响（看的是最后箱子在不在目标点上）；推过头推不动。
      expect(_rules.solved(puzzle, [playRight, playRight, playRight, playRight, playLeft]), isTrue);
      expect(_rules.solved(puzzle, [playRight, playRight]), isFalse);
      expect(_rules.solved(puzzle, List.filled(boxesMaxMoves + 1, playRight)), isFalse);
    });

    test('每档出的题：参考解解得开、推数在区间里且就是最少、难度分段不重叠、出题快', () {
      final watch = Stopwatch()..start();
      for (final tier in PuzzleTier.values) {
        final (low, high) = _least[tier]!;
        final (lowScore, highScore) = _scores[tier]!;
        for (var seed = 0; seed < 20; seed++) {
          final draw = _rules.generate(seed, tier);
          final puzzle = draw.puzzle;
          expect(_rules.solved(puzzle, draw.solution), isTrue, reason: '$tier $seed');
          expect(_rules.solved(puzzle, const []), isFalse);
          final pushes = boxesReplay(puzzle, draw.solution).pushes;
          expect(pushes, inInclusiveRange(low, high), reason: '$tier $seed');
          expect(boxesSolve(puzzle)!.pushes, pushes, reason: '$tier $seed 参考解应当是最少推数');
          expect(_rules.difficulty(puzzle), inInclusiveRange(lowScore, highScore), reason: '$tier $seed');
        }
      }
      expect(_rules.generate(5, PuzzleTier.hard).puzzle.boxes, _rules.generate(5, PuzzleTier.hard).puzzle.boxes);
      expect(watch.elapsedMilliseconds, lessThan(6000));
    });

    test('编解码往返，坏输入抛 FormatException', () {
      for (final tier in PuzzleTier.values) {
        final draw = _rules.generate(11, tier);
        final puzzle = _rules.decodePuzzle(jsonDecode(jsonEncode(_rules.encodePuzzle(draw.puzzle))));
        expect(_rules.encodePuzzle(puzzle), _rules.encodePuzzle(draw.puzzle));
        expect(_rules.solved(puzzle, _rules.decodeAnswer(jsonDecode(jsonEncode(_rules.encodeAnswer(draw.solution))))), isTrue);
      }
      final good = _rules.encodePuzzle(_corridor()) as Map<String, Object?>;
      expect(_rules.decodePuzzle(good).boxes, [9]);
      for (final bad in <Object?>[
        null,
        {...good, 'width': 2},
        {...good, 'walls': '01'},
        {...good, 'walls': (good['walls']! as String).replaceFirst('0', '2')},
        {...good, 'boxes': <int>[]},
        {...good, 'boxes': [9, 10]},
        {...good, 'boxes': [9, 9], 'goals': [11, 12]},
        {...good, 'boxes': [0]},
        {...good, 'goals': [99]},
        {...good, 'player': 9},
        {...good, 'player': 0},
        {...good, 'boxes': [12]},
      ]) {
        expect(() => _rules.decodePuzzle(bad), throwsFormatException, reason: '$bad');
      }
      for (final bad in <Object?>['0', [4], [-1], List.filled(boxesMaxMoves + 1, 0)]) {
        expect(() => _rules.decodeAnswer(bad), throwsFormatException, reason: '$bad');
      }
    });
  });

  group('推箱子对局页', () {
    Future<BoxesPuzzle> open(WidgetTester tester, int seed, {GlobalKey<NavigatorState>? navigator}) async {
      final game = playgroundCatalog.firstWhere((game) => game.id == 'boxes');
      final page = BoxesPage(game: game, store: PlaygroundStore.memory(), seeds: () => seed);
      if (navigator == null) {
        await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: page));
      } else {
        await tester.pumpWidget(MaterialApp(theme: campusTheme(), navigatorKey: navigator, home: const SizedBox.expand(child: Text('上一页'))));
        unawaited(navigator.currentState!.push(CampusPageRoute<void>(builder: (_) => page)));
      }
      await tester.pumpAndSettle();
      return _rules.generate(seed, PuzzleTier.entry).puzzle;
    }

    testWidgets('方向键：撞墙不算一步；按参考解走完，推数正好最少，弹新纪录', (tester) async {
      final puzzle = await open(tester, 1);
      final solution = _rules.generate(1, PuzzleTier.entry).solution;
      final least = boxesReplay(puzzle, solution).pushes;
      expect(find.textContaining('最少 $least 次'), findsOneWidget);
      // 找一个开局就走不动的方向：轻震，推数与撤销都不变。
      final blocked = [playUp, playRight, playDown, playLeft].firstWhere((direction) => boxesStep(puzzle, puzzle.boxes, puzzle.player, direction) == null);
      await tester.tap(find.byTooltip(_verbs[blocked]!));
      await _frames(tester, 300);
      expect(_status(0), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '撤销')).onPressed, isNull);

      for (final direction in solution) {
        await tester.tap(find.byTooltip(_verbs[direction]!));
        await _frames(tester, 140);
      }
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      expect(find.textContaining('推 $least 次，正好最少'), findsOneWidget);
    });

    testWidgets('在棋盘上滑一下走一格，推了箱子能撤销退回', (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester, 2);
      final solution = _rules.generate(2, PuzzleTier.entry).solution;
      const swipes = {playUp: Offset(0, -60), playRight: Offset(60, 0), playDown: Offset(0, 60), playLeft: Offset(-60, 0)};
      final board = tester.getCenter(find.bySemanticsLabel(RegExp('^房间')));
      // 沿参考解用滑动走，走到第一次推箱子为止。
      for (final direction in solution) {
        await tester.dragFrom(board, swipes[direction]!);
        await _frames(tester, 160);
        if (_status(1).evaluate().isNotEmpty) break;
      }
      expect(_status(1), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _frames(tester, 200);
      expect(_status(0), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('iOS 上棋盘里横滑走一格，不触发页面右滑返回', (tester) async {
      final semantics = tester.ensureSemantics();
      final navigator = GlobalKey<NavigatorState>();
      final puzzle = await open(tester, 3, navigator: navigator);
      final board = tester.getCenter(find.bySemanticsLabel(RegExp('^房间')));
      final direction = [playRight, playLeft].firstWhere((direction) => boxesStep(puzzle, puzzle.boxes, puzzle.player, direction) != null, orElse: () => playRight);
      final gesture = await tester.startGesture(board);
      for (var step = 0; step < 8; step++) {
        await gesture.moveBy(Offset(direction == playRight ? 12 : -12, 0));
        await tester.pump();
        expect(navigator.currentState!.userGestureInProgress, isFalse);
      }
      await gesture.up();
      await _frames(tester, 300);
      expect(find.byType(BoxesPage), findsOneWidget);
      expect(tester.getTopLeft(find.byType(BoxesPage)).dx, 0);
      semantics.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });
}
