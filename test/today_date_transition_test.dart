import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/page/today_date_transition.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_theme.dart';

Finder _frame(String date) => find.byKey(ValueKey('today-frame-$date'));
double _offset(WidgetTester tester, String date) => tester.widget<Transform>(find.byKey(ValueKey('today-offset-$date'))).transform.getTranslation().y;
double _opacity(WidgetTester tester, String date) => tester.widget<FadeTransition>(find.descendant(of: _frame(date), matching: find.byType(FadeTransition)).first).opacity.value;

Future<void> _mount(WidgetTester tester, List<String> commits, {bool emptyFrom = false, bool emptyTo = true, bool reduced = false}) async {
  var date = '2026-09-25';
  await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: MediaQuery(data: MediaQueryData(disableAnimations: reduced), child: CampusMotion(child: StatefulBuilder(builder: (context, setState) => TodayDateTransition(
    date: date, revision: 0, recenter: 0, canSelect: (value) => value.compareTo('2026-09-24') >= 0 && value.compareTo('2026-09-26') <= 0,
    onCommit: (value) { commits.add(value);setState(() => date = value); },
    frameBuilder: (value) {
      final empty = value == '2026-09-25' ? emptyFrom : emptyTo;
      return TodayDateFrame(scrollable: false, header: Text(value), body: empty ? const Center(child: Text('这天没课')) : const Column(children: [Card(child: SizedBox(height: 180, width: 300, child: Text('课程')))]));
    },
    builder: (context, header, body, preview) => Column(children: [SizedBox(height: 60, child: header), Expanded(child: body)]),
  ))))));
  await tester.pumpAndSettle();
}

Future<TestGesture> _drag(WidgetTester tester, double distance) async {
  final gesture = await tester.startGesture(const Offset(400, 30));
  await gesture.moveBy(Offset(0,distance.sign*24)); await tester.pump();
  await gesture.moveBy(Offset(0,distance)); await tester.pump();return gesture;
}

void main() {
  for(final emptyFrom in [false,true]) {
    for(final emptyTo in [false,true]) {
      for(final step in [-1,1]) {
        testWidgets('页面直接交接 fromEmpty=$emptyFrom toEmpty=$emptyTo direction=$step', (tester) async {
          final commits=<String>[];await _mount(tester,commits,emptyFrom:emptyFrom,emptyTo:emptyTo);
          final target=step==1?'2026-09-26':'2026-09-24';
          final gesture=await _drag(tester,-step*32);
          expect(commits,isEmpty);expect(_frame(target),findsOneWidget);
          expect(_offset(tester,'2026-09-25')*step,lessThan(0));expect(_offset(tester,target)*step,greaterThan(0));
          final position=_offset(tester,'2026-09-25');final alpha=_opacity(tester,'2026-09-25');
          await gesture.moveBy(Offset(0,-step*20));await tester.pump();
          expect(_offset(tester,'2026-09-25').abs(),greaterThan(position.abs()));expect(_opacity(tester,'2026-09-25'),lessThan(alpha));
          final releasePosition=_offset(tester,'2026-09-25'), releaseAlpha=_opacity(tester,'2026-09-25');
          await gesture.up();await tester.pump();
          expect(commits,[target]);
          expect(_offset(tester,'2026-09-25'),closeTo(releasePosition,.01));
          expect(_opacity(tester,'2026-09-25'),closeTo(releaseAlpha,.01));
          await tester.pump(const Duration(milliseconds:32));expect(_offset(tester,'2026-09-25').abs(),greaterThan(releasePosition.abs()));
          await tester.pumpAndSettle();expect(_frame('2026-09-25'),findsNothing);expect(_opacity(tester,target),1);expect(_offset(tester,target),0);expect(tester.takeException(),isNull);
        });
      }
    }
  }
  testWidgets('主要可见阶段错开，白卡与空日正文不同时强重叠', (tester) async {
    final commits=<String>[];await _mount(tester,commits);
    final gesture=await tester.startGesture(const Offset(400,30));
    await gesture.moveBy(const Offset(0,-24));await tester.pump();
    for(var index=0;index<12;index++) {
      await gesture.moveBy(const Offset(0,-8));await tester.pump();
      if(_frame('2026-09-26').evaluate().isNotEmpty) {
        final outgoing=_opacity(tester,'2026-09-25'),incoming=_opacity(tester,'2026-09-26');
        expect(outgoing > .25 && incoming > .25,isFalse);
      }
    }
    await gesture.up();await tester.pumpAndSettle();expect(commits,['2026-09-26']);
  });

  testWidgets('预览取消同程退回且静止无ticker', (tester) async {
    final commits=<String>[];await _mount(tester,commits);
    final gesture=await _drag(tester,-50);final before=_offset(tester,'2026-09-25');
    await gesture.cancel();await tester.pump();expect(_offset(tester,'2026-09-25'),before);
    await tester.pump(const Duration(milliseconds:32));expect(_offset(tester,'2026-09-25'),greaterThan(before));
    await tester.pumpAndSettle();expect(_frame('2026-09-26'),findsNothing);expect(commits,isEmpty);expect(_offset(tester,'2026-09-25'),0);expect(tester.binding.hasScheduledFrame,isFalse);
  });
  testWidgets('取消动画被新手势打断，从当前页面进度续接不跳归零', (tester) async {
    final commits=<String>[];await _mount(tester,commits);
    var gesture=await _drag(tester,-45);await gesture.cancel();await tester.pump();await tester.pump(const Duration(milliseconds:20));
    final position=_offset(tester,'2026-09-25');
    gesture=await tester.startGesture(const Offset(400,30));await gesture.moveBy(const Offset(0,-24));await tester.pump();
    expect(_offset(tester,'2026-09-25'),lessThanOrEqualTo(position));
    await gesture.moveBy(const Offset(0,-80));await tester.pump();await gesture.up();await tester.pumpAndSettle();
    expect(commits,['2026-09-26']);expect(_frame('2026-09-25'),findsNothing);
  });

  testWidgets('边界无伪造候选，松手沿当前位置回位', (tester) async {
    final commits=<String>[];await _mount(tester,commits);
    var gesture=await _drag(tester,-90);await gesture.up();await tester.pumpAndSettle();
    gesture=await _drag(tester,-100);expect(_frame('2026-09-27'),findsNothing);
    final position=_offset(tester,'2026-09-26');expect(position,lessThan(0));
    await gesture.up();await tester.pump();expect(_offset(tester,'2026-09-26'),closeTo(position,.01));
    await tester.pumpAndSettle();expect(_offset(tester,'2026-09-26'),0);expect(commits,['2026-09-26']);
  });

  testWidgets('减少动画取消不选日，提交直接定位', (tester) async {
    final commits=<String>[];await _mount(tester,commits,reduced:true);
    var gesture=await _drag(tester,-20);await gesture.up();await tester.pumpAndSettle();expect(commits,isEmpty);
    gesture=await _drag(tester,80);await gesture.up();await tester.pumpAndSettle();expect(commits,['2026-09-24']);expect(_frame('2026-09-25'),findsNothing);
  });
}
