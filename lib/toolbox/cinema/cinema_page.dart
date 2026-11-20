import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/feature_flags.dart';
import 'package:superxd/domain/pass.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_search_field.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/cinema/cinema_cloud_parse.dart';
import 'package:superxd/toolbox/cinema/cinema_detail_page.dart';
import 'package:superxd/toolbox/cinema/cinema_http.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_player_page.dart';
import 'package:superxd/toolbox/cinema/cinema_poster.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';
import 'package:superxd/toolbox/cinema/cinema_service.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';
import 'package:superxd/toolbox/toolbox_url.dart';

enum _Mode { search, parse }

// 电影院首页：找片（多源搜索、按片名加年份聚合，没搜时列看过的）与解析（视频网站播放页地址 → 云解析 → 播放）。
// 解析在功能开关 cinemaParseFlag 后面（人工决策见 domain/feature_flags.dart），关着时只有找片、不显示切换。
// 第一次搜、第一次解析前征得同意：片名与播放页地址会直接发给第三方站点（新加的源、换了主机的要重新同意）。
class CinemaPage extends StatefulWidget {
  const CinemaPage({super.key, required this.runtime});
  final ToolboxRuntime runtime;
  @override
  State<CinemaPage> createState() => _CinemaPageState();
}

class _CinemaPageState extends State<CinemaPage> {
  late CinemaService _service;
  late Future<void> _ready = _initialize();
  final _query = TextEditingController();
  final _link = TextEditingController();
  var _mode = _Mode.search;
  List<CinemaHistory> _history = const [];
  CinemaSearchResult? _result;
  String? _searched;
  var _searching = false;
  var _parsing = false;
  String? _message;
  // 新的一次搜索顶掉旧的：中断还没回来的请求，旧结果不再写界面。
  Completer<void>? _cancel;
  var _generation = 0;
  StreamSubscription<void>? _passChanges;
  StreamSubscription<void>? _featureChanges;
  var _buying = false;

  // 解析开着才有两段可切；关着（含页面开着时被关掉）一律是找片。
  _Mode get _shown => widget.runtime.features?.isOn(cinemaParseFlag) == true ? _mode : _Mode.search;

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

  // 本机已有规则包时先显示页面、在后台更新（拉不到照旧用本机的）；第一次用要等规则包。看过的记录与规则包一起读。
  // 时长券不挡页面：先照本机记的判定，拉到新的经 changes 刷新（人工决策见 domain/pass.dart）。force 是页面上的「重试」，都不等间隔。
  Future<void> _initialize({bool force = false}) async {
    try {
      await widget.runtime.initialize();
      final service = _service = await widget.runtime.service<CinemaService>(CinemaService.serviceId);
      unawaited(widget.runtime.passes?.refresh(force: force).catchError((Object error, StackTrace stack) => campusLog('[Cinema] action=passes errorType=${error.runtimeType}\n$stack')));
      final history = _reloadHistory();
      if (service.package == null || force) {
        await service.rules(force: force);
      } else {
        unawaited(service.rules().then<void>((_) {}, onError: (Object error, StackTrace stack) => campusLog('[Cinema] action=rules_background errorType=${error.runtimeType}\n$stack')));
      }
      await history;
    } on CinemaRuleException catch (error) {
      campusLog('[Cinema] action=initialize errorType=CinemaRuleException message=${error.message}');
      rethrow;
    } catch (error, stack) {
      campusLog('[Cinema] action=initialize errorType=${error.runtimeType}\n$stack');
      rethrow;
    }
  }

  Future<void> _reloadHistory() async {
    final history = await _service.store.history();
    if (mounted) setState(() => _history = history);
  }

  // 还没同意过的源先问一次；不同意就不搜。
  Future<bool> _consentRules() async {
    final package = await _service.usable();
    final missing = await _service.unconsentedRules(package);
    if (missing.isEmpty) return true;
    if (!mounted) return false;
    final agreed = await showCampusConfirm(
      context,
      title: '使用第三方片源',
      // 长文案：首次同意要说清片名发给谁、内容归谁；片名目录型的源（人工决策见 cinema_catalog.dart）片名先发到开发者服务器查编号。
      message: '片名会发给以下站点，片源与画面来自第三方，版权归原权利人：\n${[for (final rule in missing) rule.catalog == null ? rule.name : '${rule.name}（片名经开发者服务器查找，不保存）'].join('、')}',
      action: '同意并搜索',
    );
    if (!agreed) return false;
    await _service.grantRules(missing);
    return true;
  }

  Future<void> _search() async {
    final keyword = _query.text.trim();
    if (keyword.isEmpty || keyword.length > 80) {
      setState(() => _message = keyword.isEmpty ? '输入片名' : '片名最多 80 个字');
      return;
    }
    FocusScope.of(context).unfocus();
    try {
      if (!await _consentRules() || !mounted) return;
    } catch (error, stack) {
      campusLog('[Cinema] action=consent errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _message = '拿不到片源规则，稍后再试');
      return;
    }
    _cancel?.complete();
    final cancel = _cancel = Completer<void>();
    final generation = ++_generation;
    setState(() {
      _searching = true;
      _message = null;
      _searched = keyword;
    });
    try {
      // 边搜边显示（人工决策见 cinema_service.dart 的 pauseAfter）：每回来一个源换一份快照。
      await for (final result in _service.search(keyword, cancel: cancel.future)) {
        if (!mounted || generation != _generation) return;
        setState(() => _result = result);
      }
    } catch (error, stack) {
      campusLog('[Cinema] action=search errorType=${error.runtimeType}\n$stack');
      if (mounted && generation == _generation) setState(() => _message = '搜索没完成，稍后再试');
    } finally {
      if (mounted && generation == _generation) setState(() => _searching = false);
    }
  }

  Future<void> _openTitle(CinemaTitle title) async {
    await Navigator.push<void>(context, CampusPageRoute(builder: (_) => CinemaDetailPage(service: _service, title: title)));
    await _reloadHistory();
  }

  // 看过的：按记下的源直接接着播；源已不在规则包里时进选集页让用户换源。
  Future<void> _resume(CinemaHistory entry) async {
    final rule = _service.rule(entry.ruleId);
    final title = CinemaTitle(key: entry.key, name: entry.name, year: '', cover: entry.cover, remarks: '')
      ..sources.add(CinemaSourceRef(ruleId: entry.ruleId, source: entry.source, name: entry.name, remarks: ''));
    if (rule == null) {
      await _openTitle(title);
      return;
    }
    await Navigator.push<void>(
      context,
      CampusPageRoute(builder: (_) => CinemaPlayerPage.title(service: _service, title: title, source: title.sources.first, road: entry.road, episode: entry.episode, start: entry.position)),
    );
    await _reloadHistory();
  }

  Future<void> _parse() async {
    final package = _service.package;
    final parser = package == null || package.parsers.isEmpty ? null : package.parsers.first;
    final Uri target;
    try {
      target = toolboxPublicUrl(_link.text.trim());
    } on Object {
      setState(() => _message = '输入视频页面的 http(s) 地址');
      return;
    }
    if (parser == null && !cinemaMediaUrl(target.toString())) {
      setState(() => _message = '现在没有可用的解析服务');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _parsing = true;
      _message = null;
    });
    try {
      if (parser != null && !cinemaMediaUrl(target.toString()) && !await _service.parserConsented(parser)) {
        if (!mounted) return;
        final agreed = await showCampusConfirm(
          context,
          title: '使用云解析',
          message: '播放页地址会发给${parser.name}（${parser.host}），画面来自第三方，版权归原权利人。',
          action: '同意并解析',
        );
        if (!agreed) return;
        await _service.grantParser(parser);
      }
      final parsed = parser == null ? CinemaParsed(title: target.pathSegments.lastOrNull ?? '直链', type: 'direct', url: target.toString(), direct: true) : await _service.cloud.parse(parser, target.toString());
      if (!mounted) return;
      await Navigator.push<void>(context, CampusPageRoute(builder: (_) => CinemaPlayerPage.parsed(service: _service, parser: parser, target: target.toString(), parsed: parsed)));
    } on CinemaParseException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } on CinemaHttpException catch (error) {
      if (mounted) setState(() => _message = '解析服务${error.message}');
    } on CinemaRuleException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (error, stack) {
      campusLog('[Cinema] action=parse errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _message = '解析没完成，稍后再试');
    } finally {
      if (mounted) setState(() => _parsing = false);
    }
  }

  Future<void> _paste() async {
    try {
      final value = await Clipboard.getData(Clipboard.kTextPlain);
      final text = value?.text?.trim();
      if (text != null && text.isNotEmpty && mounted) {
        _link.text = text;
        setState(() => _message = null);
      }
    } catch (error, stack) {
      campusLog('[Cinema] action=paste errorType=${error.runtimeType}\n$stack');
    }
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
    _cancel?.complete();
    _query.dispose();
    _link.dispose();
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
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      sliver: SliverToBoxAdapter(child: _header(context)),
                    ),
                    if (_shown == _Mode.search) ..._searchSlivers(context),
                    const SliverToBoxAdapter(child: SizedBox(height: CampusGap.section)),
                  ],
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
      padding: const EdgeInsets.all(16),
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

  Widget _header(BuildContext context) {
    final palette = CampusPalette.of(context);
    final shown = _shown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.runtime.features?.isOn(cinemaParseFlag) == true) ...[
          CampusSegmented<_Mode>(
            values: _Mode.values,
            label: (mode) => mode == _Mode.search ? '找片' : '解析',
            selected: shown,
            onSelected: _searching || _parsing ? null : (mode) => setState(() {
              _mode = mode;
              _message = null;
            }),
          ),
          const SizedBox(height: CampusGap.medium),
        ],
        if (shown == _Mode.search)
          Row(
            children: [
              Expanded(child: CampusSearchField(controller: _query, hint: '片名', enabled: !_searching, onSubmitted: (_) => _search())),
              const SizedBox(width: CampusGap.small),
              FilledButton(
                style: campusProminent,
                onPressed: _searching ? null : _search,
                child: CampusBusyContent(busy: _searching, label: '搜索', busyLabel: '搜索中', icon: const CampusIcon(CampusIcons.search)),
              ),
            ],
          )
        else
          CampusSurface(
            padding: EdgeInsets.fromLTRB(16, campusFieldGap(context), 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _link,
                  enabled: !_parsing,
                  minLines: 1,
                  maxLines: 3,
                  maxLength: 8192,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(labelText: '视频页面地址', hintText: '粘贴播放页地址', counterText: ''),
                  onChanged: (_) => setState(() => _message = null),
                ),
                const SizedBox(height: CampusGap.medium),
                Wrap(
                  spacing: CampusGap.small,
                  runSpacing: CampusGap.small,
                  children: [
                    OutlinedButton.icon(onPressed: _parsing ? null : _paste, icon: const CampusIcon(CampusIcons.paste), label: const Text('粘贴')),
                    FilledButton(
                      style: campusProminent,
                      onPressed: _parsing || _link.text.trim().isEmpty ? null : _parse,
                      child: CampusBusyContent(busy: _parsing, label: '解析并播放', busyLabel: '解析中', icon: const CampusIcon(CampusIcons.resume)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        if (widget.runtime.passes?.until(CinemaService.passId) case final until?)
          Padding(
            padding: const EdgeInsets.only(top: CampusGap.small),
            child: Text('时长到 ${formatCampusMoment(until.toIso8601String())}', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.onSurfaceVariant)),
          ),
        if (_message case final message?)
          Padding(
            padding: const EdgeInsets.only(top: CampusGap.medium),
            child: Text(message, style: TextStyle(color: palette.danger)),
          ),
      ],
    );
  }

  List<Widget> _searchSlivers(BuildContext context) {
    final palette = CampusPalette.of(context);
    final text = Theme.of(context).textTheme;
    final result = _result;
    if (_searching && (result == null || (result.titles.isEmpty && result.pending > 0))) {
      return [SliverPadding(padding: const EdgeInsets.only(top: CampusGap.section), sliver: SliverToBoxAdapter(child: CampusLoading(label: '正在搜索', inline: true, network: true, remote: '片源站')))];
    }
    if (result == null) {
      if (_history.isEmpty) return const [];
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          sliver: SliverToBoxAdapter(child: Text('看过的', style: text.titleMedium)),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.separated(
            itemCount: _history.length,
            separatorBuilder: (_, _) => const SizedBox(height: CampusGap.small),
            itemBuilder: (context, index) {
              final entry = _history[index];
              return CinemaPosterRow(
                key: ValueKey(entry.key),
                covers: [entry.cover],
                title: entry.name,
                lines: [entry.episodeName, if (entry.position > Duration.zero) '看到 ${formatCinemaDuration(entry.position)}'],
                onTap: () => unawaited(_resume(entry).catchError((Object error, StackTrace stack) => campusLog('[Cinema] action=resume errorType=${error.runtimeType}\n$stack'))),
              );
            },
          ),
        ),
      ];
    }
    final failed = [for (final failure in result.failures) failure.message];
    final paused = result.failures.any((failure) => failure.paused);
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(result.titles.isEmpty ? '没搜到「$_searched」' : '「$_searched」${result.titles.length} 部', style: text.titleMedium),
              if (result.pending > 0) ...[
                const SizedBox(height: CampusGap.tight),
                Text('还在搜 ${result.pending} 个源', style: text.bodyMedium?.copyWith(color: palette.onSurfaceVariant)),
              ],
              if (failed.isNotEmpty) ...[
                const SizedBox(height: CampusGap.tight),
                Text('暂不可用：${failed.join('；')}', style: text.bodyMedium?.copyWith(color: palette.onSurfaceVariant)),
              ],
              if (paused && !_searching) ...[
                const SizedBox(height: CampusGap.small),
                TextButton.icon(
                  onPressed: () {
                    _service.resume();
                    unawaited(_search());
                  },
                  icon: const CampusIcon(CampusIcons.sync),
                  label: const Text('重试暂停的源'),
                ),
              ],
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList.separated(
          itemCount: result.titles.length,
          separatorBuilder: (_, _) => const SizedBox(height: CampusGap.small),
          itemBuilder: (context, index) {
            final title = result.titles[index];
            return CinemaPosterRow(
              key: ValueKey(title.key),
              covers: title.covers,
              title: title.name,
              lines: [
                [if (title.year.isNotEmpty) title.year, if (title.remarks.isNotEmpty) title.remarks].join(' · '),
                '${title.sources.length} 个源',
              ],
              onTap: () => unawaited(_openTitle(title).catchError((Object error, StackTrace stack) => campusLog('[Cinema] action=open errorType=${error.runtimeType}\n$stack'))),
            );
          },
        ),
      ),
    ];
  }
}
