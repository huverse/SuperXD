import 'package:camera/camera.dart' show CameraException;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import 'package:superxd/page/qr_scan_page.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';

// 扫码页（人工决策见 qr_scan_page.dart 文件头）：测试里没有相机，取景组件报相机打不开；识别结果直接调它的 onScan 喂进去。
Future<GlobalKey<NavigatorState>> _open(WidgetTester tester, QrScanPage page, {void Function(String? raw)? onPop}) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(MaterialApp(theme: campusTheme(), navigatorKey: navigator, home: const SizedBox.expand(child: Text('上一页'))));
  navigator.currentState!.push(CampusPageRoute<String>(builder: (_) => page)).then((raw) => onPop?.call(raw));
  await tester.pumpAndSettle();
  return navigator;
}

void _scan(WidgetTester tester, String text) => tester.widget<ReaderWidget>(find.byType(ReaderWidget)).onScan!(Code(text: text, isValid: true));

void main() {
  testWidgets('相机打不开时原地说明（没给权限另说），可从相册识别；没有手电筒与缩放档位', (tester) async {
    await _open(tester, QrScanPage(accept: (_) => null));
    final reader = tester.widget<ReaderWidget>(find.byType(ReaderWidget));
    reader.onControllerCreated!(null, CameraException('CameraAccessDenied', '用户拒绝'));
    await tester.pump();
    expect(find.text('没有相机权限，可在系统设置中开启，或从相册选择二维码截图'), findsOneWidget);
    reader.onControllerCreated!(null, CameraException('cameraNotFound', '没有相机'));
    await tester.pump();
    expect(find.text('相机暂不可用，可从相册选择二维码截图'), findsOneWidget);
    expect(find.byTooltip('从相册识别'), findsOneWidget);
    expect(find.byTooltip('打开手电筒'), findsNothing);
    expect(find.textContaining('×'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单次扫码：不认的原地提示接着扫，认下的关页把原文交回', (tester) async {
    String? popped;
    var closed = false;
    final navigator = await _open(tester, QrScanPage(accept: (raw) => raw.startsWith('https://') ? null : '不是签到二维码'), onPop: (raw) {
      popped = raw;
      closed = true;
    });
    _scan(tester, 'hello');
    await tester.pump();
    expect(find.text('不是签到二维码'), findsOneWidget);
    expect(closed, isFalse);
    _scan(tester, 'https://example.com/sign?id=1');
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(popped, 'https://example.com/sign?id=1');
    expect(navigator.currentState!.canPop(), isFalse);
  });

  // 取景组件认出后过一会儿会再报同一个码；连签时同一个码只签一次，换了新码（课堂码定时刷新）才再交出去。
  testWidgets('连续扫码：同一个码只交给 onCode 一次，换了码再交', (tester) async {
    final codes = <String>[];
    await _open(tester, QrScanPage(accept: (_) => null, onCode: codes.add));
    for (final text in ['https://example.com/a', 'https://example.com/a', 'https://example.com/a', 'https://example.com/b', 'https://example.com/b']) {
      _scan(tester, text);
      await tester.pump();
    }
    expect(codes, ['https://example.com/a', 'https://example.com/b']);
    expect(find.byType(QrScanPage), findsOneWidget);
  });

  // 两指一落下就算缩放：不然 iOS 的页面任意位置右滑返回会抢走横向分开的那根手指，整页滑走。
  // 一指按住不动、另一指往右拉开（常见的拉法）：右滑返回先走够距离，缩放的张开量还没到门槛。
  testWidgets('iOS 上两指缩放不触发右滑返回，一指横滑照常返回', (tester) async {
    final navigator = await _open(tester, QrScanPage(accept: (_) => null));
    final center = tester.getCenter(find.byType(QrScanPage));
    final first = await tester.startGesture(center - const Offset(20, 0), pointer: 1);
    final second = await tester.startGesture(center + const Offset(20, 0), pointer: 2);
    for (var step = 0; step < 8; step++) {
      await second.moveBy(const Offset(10, 0));
      await tester.pump();
    }
    expect(navigator.currentState!.userGestureInProgress, isFalse);
    expect(tester.getTopLeft(find.byType(QrScanPage)).dx, 0);
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    final width = tester.getSize(find.byType(MaterialApp)).width;
    await tester.timedDragFrom(Offset(width / 2, 300), Offset(width * .7, 0), const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byType(QrScanPage), findsNothing);
    expect(find.text('上一页'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
