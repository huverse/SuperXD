import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:superxd/domain/painting.dart';
import 'package:superxd/local/painting_library.dart';
import 'package:superxd/page/about_page.dart';
import 'package:superxd/page/painting_splash.dart';
import 'package:superxd/page/paintings_page.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/dot_separated_text.dart';

final _png = Uint8List.fromList(img.encodePng(img.Image(width: 16, height: 9)..clear(img.ColorRgb8(120, 140, 180))));

const _painting = Painting(id: 'a', title: '合成画作', note: '测试说明', asset: 'assets/paintings/misty_sunrise.jpg', width: 16, height: 9, focus: .5, horizon: [0xFF8899AA, 0xFF99AABB], sky: 0xFFCCCCDD);
const _second = Painting(id: 'b', title: '合成第二幅', note: '测试说明', asset: 'assets/paintings/riverside_tree.jpg', width: 16, height: 16, focus: .5, horizon: [0xFF8899AA], sky: 0xFFCCCCDD);

// 记下应用建了几次：开屏溶解、从树上拿掉时下面的应用不能重建（不靠 GlobalKey，那个换了父节点也保留状态）。
class _Probe extends StatefulWidget {
  const _Probe();
  static var created = 0;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.created++;
  }

  @override
  Widget build(BuildContext context) => const MaterialApp(home: Scaffold(body: Text('应用')));
}

void main() {
  Widget splash(Future<void> ready, GlobalKey appKey) => PaintingSplash(
    painting: _painting,
    image: MemoryImage(_png),
    ready: ready,
    fontFamily: 'Maple Mono NF CN',
    shown: Future<void>.value(),
    child: const _Probe(),
  );
  // 开屏这层还接手势，就是还没开始溶解（溶解途中手指已能点到下面的页面）。
  bool leaving(WidgetTester tester) => tester.widget<IgnorePointer>(find.ancestor(of: find.text('SuperXD'), matching: find.byType(IgnorePointer)).first).ignoring;

  testWidgets('开屏：满 1.2 秒且恢复好账号、转场走完才溶解；溶解完从树上拿掉，下面的应用一直在、不重建', (tester) async {
    final ready = Completer<void>();
    _Probe.created = 0;
    await tester.pumpWidget(splash(ready.future, GlobalKey()));
    expect(find.text('SuperXD'), findsOneWidget);
    expect(find.text('《合成画作》'), findsOneWidget);
    expect(find.text('测试说明'), findsOneWidget);
    expect(find.text('应用'), findsOneWidget, reason: '应用在下面照常启动');
    await tester.pump(const Duration(milliseconds: 200));
    ready.complete();
    await tester.pump(const Duration(milliseconds: 900));
    expect(leaving(tester), isFalse, reason: '还没满 1.2 秒');
    await tester.pump(const Duration(milliseconds: 200));
    expect(leaving(tester), isTrue);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('SuperXD'), findsNothing);
    expect(find.text('应用'), findsOneWidget);
    expect(_Probe.created, 1);
  });

  testWidgets('开屏：账号恢复得慢就等恢复完再过转场的时间；点一下立即溶解', (tester) async {
    final ready = Completer<void>();
    await tester.pumpWidget(splash(ready.future, GlobalKey()));
    await tester.pump(const Duration(milliseconds: 1600));
    expect(leaving(tester), isFalse, reason: '满了 1.2 秒但还没恢复好');
    ready.complete();
    await tester.pump(const Duration(milliseconds: 300));
    expect(leaving(tester), isFalse, reason: '恢复好了还要等页面转场走完');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('SuperXD'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(splash(Completer<void>().future, GlobalKey()));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('SuperXD'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('SuperXD'), findsNothing);
    // 一直恢复不完也不卡在开屏：最多等几秒（这里已经点掉了，等计时器都走完）。
    await tester.pump(PaintingSplash.longest);
  });

  // 模拟器调试包实测：首帧上屏比建好晚约 2 秒，从建好起算的话开屏一出现就满了 1.2 秒、紧接着溶解。
  testWidgets('开屏：计时从第一帧真正上屏起，上屏之前不算；入场动画也等上屏才开始', (tester) async {
    final shown = Completer<void>();
    await tester.pumpWidget(PaintingSplash(painting: _painting, image: MemoryImage(_png), ready: Future<void>.value(), fontFamily: 'Maple Mono NF CN', shown: shown.future, child: const _Probe()));
    await tester.pump(const Duration(seconds: 3));
    expect(leaving(tester), isFalse, reason: '还没上屏，不算时长');
    expect(tester.widget<Opacity>(find.ancestor(of: find.text('SuperXD'), matching: find.byType(Opacity)).first).opacity, 0, reason: '入场动画还没开始');
    shown.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(leaving(tester), isFalse, reason: '上屏后还没满 1.2 秒');
    await tester.pump(const Duration(milliseconds: 200));
    expect(leaving(tester), isTrue);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('SuperXD'), findsNothing);
    await tester.pump(PaintingSplash.longest);
  });

  testWidgets('开屏：一直恢复不完时最多停几秒，之后照常溶解', (tester) async {
    await tester.pumpWidget(splash(Completer<void>().future, GlobalKey()));
    await tester.pump(PaintingSplash.longest - const Duration(milliseconds: 100));
    expect(leaving(tester), isFalse);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('SuperXD'), findsNothing);
  });

  testWidgets('开屏：减少动画时第一帧就是完整画面，不位移不缩放', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures.allOn;
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(splash(Completer<void>().future, GlobalKey()));
    final title = tester.widget<Opacity>(find.ancestor(of: find.text('SuperXD'), matching: find.byType(Opacity)).first);
    expect(title.opacity, 1);
    expect(find.descendant(of: find.byType(PaintingSplash), matching: find.byWidgetPredicate((widget) => widget is Transform && widget.transform.getMaxScaleOnAxis() != 1)), findsNothing);
    await tester.tap(find.text('SuperXD'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('SuperXD'), findsNothing);
    await tester.pump(PaintingSplash.longest);
  });

  test('系统启动图（Android 12 起）不画应用图标，浅深色两份启动主题都是透明图标、只剩底色', () {
    for (final folder in ['values-v31', 'values-night-v31']) {
      expect(File('android/app/src/main/res/$folder/styles.xml').readAsStringSync(), contains('<item name="android:windowSplashScreenAnimatedIcon">@android:color/transparent</item>'), reason: folder);
    }
  });

  testWidgets('关于页有「开屏画作」，列出全部画作并标出这次开屏的那幅；保存原地转圈、存好原地变成已保存', (tester) async {
    final temp = Directory.systemTemp.createTempSync('painting_ui');
    addTearDown(() => temp.deleteSync(recursive: true));
    final gate = Completer<bool>();
    final saved = <String>[];
    final library = PaintingLibrary.memory([_painting, _second], last: 'b', temporary: temp, publish: (picture, filename) async {
      saved.add(filename);
      return gate.future;
    });
    library.next();
    await tester.binding.setSurfaceSize(const Size(400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: AboutPage(packageInfo: Completer<Never>().future, paintings: library)));
    await tester.pump();
    await tester.tap(find.text('开屏画作'));
    await tester.pumpAndSettle();
    expect(find.text('《合成画作》'), findsOneWidget);
    expect(find.text('《合成第二幅》'), findsOneWidget);
    expect(find.byWidgetPredicate((widget) => widget is DotSeparatedText && widget.text == '测试说明 · 这次开屏'), findsOneWidget, reason: '上次是第二幅，这次轮到第一幅');
    await tester.runAsync(() async {
      await tester.tap(find.text('保存到相册').first);
      await tester.pump();
      // 读原图、写临时文件是真实 IO：等导出被调用。
      for (var step = 0; step < 100 && saved.isEmpty; step++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(saved, ['SuperXD-合成画作.jpg']);
    expect(find.text('保存中'), findsOneWidget);
    gate.complete(true);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('已保存'), findsOneWidget);
    expect(find.text('保存到相册'), findsOneWidget, reason: '另一幅还没存');
  });

  testWidgets('点画作原地放大成全屏，关闭按钮与说明随后淡入；点关闭原路缩回', (tester) async {
    final library = PaintingLibrary.memory([_painting]);
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: PaintingsPage(gallery: library)));
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byType(AspectRatio));
    await tester.tap(find.byType(AspectRatio));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    // 飞行途中只看得到一张：卡片里那张隐藏、位置保留。
    expect(tester.widget<Visibility>(find.descendant(of: find.byType(AspectRatio), matching: find.byType(Visibility))).visible, isFalse);
    await tester.pumpAndSettle();
    expect(find.byTooltip('关闭'), findsOneWidget);
    // 停稳后黑底不透明：半透明时下面卡片的标题、按钮会和全屏页的说明叠在一起（模拟器上看到过）。
    expect(find.byWidgetPredicate((widget) => widget is ColoredBox && widget.color == Colors.black), findsOneWidget);
    final zoomed = tester.getRect(find.descendant(of: find.byType(InteractiveViewer), matching: find.byType(Image)));
    expect(zoomed.width, greaterThan(card.width - 1));
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('关闭'), findsNothing);
    expect(tester.widget<Visibility>(find.descendant(of: find.byType(AspectRatio), matching: find.byType(Visibility))).visible, isTrue);
  });
}
