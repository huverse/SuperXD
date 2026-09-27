import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/page/shell_page.dart';
import 'package:superxd/theme/campus_theme.dart';

Future<void> _mount(WidgetTester tester, List<int> changes, {bool rtl = false}) async {
  var selected = 0;
  await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: Directionality(textDirection: rtl ? TextDirection.rtl : TextDirection.ltr, child: Scaffold(body: StatefulBuilder(builder: (context, setState) => Align(alignment: Alignment.bottomCenter, child: DragNavigationBar(selected: selected, onSelected: (index) {changes.add(index);setState(() => selected = index);})))))));
  await tester.pumpAndSettle();
}
Finder get _capsule => find.byKey(const ValueKey('navigation-capsule'));

void main() {
  testWidgets('底栏连续跟手，栏外静止不复位，栏外抬手选最近模块', (tester) async {
    final changes = <int>[];await _mount(tester, changes);
    final first = tester.getCenter(find.text('今天')), second = tester.getCenter(find.text('服务'));
    final gesture = await tester.startGesture(first);
    await gesture.moveTo(Offset(first.dx + 30, first.dy - 120));await tester.pump();
    final targetX = first.dx + (second.dx - first.dx) * .68;
    await gesture.moveTo(Offset(targetX, first.dy - 200));await tester.pump();
    expect(tester.getCenter(_capsule).dx, closeTo(targetX, .1));expect(changes, isEmpty);
    await tester.pump(const Duration(seconds: 1));expect(tester.getCenter(_capsule).dx, closeTo(targetX, .1));
    await gesture.up();await tester.pump();
    expect(changes, [1]);expect(tester.getCenter(_capsule).dx, closeTo(targetX, .1));
    await tester.pump(const Duration(milliseconds: 90));
    final middle = tester.getCenter(_capsule).dx;
    expect(middle, greaterThan(targetX));expect(middle, lessThan(second.dx));
    await tester.pumpAndSettle();expect(tester.getCenter(_capsule).dx, closeTo(second.dx, .1));expect(changes,[1]);
  });

  testWidgets('取消不同于栏外松手，第二个指针不能结束第一指针拖动', (tester) async {
    final changes = <int>[];await _mount(tester, changes);
    final start = tester.getCenter(find.text('今天')), end = tester.getCenter(find.text('我的'));
    final drag = await tester.startGesture(start, pointer: 1);
    await drag.moveTo(Offset(end.dx, end.dy - 100));await tester.pump();
    final second = await tester.startGesture(tester.getCenter(find.text('服务')), pointer: 2);
    await second.up();await tester.pump();
    expect(changes, isEmpty);expect(tester.getCenter(_capsule).dx, closeTo(end.dx,.1));
    await drag.cancel();await tester.pumpAndSettle();expect(changes,isEmpty);expect(tester.getCenter(_capsule).dx,closeTo(start.dx,.1));
  });

  testWidgets('左右超界钳制，底栏下方松手同样提交，不重复提交当前模块', (tester) async {
    final changes=<int>[];await _mount(tester,changes);
    var drag=await tester.startGesture(tester.getCenter(find.text('今天')));
    await drag.moveTo(const Offset(1000,650));await tester.pump();
    expect(tester.getCenter(_capsule).dx,closeTo(tester.getCenter(find.text('我的')).dx,.1));
    await drag.up();await tester.pumpAndSettle();expect(changes,[3]);
    drag=await tester.startGesture(tester.getCenter(find.text('我的')));
    await drag.moveTo(const Offset(1100,650));await drag.up();await tester.pumpAndSettle();expect(changes,[3]);
    drag=await tester.startGesture(tester.getCenter(find.text('我的')));
    await drag.moveTo(const Offset(-100,650));await drag.up();await tester.pumpAndSettle();expect(changes,[3,0]);
  });

  testWidgets('RTL位置与模块对应且快速重拖不回跳已选槽位', (tester) async {
    final changes=<int>[];await _mount(tester,changes,rtl:true);
    final first=tester.getCenter(find.text('今天')), last=tester.getCenter(find.text('我的'));
    expect(tester.getCenter(_capsule).dx,closeTo(first.dx,.1));
    final drag=await tester.startGesture(first);await drag.moveTo(Offset(last.dx+25,last.dy-100));await drag.up();await tester.pump(const Duration(milliseconds:40));
    final position=tester.getCenter(_capsule);
    final next=await tester.startGesture(position);await tester.pump();expect(tester.getCenter(_capsule).dx,closeTo(position.dx,.1));
    await next.moveTo(Offset(first.dx,first.dy-100));await tester.pump();await next.up();await tester.pumpAndSettle();expect(changes,[3,0]);
  });
}
