import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/pass.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';
import 'package:superxd/toolbox/cinema/cinema_service.dart';
import 'package:superxd/toolbox/toolbox_module.dart';
import 'package:superxd/toolbox/toolbox_page.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 电影院各段共用的接线：段落经它取服务，开始忙（搜索中、解析中）与忙完时报上来，忙着时不能切到别的段（同改成子模块之前）。
// 段落在页面里一直挂着（切走只是不显示），输入的字、搜到的结果切回来都还在。
class CinemaScope extends InheritedWidget {
  const CinemaScope({super.key, required this.service, required this.history, required this.busy, required super.child});
  final CinemaService service;
  // 准备页面时一起读好的「看过的」：页面一出来就带着，不先空着再跳出一行。
  final List<CinemaHistory> history;
  final void Function(String section, bool busy) busy;

  // 不建立依赖：服务在页面准备好之后不再换，initState 里也能取。
  static CinemaScope of(BuildContext context) => context.getInheritedWidgetOfExactType<CinemaScope>()!;

  @override
  bool updateShouldNotify(CinemaScope oldWidget) => service != oldWidget.service;
}

// 电影院首页：准备规则包与时长券，再摆注册表里登记的段（子模块，人工决策见 toolbox_module.dart 与下面的 _sections）：
// 现在是找片（cinema_search_section.dart）与解析（cinema_parse_section.dart，在功能开关 cinemaParseFlag 后面，关着时只有找片、不显示切换）。
class CinemaPage extends StatefulWidget {
  const CinemaPage({super.key, required this.runtime});
  final ToolboxRuntime runtime;
  @override
  State<CinemaPage> createState() => _CinemaPageState();
}

class _CinemaPageState extends State<CinemaPage> {
  late CinemaService _service;
  List<CinemaHistory> _history = const [];
  late Future<void> _ready = _initialize();
  String? _picked;
  final _busy = <String>{};
  StreamSubscription<void>? _passChanges;
  StreamSubscription<void>? _featureChanges;
  var _buying = false;

  // [人工决策-2026-11-22 18:46:09] 找片、解析改成电影院登记的两个子模块（用户选「框架统一子模块」，行为不变）：段落只在 toolbox_catalog.dart 的
  // 电影院 children 里登记，这里按登记的先后摆、两段以上才出分段切换；灰度中的段（解析）开关没开不显示，页面开着时被关掉就回到第一段。
  List<ToolboxModule> get _sections => [
    for (final section in widget.runtime.module(CinemaService.serviceId)?.children ?? const <ToolboxModule>[])
      if (toolboxVisible(section, features: widget.runtime.features)) section,
  ];

  @override
  void initState() {
    super.initState();
    _passChanges = widget.runtime.passes?.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _featureChanges = widget.runtime.features?.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  // 本机已有规则包时先显示页面、在后台更新（拉不到照旧用本机的）；第一次用要等规则包。看过的记录与规则包一起读，交给找片那一段。
  // 时长券不挡页面：先照本机记的判定，拉到新的经 changes 刷新（人工决策见 domain/pass.dart）。force 是页面上的「重试」，都不等间隔。
  Future<void> _initialize({bool force = false}) async {
    try {
      await widget.runtime.initialize();
      final service = _service = await widget.runtime.service<CinemaService>(CinemaService.serviceId);
      unawaited(widget.runtime.passes?.refresh(force: force).catchError((Object error, StackTrace stack) => campusLog('[Cinema] action=passes errorType=${error.runtimeType}\n$stack')));
      final history = service.store.history(DateTime.now());
      if (service.package == null || force) {
        await service.rules(force: force);
      } else {
        unawaited(service.rules().then<void>((_) {}, onError: (Object error, StackTrace stack) => campusLog('[Cinema] action=rules_background errorType=${error.runtimeType}\n$stack')));
      }
      _history = await history;
    } on CinemaRuleException catch (error) {
      campusLog('[Cinema] action=initialize errorType=CinemaRuleException message=${error.message}');
      rethrow;
    } catch (error, stack) {
      campusLog('[Cinema] action=initialize errorType=${error.runtimeType}\n$stack');
      rethrow;
    }
  }

  void _onBusy(String section, bool busy) {
    if (!mounted || _busy.contains(section) == busy) return;
    setState(() => busy ? _busy.add(section) : _busy.remove(section));
  }

  // 花积分换一段时长（人工决策见 domain/pass.dart）：成功后原地换成找片，提示到哪天。
  Future<void> _buyPass() async {
    final passes = widget.runtime.passes;
    if (passes == null || _buying) return;
    setState(() => _buying = true);
    try {
      await passes.buy(CinemaService.passId);
      final until = passes.until(CinemaService.passId);
      if (mounted && until != null) showCampusToast(context, '可以用到 ${formatCampusMoment(until.toIso8601String())}');
    } on PassException catch (error) {
      if (mounted) showCampusToast(context, error.message);
    } finally {
      if (mounted) setState(() => _buying = false);
    }
  }

  @override
  void dispose() {
    unawaited(_passChanges?.cancel());
    unawaited(_featureChanges?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('电影院'),
      leading: IconButton(
        tooltip: '返回',
        onPressed: () => context.canPop() ? context.pop() : Navigator.pop(context),
        icon: const CampusIcon(CampusIcons.back),
      ),
    ),
    body: CampusScrollFade(
      child: SafeArea(
        bottom: false,
        child: FutureBuilder<void>(
          future: _ready,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              final error = snapshot.error;
              return CampusLoadError(
                message: error is CinemaRuleException ? error.message : '准备失败',
                onRetry: () => setState(() {
                  _ready = _initialize(force: true);
                }),
              );
            }
            if (snapshot.connectionState != ConnectionState.done) return const Center(child: CampusLoading(label: '正在准备', network: true, remote: '中转服务'));
            final passes = widget.runtime.passes;
            if (passes != null && passes.locked(CinemaService.passId)) return _passCard(context, passes);
            final sections = _sections;
            final shown = sections.where((section) => section.id == _picked).firstOrNull ?? sections.firstOrNull;
            final until = passes?.until(CinemaService.passId);
            return CinemaScope(
              service: _service,
              history: _history,
              busy: _onBusy,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 800),
                  child: CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.only(top: 8),
                        sliver: SliverMainAxisGroup(
                          slivers: [
                            if (sections.length > 1 || until != null)
                              SliverPadding(
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                sliver: SliverToBoxAdapter(child: _header(context, sections, shown, until)),
                              ),
                            for (final section in sections) SliverOffstage(key: ValueKey(section.id), offstage: section != shown, sliver: section.builder!(context)),
                          ],
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: CampusGap.section)),
                      const CampusScrollTail(),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );

  Widget _passCard(BuildContext context, PassAccess passes) {
    final offer = passes.offer(CinemaService.passId)!;
    final text = Theme.of(context).textTheme;
    final palette = CampusPalette.of(context);
    return ListView(
      padding: campusScrollPadding(context, const EdgeInsets.all(16)),
      children: [
        CampusSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('用积分换时长', style: text.titleMedium),
              const SizedBox(height: CampusGap.tight),
              Text('${offer.price} 积分用 ${offer.days} 天', style: text.bodyMedium?.copyWith(color: palette.onSurfaceVariant)),
              const SizedBox(height: CampusGap.medium),
              if (passes.canBuy)
                FilledButton(
                  style: campusProminent,
                  onPressed: _buying ? null : () => unawaited(_buyPass()),
                  child: CampusBusyContent(busy: _buying, label: '兑换', busyLabel: '兑换中', icon: const CampusIcon(CampusIcons.resume)),
                )
              else
                Text('登录应用账号并联网后才能兑换', style: text.bodyMedium?.copyWith(color: palette.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, List<ToolboxModule> sections, ToolboxModule? shown, DateTime? until) {
    final busy = sections.any((section) => _busy.contains(section.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sections.length > 1 && shown != null) ...[
          CampusSegmented<ToolboxModule>(
            values: sections,
            label: (section) => section.name,
            selected: shown,
            onSelected: busy ? null : (section) => setState(() => _picked = section.id),
          ),
          const SizedBox(height: CampusGap.medium),
        ],
        if (until != null) ...[
          Text('时长到 ${formatCampusMoment(until.toIso8601String())}', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: CampusPalette.of(context).onSurfaceVariant)),
          const SizedBox(height: CampusGap.medium),
        ],
      ],
    );
  }
}
