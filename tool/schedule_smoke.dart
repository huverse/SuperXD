import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:superxd/gateway/kingo_campus_gateway.dart';
import 'package:superxd/local/app_database.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/page/schedule_editor_page.dart';
import 'package:superxd/theme/campus_theme.dart';

// 仅手工验收入口：内存SQLite、合成学期、不使用AccountStore、不登录或请求教务。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ensureCampusClock();
  final database = await AppDatabase.openMemory();
  const term = TermRef(xn: '2090', xq: '0', label: '隔离交互验收 · 合成课表');
  await database.saveTerms([term]);
  runApp(
    MaterialApp(
      theme: campusTheme(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: ScheduleEditorPage(
        gateway: KingoCampusGateway(database: database),
        term: term,
      ),
    ),
  );
}
