import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:superxd/toolbox/short_video/media_image.dart';

void main() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lN0AAAAASUVORK5CYII=',
  );
  testWidgets('图片失败可点按重试，不自动循环请求', (tester) async {
    var calls = 0;
    http.Client client() => MockClient((_) async {
      calls++;
      return calls == 1
          ? http.Response('unavailable', 503)
          : http.Response.bytes(png, 200);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: MediaImage(
          url: Uri.parse('https://cdn.example.com/image.png'),
          createClient: client,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('重试图片'), findsOneWidget);
    expect(calls, 1);
    await tester.tap(find.text('重试图片'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('同一组件换图片时取消旧请求并忽略迟到响应', (tester) async {
    final oldResponse = Completer<http.Response>();
    final key = GlobalKey();
    http.Client client() => MockClient(
      (request) => request.url.path == '/old.png'
          ? oldResponse.future
          : Future.value(http.Response.bytes(png, 200)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MediaImage(
          key: key,
          url: Uri.parse('https://cdn.example.com/old.png'),
          createClient: client,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaImage(
          key: key,
          url: Uri.parse('https://cdn.example.com/new.png'),
          createClient: client,
        ),
      ),
    );
    await tester.pumpAndSettle();
    oldResponse.complete(http.Response('failure', 500));
    await tester.pumpAndSettle();
    expect(find.text('重试图片'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
