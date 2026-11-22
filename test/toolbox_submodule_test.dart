import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/domain/feature_flags.dart';
import 'package:superxd/domain/rollout.dart';
import 'package:superxd/domain/unlock.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/toolbox/cinema/cinema_parse_section.dart';
import 'package:superxd/toolbox/cinema/cinema_search_section.dart';
import 'package:superxd/toolbox/cinema/cinema_service.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_module.dart';
import 'package:superxd/toolbox/toolbox_page.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

import 'toolbox_test_support.dart';

// 子模块框架（人工决策见 lib/toolbox/toolbox_module.dart 的 ToolboxModule）：注册表的写法、路由、显隐、清除数据与列表页。

class _Gate implements FeatureGate {
  _Gate(this.on);
  final Set<String> on;
  final _changes = StreamController<void>.broadcast(sync: true);
  void turn(String id, {required bool enabled}) {
    enabled ? on.add(id) : on.remove(id);
    _changes.add(null);
  }

  @override
  bool isOn(FeatureFlag flag) => on.contains(flag.id);
  @override
  Stream<void> get changes => _changes.stream;
}

class _Locks implements UnlockAccess {
  _Locks(this.lockedIds);
  final Set<String> lockedIds;
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  bool locked(String id) => lockedIds.contains(id);
  @override
  RolloutUnlock? offer(String id) => null;
  @override
  List<RolloutUnlock> get purchasable => const [];
  @override
  Future<void> refresh() async {}
  @override
  Future<void> buy(String id) async {}
}

class _Service implements ToolboxService {
  var cleared = false;
  @override
  Future<void> close() async {}
  @override
  Future<void> clearData() async => cleared = true;
}

const _parentFlag = FeatureFlag('toolbox.home', fallback: false);
const _childFlag = FeatureFlag('toolbox.home.water', fallback: false);

// 合成的父模块（同生活：不给页面，由框架列出子模块）：两个子模块，一个有自己的数据与快捷入口，一个在开关后面。
List<ToolboxModule> _catalog(ToolboxRuntime runtime) => [
  ToolboxModule(id: 'solo', name: '单个工具', icon: CampusIcons.toolbox, builder: (context) => const Text('单个工具页')),
  ToolboxModule(
    id: 'home',
    name: '合成生活',
    icon: CampusIcons.life,
    flag: _parentFlag,
    children: [
      ToolboxModule(
        id: 'home.power',
        name: '电费',
        icon: CampusIcons.toolbox,
        builder: (context) => const Text('电费页'),
        openService: (context) async => _Service(),
        clearedData: '电表与账号',
        shortcuts: [ToolboxShortcut(id: 'scan', label: '扫码缴费', icon: CampusIcons.qrCode, builder: (context) => const Text('扫码页'))],
      ),
      ToolboxModule(id: 'home.water', name: '水费', icon: CampusIcons.toolbox, builder: (context) => const Text('水费页'), openService: (context) async => _Service(), clearedData: '水表', flag: _childFlag),
    ],
  ),
];

void main() {
  group('注册表', () {
    late ToolboxFixture fixture;
    setUp(() async {
      fixture = ToolboxFixture();
      await fixture.initialize();
    });
    tearDown(() => fixture.close());

    test('真实注册表：id 全树唯一，子模块写成「父 id.子 id」；页面路径与快捷入口路径不撞；自己摆子模块的父模块（电影院）的子模块不登记服务、资源、快捷入口与好友分享', () {
      final roots = toolboxCatalog(fixture.runtime);
      final all = toolboxTree(roots).toList();
      expect(all.map((module) => module.id).toSet(), hasLength(all.length));
      void walk(ToolboxModule parent) {
        for (final child in parent.children) {
          expect(child.id, startsWith('${parent.id}.'), reason: child.id);
          expect(child.id.substring(parent.id.length + 1), isNot(contains('.')), reason: '只往下一层：${child.id}');
          if (parent.builder != null) {
            expect((child.builder != null, child.openService == null, child.resource == null, child.shortcuts.isEmpty, child.openShared == null, child.children.isEmpty), (true, true, true, true, true, true), reason: child.id);
          }
          walk(child);
        }
      }

      roots.forEach(walk);
      final paths = [
        for (final module in toolboxRoutable(roots)) ...[toolboxPath(module), for (final shortcut in module.shortcuts) '${toolboxPath(module)}/${shortcut.id}'],
      ];
      expect(paths.toSet(), hasLength(paths.length));
      expect(paths, isNot(contains('/toolbox/cinema/search')), reason: '电影院的段落没有自己的路由');
      expect(all.where((module) => module.openService != null && module.clearedData.isEmpty), isEmpty, reason: '有本机数据的都写明清除会删什么');
    });

    test('电影院的找片与解析是登记的两段，解析在开关 toolbox.cinema.parse 后面；生活登记在开关 toolbox.life 后面、由框架列出子模块', () {
      final roots = toolboxCatalog(fixture.runtime);
      final cinema = roots.singleWhere((module) => module.id == CinemaService.serviceId);
      expect([for (final section in cinema.children) (section.id, section.name, section.flag)], [(CinemaSearchSection.sectionId, '找片', null), (CinemaParseSection.sectionId, '解析', cinemaParseFlag)]);
      final life = roots.singleWhere((module) => module.id == 'life');
      expect((life.name, life.flag, life.builder), ('生活', lifeFlag, null));
      expect(featureFlags, contains(lifeFlag));
      expect((lifeFlag.id, lifeFlag.fallback), ('toolbox.life', false));
      // 还没有子模块：开关开着也不出现，不留一个点进去是空的入口。
      expect(toolboxVisible(life, features: _Gate({lifeFlag.id})), isFalse);
    });

    test('路径按 id 的点分层；有自己路由的只有顶层工具与框架列出的子模块；清除数据的内容按子模块写', () {
      final roots = _catalog(fixture.runtime);
      final home = roots.last;
      expect(toolboxPath(home.children.first), '/toolbox/home/power');
      expect([for (final module in toolboxRoutable(roots)) module.id], ['solo', 'home', 'home.power', 'home.water']);
      expect([for (final module in toolboxClearable(home)) module.id], ['home.power', 'home.water']);
      expect(toolboxClearedData(home), '电费的电表与账号；水费的水表');
      expect(toolboxClearable(roots.first), isEmpty);
    });

    test('显隐：父模块的开关与解锁照常；框架列出子模块的父模块至少要有一个看得见的子模块；路由门禁回到看不见那一层的上一层', () {
      final roots = _catalog(fixture.runtime);
      final home = roots.last;
      expect(toolboxVisible(home, features: _Gate({})), isFalse);
      expect(toolboxVisible(home, features: _Gate({_parentFlag.id})), isTrue, reason: '电费没开关，看得见');
      expect(toolboxVisible(home, features: _Gate({_parentFlag.id}), unlocks: _Locks({toolboxUnlockId('home.power')})), isFalse, reason: '电费锁着、水费开关关着：一个都看不见');
      expect(toolboxVisible(home, features: _Gate({_parentFlag.id, _childFlag.id}), unlocks: _Locks({toolboxUnlockId('home.power')})), isTrue);

      final features = _Gate({_parentFlag.id});
      String? redirect(String location, {UnlockAccess? unlocks}) => toolboxRedirect(roots, location, features: features, unlocks: unlocks);
      expect(redirect('/toolbox/home/water'), '/toolbox/home', reason: '子模块看不见回到父模块');
      expect(redirect('/toolbox/home/power'), isNull);
      expect(redirect('/toolbox/home/power/scan'), isNull, reason: '快捷入口跟着所属模块');
      expect(redirect('/toolbox/home/power/scan', unlocks: _Locks({toolboxUnlockId('home.power')})), '/toolbox', reason: '电费锁着、水费关着，父模块也看不见');
      features.turn(_childFlag.id, enabled: true);
      expect(redirect('/toolbox/home/power/scan', unlocks: _Locks({toolboxUnlockId('home.power')})), '/toolbox/home');
      features.turn(_childFlag.id, enabled: false);
      expect(redirect('/toolbox/home/power', unlocks: _Locks({toolboxUnlockId('home')})), '/toolbox', reason: '父模块看不见回到百宝箱首页');
      expect(redirect('/toolbox/solo'), isNull);
      expect(redirect('/today'), isNull);
    });

    test('清除父模块的数据：逐个清它下面有数据的子模块，撤的是子模块自己的同意记录', () async {
      final power = _Service();
      final water = _Service();
      final runtime = ToolboxRuntime.testing(catalog: _catalog, store: fixture.store, downloads: fixture.manager, services: {'home.power': power, 'home.water': water});
      await fixture.store.grantConsent('home.power', 'v1');
      await fixture.store.grantConsent('home.water', 'v1');
      await fixture.store.grantConsent('solo', 'v1');
      await runtime.clearData('home');
      expect((power.cleared, water.cleared), (true, true));
      expect(await fixture.store.consent('home.power', 'v1'), isFalse);
      expect(await fixture.store.consent('home.water', 'v1'), isFalse);
      expect(await fixture.store.consent('solo', 'v1'), isTrue);
      expect(runtime.module('home.water')?.name, '水费');
    });
  });

  group('列表页', () {
    late ToolboxFixture fixture;
    setUp(() async {
      fixture = ToolboxFixture();
      await fixture.initialize();
    });
    tearDown(() => fixture.close());

    testWidgets('父模块的页面列出看得见的子模块（标题是父模块的名字），点了进子模块的路由；开关在页面开着时关掉，那一项立即收起，一个都没有时写明', (tester) async {
      final runtime = ToolboxRuntime.testing(catalog: _catalog, store: fixture.store, downloads: fixture.manager);
      final home = runtime.module('home')!;
      final features = _Gate({_parentFlag.id, _childFlag.id});
      final router = GoRouter(
        initialLocation: '/toolbox/home',
        routes: [
          GoRoute(path: '/toolbox/home', builder: (_, _) => ToolboxPage(runtime: runtime, parent: home, features: features)),
          for (final child in home.children) GoRoute(path: toolboxPath(child), builder: (context, _) => child.builder!(context)),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(theme: campusTheme(), routerConfig: router));
      await tester.pumpAndSettle();
      expect(find.text('合成生活'), findsOneWidget);
      expect(find.text('电费'), findsOneWidget);
      expect(find.text('水费'), findsOneWidget);
      features.turn(_childFlag.id, enabled: false);
      await tester.pump();
      expect(find.text('水费'), findsNothing);
      await tester.tap(find.text('电费'));
      await tester.pumpAndSettle();
      expect(find.text('电费页'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();

      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ToolboxPage(runtime: runtime, parent: home, features: _Gate({_parentFlag.id}), unlocks: _Locks({toolboxUnlockId('home.power')}))));
      await tester.pumpAndSettle();
      expect(find.text('暂时没有可用的功能'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('父模块卡片左滑是「清除数据」，确认里按子模块写会删什么', (tester) async {
      final runtime = ToolboxRuntime.testing(catalog: _catalog, store: fixture.store, downloads: fixture.manager, services: {'home.power': _Service(), 'home.water': _Service()});
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ToolboxPage(runtime: runtime, features: _Gate({_parentFlag.id}))));
      await tester.pumpAndSettle();
      await tester.drag(find.text('合成生活'), const Offset(-260, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清除数据'));
      await tester.pumpAndSettle();
      expect(find.text('清除合成生活的数据？'), findsOneWidget);
      expect(find.textContaining('电费的电表与账号；水费的水表'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });
  });
}
