import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphnext/morphnext.dart';

import 'package:superxd/theme/campus_icons.dart';

// 先flutter build apk --release；验证实际裁剪后字体，而不是debug全字体。
class _ReleaseBundle extends CachingAssetBundle {
  final _assets = <String, Future<ByteData>>{};
  @override
  Future<ByteData> load(String key) => _assets.putIfAbsent(key, () async {
    final result = await Process.run('unzip', [
      '-p',
      'build/app/outputs/flutter-apk/app-release.apk',
      'assets/flutter_assets/$key',
    ], stdoutEncoding: null);
    if (result.exitCode != 0) throw StateError('发布包缺少资源：$key');
    final bytes = Uint8List.fromList(result.stdout as List<int>);
    return ByteData.sublistView(bytes);
  });
}

void main() {
  testWidgets('发布APK内裁剪后的Lucide字体仍产生所有导航形变', (tester) async {
    final bundle = _ReleaseBundle();
    await tester.runAsync(() async {
      await bundle.load('FontManifest.json');
      final manifest =
          jsonDecode(await bundle.loadString('FontManifest.json')) as List;
      final family = manifest.cast<Map>().firstWhere(
        (row) => row['family'] == 'packages/lucide_icons_flutter/Lucide',
      );
      for (final font in family['fonts'] as List) {
        await bundle.load((font as Map)['asset'] as String);
      }
    });
    configureCampusIcons();
    for (final pair in [
      (CampusIcons.today, CampusIcons.todaySelected),
      (CampusIcons.services, CampusIcons.servicesSelected),
      (CampusIcons.messages, CampusIcons.messagesSelected),
      (CampusIcons.account, CampusIcons.accountSelected),
      (CampusIcons.expand, CampusIcons.collapse),
    ]) {
      await tester.pumpWidget(
        DefaultAssetBundle(
          bundle: bundle,
          child: MaterialApp(
            home: Center(
              child: MorphIcon(
                key: ValueKey(pair),
                from: pair.$1,
                to: pair.$2,
                progress: const AlwaysStoppedAnimation(.5),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .where(
              (paint) => paint.painter.runtimeType.toString() == 'MorphPainter',
            ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    }
    expect(MorphCache.currentMorphs, 5);
  });
}
