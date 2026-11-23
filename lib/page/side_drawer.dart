import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/application/quick_nav.dart';
import 'package:superxd/domain/quick_nav.dart';
import 'package:superxd/page/quick_edit_page.dart';
import 'package:superxd/page/quick_entry.dart';
import 'package:superxd/page/splash_signature.dart';
import 'package:superxd/theme/campus_fog_scroll.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_pull_button.dart';
import 'package:superxd/theme/campus_search_field.dart';
import 'package:superxd/theme/campus_side_drawer.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';

// [人工决策-2026-11-23 18:29:13] 今天页侧栏（用户 11-23 参照 Claude 应用的录屏提出，四项都选推荐）：点今天页左上角圆钮或在今天页从左往右滑拉出；
// 侧栏左上角是开屏那笔「SuperXD」签名（每次启动后第一次打开时写一遍），列表滚到它下面时越往上越淡、完整玻璃档另渐进模糊（融进云雾），签名一直浮在上面；
// 两组：常用（用户勾选与排序，没编辑过用组合根给的默认）与最近（自动记最近进过的几个，已在常用里的不重复列）；
// 在列表顶上往下拉：右上角搜索钮描一圈、到位铺满激活色展开成「搜索」胶囊并轻震，松手进搜索（侧栏展开成整屏，搜索钮原地变关闭钮，输入框从它左边长出来）。
// 没选：两行大标题、按钮插在「今天」前（顶栏）；只有常用、常用加全部分类（分组）；普通文字、问候语（左上角）；所有档位只淡出（云雾）。
// [人工决策-2026-11-23 21:08:21] 用户真机看过后改（取代上条的左上角与底部）：签名笔画 1.8 倍嫌粗，改 1.6 倍（用户自己试的）；签名为主、Newsreader 斜体为次，
// 跟着列表滚动切换（同 iOS 大标题收成小标题：在顶上是签名，往上滚、内容滑进雾里时签名淡出收小、Newsreader 小一号淡入，滚回顶上换回，过渡跟手、先淡出再淡入）；
// 没选点一下切换、写完签名后换成 Newsreader。底部「我的」那一行嫌冗余，删掉。Anthropic 自己的衬线体是商用字体，开源仓库不能打包，选了气质相近的 OFL 字体 Newsreader。
class SideDrawerPanel extends StatefulWidget {
  const SideDrawerPanel({super.key, required this.catalog, required this.nav});
  final QuickCatalog catalog;
  final QuickNav nav;

  @override
  State<SideDrawerPanel> createState() => _SideDrawerPanelState();
}

const _headerHeight = 64.0;
// 往下拉多远算到位。
const _pullDistance = 72.0;
// 往上滚多远签名完全换成 Newsreader。
const _collapseDistance = 48.0;
// 签名这次运行写过没有（每次启动后第一次打开侧栏写一遍）。
var _signatureWritten = false;

class _SideDrawerPanelState extends State<SideDrawerPanel> with SingleTickerProviderStateMixin {
  final _pull = ValueNotifier<double>(0);
  // 列表往上滚了多远（左上角签名换成 Newsreader 的进度跟着它）。
  final _scroll = ValueNotifier<double>(0);
  final _settled = ValueNotifier<bool>(true);
  final _query = TextEditingController();
  final _focus = FocusNode();
  late final _ink = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800), value: _signatureWritten ? 1 : 0);
  CampusSideDrawerState? _drawer;
  bool _armed = false;
  final _changes = <StreamSubscription<void>>[];

  @override
  void initState() {
    super.initState();
    // 解锁、灰度变了，看得见的入口跟着变。
    for (final changes in widget.catalog.changes) {
      _changes.add(changes.listen((_) => setState(() {})));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final drawer = CampusSideDrawer.maybeOf(context);
    if (drawer == _drawer) return;
    _detach();
    _drawer = drawer?..progress.addListener(_progressed)..expanded.addListener(_searchChanged)..expansion.addStatusListener(_expansionStatus);
  }

  void _detach() => _drawer
    ?..progress.removeListener(_progressed)
    ..expanded.removeListener(_searchChanged)
    ..expansion.removeStatusListener(_expansionStatus);

  @override
  void dispose() {
    _detach();
    for (final subscription in _changes) {
      unawaited(subscription.cancel());
    }
    _pull.dispose();
    _scroll.dispose();
    _settled.dispose();
    _query.dispose();
    _focus.dispose();
    _ink.dispose();
    super.dispose();
  }

  void _progressed() {
    final progress = _drawer?.progress.value ?? 0;
    // 合上了：拉到一半的下拉不作数（回弹跟着侧栏停在半路，圈会停在那里）。
    if (progress == 0) _resetPull();
    _write(progress);
  }

  // 拉出过半时开始写签名（这次运行只写一遍；减少动画时直接写好）。
  void _write(double progress) {
    if (_signatureWritten || progress < .5) return;
    _signatureWritten = true;
    MediaQuery.disableAnimationsOf(context) ? _ink.value = 1 : _ink.forward(from: 0);
  }

  void _expansionStatus(AnimationStatus status) => _settled.value = status.isCompleted || status.isDismissed;

  // 进搜索弹键盘：输入框这一帧才建出来，等它建好下一帧再要焦点（对着还没接上的节点要焦点，接上后不会打开输入法，模拟器上试过）。
  void _searchChanged() {
    if (_drawer?.expanded.value ?? false) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (_drawer?.expanded.value ?? false)) _focus.requestFocus();
      });
    } else {
      _focus.unfocus();
      _query.clear();
      // 列表退出搜索时是重新建的、在顶上：下拉的圈与滚动进度都从头算（不然停在松手进搜索那一刻的回弹进度上，11-23 用户录屏）。
      _resetPull();
      _scroll.value = 0;
    }
  }

  void _resetPull() {
    _armed = false;
    _pull.value = 0;
  }

  void _search(bool value) {
    _resetPull();
    _drawer?.expand(value);
  }

  // 列表顶上往下拉：手指拖着时按拉了多远描圈，到位轻震一下；拉回去不到位就取消。松手回弹时圈跟着退。
  // 进了搜索就不再跟（列表淡出时还在回弹，跟着会把圈停在半路）；往上滚了多远交给左上角的字样。
  bool _scrolled(ScrollNotification notification) {
    if (notification.depth != 0 || (_drawer?.expanded.value ?? false)) return false;
    _scroll.value = math.max(0, notification.metrics.pixels - notification.metrics.minScrollExtent);
    final over = notification.metrics.minScrollExtent - notification.metrics.pixels;
    final pull = over > 0 ? over / _pullDistance : 0.0;
    final dragging = (notification is ScrollUpdateNotification && notification.dragDetails != null) || (notification is OverscrollNotification && notification.dragDetails != null);
    if (dragging && pull >= 1 != _armed) {
      _armed = pull >= 1;
      if (_armed) HapticFeedback.mediumImpact();
    }
    _pull.value = _armed ? 1 : math.min(pull, .99);
    return false;
  }

  void _released() {
    if (_armed) _search(true);
  }

  void _go(QuickEntry entry) {
    _focus.unfocus();
    widget.nav.visit(entry.id);
    _drawer?.dismissWhenCovered();
    entry.open(context);
  }

  void _edit() => Navigator.of(context, rootNavigator: true).push(CampusPageRoute<void>(builder: (context) => QuickEditPage(catalog: widget.catalog, nav: widget.nav)));

  @override
  Widget build(BuildContext context) {
    final drawer = _drawer!;
    return Material(
      type: MaterialType.transparency,
      child: ListenableBuilder(
        listenable: Listenable.merge([widget.nav, drawer.expanded, _settled]),
        builder: (context, _) {
          final searching = drawer.expanded.value;
          final entries = widget.catalog.entries();
          final byId = {for (final entry in entries) entry.id: entry};
          final pinnedIds = widget.nav.prefs.pinned ?? widget.catalog.defaults;
          final pinned = [for (final id in pinnedIds) ?byId[id]];
          final recent = [for (final id in widget.nav.prefs.recent) if (!pinnedIds.contains(id)) ?byId[id]];
          final home = _home(pinned, recent, blur: !searching && _settled.value);
          final results = _Results(entries: entries, recent: [for (final id in widget.nav.prefs.recent) ?byId[id]], query: _query, onOpen: _go, blur: searching && _settled.value);
          return AnimatedBuilder(
            animation: drawer.expansion,
            builder: (context, _) {
              final t = drawer.expansion.value.clamp(0.0, 1.0);
              // 列表与搜索结果先淡出再淡入（fade through，同 Material 的同级切换），不同时半透明叠出重影：前四成列表淡完，后六成结果淡入。
              final leaving = Curves.easeOut.transform((t / .4).clamp(0.0, 1.0)), arriving = Curves.easeOut.transform(((t - .4) / .6).clamp(0.0, 1.0));
              return Stack(children: [
                // 各层带键：一层出现或拿掉时别的层按键对上，不按位置错配（错配会把顶上一行重建掉，输入框断了输入法连接、键盘收起）。
                if (leaving < 1)
                  Positioned.fill(key: const ValueKey('home'), child: IgnorePointer(ignoring: searching, child: Opacity(opacity: 1 - leaving, child: Transform.translate(offset: Offset(0, 24 * leaving), child: home)))),
                if (arriving > 0)
                  Positioned.fill(key: const ValueKey('results'), child: IgnorePointer(ignoring: !searching, child: Opacity(opacity: arriving, child: Transform.translate(offset: Offset(0, 16 * (1 - arriving)), child: results)))),
                Positioned(key: const ValueKey('header'), left: 0, right: 0, top: MediaQuery.paddingOf(context).top, height: _headerHeight, child: _header(t, searching)),
              ]);
            },
          );
        },
      ),
    );
  }

  Widget _home(List<QuickEntry> pinned, List<QuickEntry> recent, {required bool blur}) {
    final padding = MediaQuery.paddingOf(context);
    return CampusFogScroll(
      header: const SizedBox.shrink(),
      headerHeight: _headerHeight,
      blur: blur,
      child: Listener(
        onPointerUp: (_) => _released(),
        onPointerCancel: (_) => _armed = false,
        child: NotificationListener<ScrollNotification>(
          onNotification: _scrolled,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.only(top: padding.top + _headerHeight, bottom: padding.bottom + CampusGap.large),
                sliver: SliverList.list(children: [
                  _Heading(label: '常用', action: TextButton(
                    style: campusLink,
                    onPressed: _edit,
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [Text('编辑'), SizedBox(width: CampusGap.tight), CampusIcon(CampusIcons.next, size: 18)]),
                  )),
                  if (pinned.isEmpty) _EntryRow(icon: CampusIcons.add, title: '添加常用', onTap: _edit),
                  for (final entry in pinned) _EntryRow(key: ValueKey('pinned-${entry.id}'), icon: entry.icon, title: entry.title, onTap: () => _go(entry)),
                  if (recent.isNotEmpty) ...[
                    const SizedBox(height: CampusGap.small),
                    const _Heading(label: '最近'),
                    for (final entry in recent) _EntryRow(key: ValueKey('recent-${entry.id}'), icon: entry.icon, title: entry.title, onTap: () => _go(entry)),
                  ],
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 顶上一行：左边字样（签名，列表往上滚时换成 Newsreader；搜索时淡出上移），右边搜索钮（搜索时原地变关闭钮），搜索时输入框从按钮左边长出来。
  Widget _header(double t, bool searching) {
    final palette = CampusPalette.of(context);
    final eased = Curves.easeOutCubic.transform(t);
    // 签名同列表一起在前四成淡完，输入框长过来时不压在还看得见的签名上。
    final leaving = Curves.easeOut.transform((t / .4).clamp(0.0, 1.0));
    return LayoutBuilder(builder: (context, constraints) {
      const button = 44.0, side = 12.0, gap = 8.0;
      final field = math.max(0.0, constraints.maxWidth - CampusGap.large - side - button - gap);
      return Stack(children: [
        if (leaving < 1)
          Positioned(key: const ValueKey('wordmark'), left: 20, top: 0, bottom: 0, child: IgnorePointer(child: Opacity(
            opacity: 1 - leaving,
            child: Transform.translate(offset: Offset(0, -10 * leaving), child: Center(child: ValueListenableBuilder<double>(
              valueListenable: _scroll,
              builder: (context, scroll, _) => _Wordmark(ink: _ink, colors: (palette.onSurface, palette.accentText), collapse: (scroll / _collapseDistance).clamp(0.0, 1.0)),
            ))),
          ))),
        if (t > 0 || searching)
          Positioned(key: const ValueKey('field'), right: side + button + gap, top: 0, bottom: 0, width: field, child: Center(child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: Align(
              alignment: Alignment.centerRight,
              widthFactor: eased,
              child: Opacity(opacity: Curves.easeIn.transform(t), child: SizedBox(width: field, child: CampusSearchField(controller: _query, focusNode: _focus, hint: '搜索页面和功能'))),
            ),
          ))),
        Positioned(key: const ValueKey('button'), right: side, top: 0, bottom: 0, child: Center(child: ValueListenableBuilder<double>(
          valueListenable: _pull,
          builder: (context, pull, _) => CampusPullButton(
            icon: searching ? CampusIcons.close : CampusIcons.search,
            label: searching ? '关闭搜索' : '搜索',
            caption: '搜索',
            pull: searching ? 0 : pull,
            onPressed: () => _search(!searching),
          ),
        ))),
      ]);
    });
  }
}

// 左上角的字样：签名为主、Newsreader 斜体为次（人工决策见 SideDrawerPanel 上 11-23 21:08:21 那条）。collapse 是列表往上滚的进度（0 在顶上、1 滚过 _collapseDistance）：
// 签名在前六成淡完并收小上移，Newsreader 后六成从下面一点淡入并放到原大（先淡出再淡入，不同时半透明叠出重影），跟着手指走、不自己播。
// 签名高 34、宽按比例，笔画 1.6 倍（小尺寸的光学补偿，用户试过）；两种墨色都从正文色渐变到激活色（同开屏取画作最冷最暖两色的意思，这里取配色）。读屏只读一遍名字。
class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.ink, required this.colors, required this.collapse});
  final Animation<double> ink;
  final (Color, Color) colors;
  final double collapse;

  @override
  Widget build(BuildContext context) {
    final bounds = SplashSignature.shared.bounds;
    const height = 34.0;
    final leaving = Curves.easeOut.transform((collapse / .6).clamp(0.0, 1.0)), arriving = Curves.easeOut.transform(((collapse - .4) / .6).clamp(0.0, 1.0));
    return Semantics(
      label: 'SuperXD',
      header: true,
      child: ExcludeSemantics(child: Stack(alignment: Alignment.centerLeft, clipBehavior: Clip.none, children: [
        if (leaving < 1)
          Opacity(opacity: 1 - leaving, child: Transform.scale(
            scale: 1 - .14 * leaving,
            alignment: Alignment.centerLeft,
            child: Transform.translate(
              offset: Offset(0, -4 * leaving),
              child: SizedBox(
                width: height * bounds.width / bounds.height,
                height: height,
                child: AnimatedBuilder(animation: ink, builder: (context, _) => CustomPaint(painter: SplashSignaturePainter(progress: ink.value, ink: colors, weight: 1.6))),
              ),
            ),
          )),
        if (arriving > 0)
          Opacity(opacity: arriving, child: Transform.scale(
            scale: .94 + .06 * arriving,
            alignment: Alignment.centerLeft,
            child: Transform.translate(
              offset: Offset(0, 6 * (1 - arriving)),
              // 斜体最后一个字母往右探出字框，右边留几像素，不被渐变的范围切掉。
              child: ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (rect) => LinearGradient(colors: [colors.$1, colors.$2]).createShader(rect),
                child: const Padding(
                  padding: EdgeInsets.only(right: CampusGap.small),
                  child: Text('SuperXD', maxLines: 1, softWrap: false, style: TextStyle(fontFamily: 'Newsreader', fontStyle: FontStyle.italic, fontSize: CampusFontSize.headline, height: 1, color: Colors.white)),
                ),
              ),
            ),
          )),
      ])),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.label, this.action});
  final String label;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 12, 0),
    child: SizedBox(height: 40, child: Row(children: [
      Expanded(child: Semantics(header: true, child: Text(label, style: TextStyle(fontSize: CampusFontSize.secondary, color: CampusPalette.of(context).onSurfaceVariant)))),
      ?action,
    ])),
  );
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({super.key, required this.icon, required this.title, required this.onTap, this.trailing});
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return ListTile(
      onTap: onTap,
      visualDensity: const VisualDensity(vertical: -2),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      minLeadingWidth: 20,
      horizontalTitleGap: 14,
      leading: CampusIcon(icon, size: 20, color: palette.onSurfaceVariant),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: CampusFontSize.body, color: palette.onSurface)),
      trailing: trailing == null ? null : Text(trailing!, style: TextStyle(fontSize: CampusFontSize.secondary, color: palette.onSurfaceVariant)),
    );
  }
}

// 搜索：空查询列最近使用与全部（按分组），有字时按名字与别名排（名字开头的最前）、每行写分组；搜不到写一行。
class _Results extends StatelessWidget {
  const _Results({required this.entries, required this.recent, required this.query, required this.onOpen, required this.blur});
  final List<QuickEntry> entries;
  final List<QuickEntry> recent;
  final TextEditingController query;
  final ValueChanged<QuickEntry> onOpen;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return CampusFogScroll(
      header: const SizedBox.shrink(),
      headerHeight: _headerHeight,
      blur: blur,
      child: ListenableBuilder(
        listenable: query,
        builder: (context, _) {
          final text = query.text;
          final List<Widget> rows;
          if (text.trim().isEmpty) {
            final groups = <String, List<QuickEntry>>{};
            for (final entry in entries) {
              (groups[entry.group] ??= []).add(entry);
            }
            rows = [
              if (recent.isNotEmpty) ...[
                const _Heading(label: '最近使用'),
                for (final entry in recent) _EntryRow(key: ValueKey('recent-${entry.id}'), icon: entry.icon, title: entry.title, onTap: () => onOpen(entry)),
              ],
              for (final MapEntry(key: group, value: members) in groups.entries) ...[
                _Heading(label: group),
                for (final entry in members) _EntryRow(key: ValueKey('all-${entry.id}'), icon: entry.icon, title: entry.title, onTap: () => onOpen(entry)),
              ],
            ];
          } else {
            final ranked = [
              for (final (index, entry) in entries.indexed)
                if (quickNavRank(text, entry.title, entry.keywords) case final rank?) (rank: rank, index: index, entry: entry),
            ]..sort((a, b) => a.rank != b.rank ? a.rank.compareTo(b.rank) : a.index.compareTo(b.index));
            rows = ranked.isEmpty
                ? [Padding(padding: const EdgeInsets.all(CampusGap.section), child: Text('没有找到', textAlign: TextAlign.center, style: TextStyle(fontSize: CampusFontSize.body, color: CampusPalette.of(context).onSurfaceVariant)))]
                : [for (final item in ranked) _EntryRow(key: ValueKey('found-${item.entry.id}'), icon: item.entry.icon, title: item.entry.title, trailing: item.entry.group, onTap: () => onOpen(item.entry))];
          }
          return CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.only(top: media.padding.top + _headerHeight, bottom: math.max(media.viewInsets.bottom, media.padding.bottom) + CampusGap.large),
                sliver: SliverList.list(children: rows),
              ),
            ],
          );
        },
      ),
    );
  }
}
