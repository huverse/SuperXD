import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/theme/campus_animated_list.dart';
import 'package:superxd/theme/campus_prose.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_anchor.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

void main() {
  testWidgets('长说明：编号与正文两列悬挂缩进，段内小标题与小节标题半粗', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: const Scaffold(body: SizedBox(width: 200, child: CampusProse('本机：\n1. 课表、成绩主要存在本机，教务账号只发给学校教务系统。\n登录：账号、密码直接发给学校。\n点「同意」即表示同意。')))));
    // 编号单独一列，正文折行后仍从正文左缘起，不回到编号下面。
    final number = tester.getRect(find.text('1. '));
    final body = tester.getRect(find.text('课表、成绩主要存在本机，教务账号只发给学校教务系统。'));
    expect(body.left, greaterThan(number.right - 1));
    expect(body.height, greaterThan(number.height * 1.5));
    expect(tester.widget<Text>(find.text('本机：')).style!.fontWeight, FontWeight.w600);
    final labelled = tester.widget<Text>(find.byWidgetPredicate((widget) => widget is Text && widget.textSpan?.toPlainText() == '登录：账号、密码直接发给学校。'));
    expect((labelled.textSpan! as TextSpan).children!.first.style!.fontWeight, FontWeight.w600);
    // 普通句子里的冒号（前面带逗号、句号）不当小标题。
    expect(tester.widget<Text>(find.text('点「同意」即表示同意。')).style!.fontWeight, isNot(FontWeight.w600));
  });

  testWidgets('列表增删：第一次不动画，新条目展开，去掉的条目原地收起后才移除', (tester) async {
    Widget list(List<String> items) => MaterialApp(home: Scaffold(body: CampusAnimatedColumn(children: [for (final item in items) SizedBox(key: ValueKey(item), height: 40, child: Text(item))])));
    await tester.pumpWidget(list(['甲', '乙']));
    expect(tester.getSize(find.byType(CampusAnimatedColumn)).height, 80);
    await tester.pumpWidget(list(['甲', '乙', '丙']));
    await tester.pump(const Duration(milliseconds: 100));
    final growing = tester.getSize(find.byType(CampusAnimatedColumn)).height;
    expect(growing, inExclusiveRange(80, 120));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(CampusAnimatedColumn)).height, 120);
    await tester.pumpWidget(list(['甲', '丙']));
    await tester.pump(const Duration(milliseconds: 100));
    // 收起途中「乙」还在原位，排在甲和丙之间。
    expect(find.text('乙'), findsOneWidget);
    expect(tester.getTopLeft(find.text('乙')).dy, lessThan(tester.getTopLeft(find.text('丙')).dy));
    await tester.pumpAndSettle();
    expect(find.text('乙'), findsNothing);
    expect(tester.getSize(find.byType(CampusAnimatedColumn)).height, 80);
  });

  testWidgets('列表过渡不改条目的横向排布：按内容收窄的条目照旧靠左、靠右，展开途中也不被居中', (tester) async {
    Widget item(CrossAxisAlignment alignment, String label) => Column(crossAxisAlignment: alignment, children: [SizedBox(width: 100, height: 20, child: Text(label))]);
    Widget list(List<String> items) => MaterialApp(home: Align(alignment: Alignment.topLeft, child: SizedBox(width: 400, height: 300, child: ListView(children: [
      CampusAppear(animate: false, child: item(CrossAxisAlignment.start, '左')),
      CampusAppear(animate: true, child: item(CrossAxisAlignment.end, '右')),
      CampusAnimatedColumn(children: [for (final label in items) KeyedSubtree(key: ValueKey(label), child: item(CrossAxisAlignment.end, label))]),
    ]))));
    await tester.pumpWidget(list(['甲']));
    await tester.pumpWidget(list(['甲', '乙']));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getTopLeft(find.text('左')).dx, 0);
    expect(tester.getTopRight(find.text('右')).dx, 400);
    expect(tester.getTopRight(find.text('甲')).dx, 400);
    expect(tester.getTopRight(find.text('乙')).dx, 400);
    await tester.pumpAndSettle();
    expect(tester.getTopRight(find.text('右')).dx, 400);
  });

  testWidgets('滚动边缘渐隐：正序列表滚过上缘才渐隐，倒序列表（最新在下）打开时上方已有内容就渐隐', (tester) async {
    double top() => tester.widget<ScrollEdgeFade>(find.byType(ScrollEdgeFade)).top;
    Widget list({required bool reverse}) => MaterialApp(home: Scaffold(body: CampusScrollFade(child: ListView(reverse: reverse, children: [for (var index = 0; index < 40; index++) SizedBox(height: 60, child: Text('第$index行'))]))));
    await tester.pumpWidget(list(reverse: false));
    await tester.pump();
    expect(top(), 0);
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pump();
    expect(top(), 24);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(list(reverse: true));
    await tester.pump();
    expect(top(), 24, reason: '倒序列表停在最新处，上面还有更早的内容');
    // 滚到最早一条（视觉上缘）就不再渐隐。
    await tester.drag(find.byType(ListView), const Offset(0, 4000));
    await tester.pumpAndSettle();
    expect(top(), 0);
  });

  testWidgets('滚动锚定：锚点上方变高变矮时锚点停在原位；放开后或有别的滚动时不再拉回', (tester) async {
    final controller = CampusAnchoredScrollController();
    addTearDown(controller.dispose);
    final anchor = GlobalKey();
    var above = 300.0;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return ListView(controller: controller, children: [
        SizedBox(height: above),
        SizedBox(key: anchor, height: 60),
        const SizedBox(height: 2000),
      ]);
    }))));
    controller.jumpTo(200);
    await tester.pump();
    final before = tester.getTopLeft(find.byKey(anchor)).dy;
    controller.hold(anchor, const Duration(seconds: 1));
    for (final height in [280.0, 240.0, 330.0]) {
      update(() => above = height);
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(anchor)).dy, closeTo(before, .5));
    }
    // 锚定期间代码发起的滚动照常滚到位，不被拉回。
    controller.animateTo(500, duration: const Duration(milliseconds: 100), curve: Curves.linear);
    await tester.pumpAndSettle();
    expect(controller.offset, 500);
    update(() => above = 200);
    await tester.pump();
    expect(controller.offset, 500, reason: '放开后照常排版，不再按锚点校正');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('底部弹层挂根导航器：从嵌套导航器里打开也盖住外层，返回键先关弹层', (tester) async {
    final root = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: root, theme: campusTheme(), home: Scaffold(body: Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (context) => Center(child: TextButton(
      onPressed: () => showCampusSheet<void>(context: context, builder: (_) => const CampusSheetPanel(child: Text('弹层内容'))),
      child: const Text('打开'),
    )))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(tester.state<NavigatorState>(find.ancestor(of: find.text('弹层内容'), matching: find.byType(Navigator)).first), root.currentState);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('弹层内容'), findsNothing);
    expect(find.text('打开'), findsOneWidget);
  });
}
