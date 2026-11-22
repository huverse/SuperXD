import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_search_field.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/toolbox/cinema/cinema_consent.dart';
import 'package:superxd/toolbox/cinema/cinema_detail_page.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_page.dart';
import 'package:superxd/toolbox/cinema/cinema_player_page.dart';
import 'package:superxd/toolbox/cinema/cinema_poster.dart';
import 'package:superxd/toolbox/cinema/cinema_service.dart';

// 暂不可用各组的开头（人工决策见 _onQuery 上 11-22 那条）。
const _failureLabels = {CinemaFailureKind.unreachable: '连不上', CinemaFailureKind.refused: '拒绝访问', CinemaFailureKind.broken: '出错'};

// 电影院的「找片」一段（登记在 toolbox_catalog.dart 的电影院 children，id cinema.search）：多源搜索、按片名加年份聚合，没搜时列看过的。
// 第一次搜前征得同意：片名会直接发给第三方站点（新加的源、换了主机的要重新同意）。是电影院首页 CustomScrollView 里的一段 sliver。
class CinemaSearchSection extends StatefulWidget {
  const CinemaSearchSection({super.key});
  static const sectionId = 'cinema.search';
  @override
  State<CinemaSearchSection> createState() => _CinemaSearchSectionState();
}

class _CinemaSearchSectionState extends State<CinemaSearchSection> {
  late final CinemaService _service = CinemaScope.of(context).service;
  final _query = TextEditingController();
  // 先用首页准备时读好的，看完回来再重读。
  late List<CinemaHistory> _history = CinemaScope.of(context).history;
  CinemaSearchResult? _result;
  String? _searched;
  var _searching = false;
  String? _message;
  // 新的一次搜索顶掉旧的：中断还没回来的请求，旧结果不再写界面。
  Completer<void>? _cancel;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQuery);
  }

  // [人工决策-2026-11-20 22:54:48] 首页三项（用户全选推荐）：清空搜索框（点 × 或删光）就回到「看过的」并中断还没搜完的；
  // 搜索中输入框照常可改，按键盘的搜索重新搜（新的一次本来就顶掉旧的）；暂不可用的源只写名字（11-22 起按原因分组，见下一条）。
  // [人工决策-2026-11-22 17:21:06] 暂不可用按原因分组写源名（用户选「按原因分组写源名」，专人建议分清网络不通与片源拒绝）：
  // 连不上（连接失败、超时）、拒绝访问（401、403、407、429、451 与 Cloudflare 人机验证）、出错（别的）各一行，只有一组时就一行；
  // 仍只写源名，具体原因照旧只进日志（CinemaService.search）。分组见 CinemaFailureKind。
  void _onQuery() {
    if (_query.text.isNotEmpty || (_result == null && !_searching)) return;
    _cancel?.complete();
    _cancel = null;
    _generation++;
    setState(() {
      _result = null;
      _searched = null;
      _message = null;
    });
    _setSearching(false);
  }

  // 搜索中报给电影院首页（忙着时不能切到别的段）。
  void _setSearching(bool searching) {
    if (_searching != searching) setState(() => _searching = searching);
    CinemaScope.of(context).busy(CinemaSearchSection.sectionId, searching);
  }

  Future<void> _reloadHistory() async {
    final history = await _service.store.history(DateTime.now());
    if (mounted) setState(() => _history = history);
  }

  // 还没同意过的源先问一次（cinema_consent.dart）；不同意就不搜。
  Future<bool> _consentRules() async {
    final package = await _service.usable();
    final missing = await _service.unconsentedRules(package);
    if (missing.isEmpty) return true;
    if (!mounted) return false;
    return askCinemaConsent(context, _service, missing, action: '同意并搜索');
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
    // 结果正显示着时再搜同一个词是「重新搜」，不用最近的搜索结果（人工决策见 CinemaService.searchCacheLifetime）。
    final fresh = !_searching && _result != null && _searched == keyword;
    _cancel?.complete();
    final cancel = _cancel = Completer<void>();
    final generation = ++_generation;
    setState(() {
      _message = null;
      _searched = keyword;
    });
    _setSearching(true);
    try {
      // 边搜边显示（人工决策见 cinema_service.dart 的 pauseAfter）：每回来一个源换一份快照。
      await for (final result in _service.search(keyword, cancel: cancel.future, fresh: fresh)) {
        if (!mounted || generation != _generation) return;
        setState(() => _result = result);
      }
    } catch (error, stack) {
      campusLog('[Cinema] action=search errorType=${error.runtimeType}\n$stack');
      if (mounted && generation == _generation) setState(() => _message = '搜索没完成，稍后再试');
    } finally {
      if (mounted && generation == _generation) _setSearching(false);
    }
  }

  // [人工决策-2026-11-21 11:59:29] 搜索结果点开一律进选集页（用户选「保持选集页」，没选单集电影点卡片直接播）：直接播等于替用户选了源，
  // 不合「由用户选源」；选集页已预取接着看那一集的播放列表，点一集就快。
  Future<void> _openTitle(CinemaTitle title) async {
    await Navigator.push<void>(context, CampusPageRoute(builder: (_) => CinemaDetailPage(service: _service, title: title)));
    await _reloadHistory();
  }

  // 看过的：按记下的源直接接着播，看完了的（CinemaHistory.finished）从下一集开头播，没有下一集时播放页落回这一集从头；
  // 源坏了或已不在规则包里，播放页报错并可「找其他片源」（人工决策见 CinemaService.findMoreSources）。
  // [人工决策-2026-11-21 13:37:52] 先用本机记下的别的源（11-21 Codex 总交接第 6.5 节，用户说按最佳实践做）：看的时候把这部片的各个源记在本机
  // （cinema_store.dart 的 title_source，跟着看过的记录删），续播时一起放进片源菜单，记的源坏了直接换，记下的都不行再「找其他片源」联网搜。
  Future<void> _resume(CinemaHistory entry) async {
    final title = CinemaTitle(key: entry.key, name: entry.name, year: '', cover: entry.cover, remarks: '');
    final source = CinemaSourceRef(ruleId: entry.ruleId, source: entry.source, name: entry.name, remarks: '');
    title.addSource(source);
    try {
      for (final known in await _service.store.titleSources(entry.key)) {
        title.addSource(known);
      }
    } catch (error, stack) {
      campusLog('[Cinema] action=title_sources errorType=${error.runtimeType}\n$stack');
    }
    if (!mounted) return;
    final finished = entry.finished;
    await Navigator.push<void>(
      context,
      CampusPageRoute(
        builder: (_) => CinemaPlayerPage.title(service: _service, title: title, source: source, road: entry.road, episode: finished ? entry.episode + 1 : entry.episode, start: finished ? Duration.zero : entry.position),
      ),
    );
    await _reloadHistory();
  }

  // 看过的一条：⋯ 里只有删除（警示色，先确认），只删本机这条记录。
  Future<void> _historyMenu(BuildContext anchor, CinemaHistory entry) async {
    final picked = await showCampusMenu<bool>(anchor, items: const [CampusMenuItem(value: true, label: '删除', icon: CampusIcons.delete, destructive: true)]);
    if (picked != true || !mounted) return;
    final agreed = await showCampusConfirm(context, title: '删除这条记录', message: '「${entry.name}」看到哪也一起删掉。', action: '删除', destructive: true);
    if (!agreed) return;
    try {
      await _service.store.deleteHistory(entry.key);
    } catch (error, stack) {
      campusLog('[Cinema] action=delete_history errorType=${error.runtimeType}\n$stack');
      if (mounted) showCampusToast(context, '没删掉，稍后再试');
      return;
    }
    await _reloadHistory();
  }

  @override
  void dispose() {
    _cancel?.complete();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SliverMainAxisGroup(
    slivers: [
      SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 16), sliver: SliverToBoxAdapter(child: _header(context))),
      ..._searchSlivers(context),
    ],
  );

  Widget _header(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: CampusSearchField(controller: _query, hint: '片名', onSubmitted: (_) => _search())),
          const SizedBox(width: CampusGap.small),
          FilledButton(
            style: campusProminent,
            onPressed: _searching ? null : _search,
            child: CampusBusyContent(busy: _searching, label: '搜索', busyLabel: '搜索中', icon: const CampusIcon(CampusIcons.search)),
          ),
        ],
      ),
      if (_message case final message?)
        Padding(
          padding: const EdgeInsets.only(top: CampusGap.medium),
          child: Text(message, style: TextStyle(color: CampusPalette.of(context).danger)),
        ),
    ],
  );

  // [人工决策-2026-11-20 22:54:48] 「看过的」改成横向海报条（同腾讯视频、Netflix 的「继续观看」；用户从两种排法里选的，没选「竖列表加进度条」）：
  // 海报底边是看到哪的进度，⋯ 里删除这条（先确认）；最多 cinemaHistoryLimit 条都在这一行横滑，首页不再被拉得很长，海报只取看得见的几张。
  List<Widget> _historySlivers(BuildContext context) {
    if (_history.isEmpty) return const [];
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        sliver: SliverToBoxAdapter(child: Text('看过的', style: Theme.of(context).textTheme.titleMedium)),
      ),
      SliverToBoxAdapter(
        child: SizedBox(
          height: CinemaHistoryCard.heightOf(context),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: CampusGap.large),
            itemCount: _history.length,
            separatorBuilder: (_, _) => const SizedBox(width: CampusGap.medium),
            itemBuilder: (context, index) {
              final entry = _history[index];
              return CinemaHistoryCard(
                key: ValueKey(entry.key),
                cover: entry.cover,
                title: entry.name,
                episode: entry.episodeName,
                progress: entry.duration > Duration.zero ? entry.position.inMilliseconds / entry.duration.inMilliseconds : null,
                onTap: () => unawaited(_resume(entry).catchError((Object error, StackTrace stack) => campusLog('[Cinema] action=resume errorType=${error.runtimeType}\n$stack'))),
                onMore: (anchor) => unawaited(_historyMenu(anchor, entry)),
              );
            },
          ),
        ),
      ),
    ];
  }

  List<Widget> _searchSlivers(BuildContext context) {
    final palette = CampusPalette.of(context);
    final text = Theme.of(context).textTheme;
    final result = _result;
    if (_searching && (result == null || (result.titles.isEmpty && result.pending > 0))) {
      return [SliverPadding(padding: const EdgeInsets.only(top: CampusGap.section), sliver: SliverToBoxAdapter(child: CampusLoading(label: '正在搜索', inline: true, network: true, remote: '片源站')))];
    }
    if (result == null) return _historySlivers(context);
    final failed = {for (final kind in CinemaFailureKind.values) kind: [for (final failure in result.failures) if (failure.kind == kind) failure.name]};
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
              for (final MapEntry(key: kind, value: names) in failed.entries)
                if (names.isNotEmpty) ...[
                  const SizedBox(height: CampusGap.tight),
                  DotSeparatedText('${_failureLabels[kind]}：${names.join('、')}', separator: '、', style: text.bodyMedium!.copyWith(color: palette.onSurfaceVariant)),
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
                // 分类写在年份后面（同名的正片、纪录片、解说靠它分开，11-21 Codex 总交接第 6.6 节）。
                [if (title.year.isNotEmpty) title.year, if (title.category.isNotEmpty) title.category, if (title.remarks.isNotEmpty) title.remarks].join(' · '),
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
