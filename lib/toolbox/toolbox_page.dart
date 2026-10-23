import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_module.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';
import 'package:superxd/domain/campus_log.dart';

class ToolboxPage extends StatefulWidget {
  const ToolboxPage({super.key, required this.runtime, this.modules});
  final ToolboxRuntime runtime;
  final List<ToolboxModule>? modules;
  @override
  State<ToolboxPage> createState() => _ToolboxPageState();
}

class _ToolboxPageState extends State<ToolboxPage> {
  late Future<void> _ready = widget.runtime.initialize();
  late final _modules = widget.modules ?? widget.runtime.modules;
  final _busy = <String>{};
  String? _error;

  Future<void> _operation(String id, Future<void> Function() action) async {
    if (_busy.contains(id)) return;
    setState(() {
      _busy.add(id);
      _error = null;
    });
    try {
      await action();
    } catch (error, stack) {
      campusLog(
        '[Toolbox] action=manage errorType=${error.runtimeType}\n$stack',
      );
      if (mounted) {
        setState(
          () =>
              _error = error is ToolboxException ? error.message : '操作未完成，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _uninstall(ToolboxModule module) async {
    final agreed = await showCampusConfirm(
      context,
      title: '卸载${module.name}？',
      message: '将取消本工具任务并移除资源，已保存的视频保留。',
      action: '卸载', destructive: true,
    );
    if (agreed && mounted) {
      await _operation(
        module.id,
        () => widget.runtime.downloads.uninstall(module.id),
      );
    }
  }

  // [人工决策-2026-10-09 20:32:45] 有自己本机数据的工具（登记了 openService）可「清除数据」：同 iOS 删除 App 时连数据一起删。
  // 不叫卸载（轻量代码随应用发布，不伪装可卸载），点了要确认。用户选定「框架统一契约」。入口形态见 _tile 的 2026-10-23 决策。
  Future<void> _clearData(ToolboxModule module) async {
    final agreed = await showCampusConfirm(
      context,
      title: '清除${module.name}的数据？',
      message: '会删除本机保存的${module.clearedData}；已保存到相册或下载目录的文件保留。',
      action: '清除', destructive: true,
    );
    if (agreed && mounted) {
      await _operation(module.id, () => widget.runtime.clearData(module.id));
      if (mounted && _error == null) showCampusToast(context, '已清除${module.name}的数据');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        tooltip: '返回',
        icon: const CampusIcon(CampusIcons.back),
        onPressed: () => context.pop(),
      ),
      title: const Text('百宝箱'),
    ),
    body: CampusScrollFade(child: SafeArea(
      child: FutureBuilder<void>(
        future: _ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return CampusLoadError(
              message: '百宝箱暂未就绪',
              onRetry: () => setState(() {
                _ready = widget.runtime.initialize();
              }),
            );
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CampusLoading(label: '正在准备百宝箱'));
          }
          return ListenableBuilder(
            listenable: widget.runtime.downloads,
            builder: (context, _) => SlidableAutoCloseBehavior(child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      _error!,
                      style: TextStyle(color: CampusPalette.of(context).danger),
                    ),
                  ),
                for (final module in _modules)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _tile(module),
                  ),
              ],
            )),
          );
        },
      ),
    )),
  );

  Widget _tile(ToolboxModule module) {
    final manager = widget.runtime.downloads;
    final installed =
        module.resource == null || manager.resources.installed(module.id);
    final task = manager
        .forTool(module.id)
        .where((download) => !download.terminal)
        .firstOrNull;
    final busy = _busy.contains(module.id);
    final colors = CampusPalette.of(context);
    // 入口卡与服务页的入口卡同一规格：内边距20、图标与文字间距20、内容至少40高。
    final card = CampusSurface(
      padding: const EdgeInsets.all(20),
      onTap: installed && !busy
          ? () => context.push('/toolbox/${module.id}')
          : null,
      child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 40), child: Row(
        children: [
          CampusIcon(module.icon, size: 28, color: colors.primary),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(module.name, style: const TextStyle(fontSize: 16)),
                if (task != null) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: task.totalBytes > 0 ? task.progress : null,
                  ),
                ],
                if (!installed && task == null)
                  Text(
                    '${(module.resource!.bytes / (1024 * 1024)).toStringAsFixed(1)} MB',
                    style: TextStyle(
                      fontSize: 14,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (installed)
            const CampusIcon(CampusIcons.next)
          else if (task != null)
            IconButton(
              tooltip: '取消下载',
              onPressed: busy
                  ? null
                  : () => _operation(module.id, () => manager.cancel(task.id)),
              icon: const CampusIcon(CampusIcons.close),
            )
          else
            IconButton(
              tooltip: '下载资源',
              onPressed: busy
                  ? null
                  : () => _operation(module.id, () async {
                      await manager.downloadResource(module.id);
                    }),
              icon: const CampusIcon(CampusIcons.download),
            ),
        ],
      )),
    );
    final uninstallable = module.resource != null && installed;
    final clearable = module.openService != null;
    if (!uninstallable && !clearable) return card;
    final label = uninstallable ? '卸载' : '清除数据';
    void act() => uninstallable ? _uninstall(module) : _clearData(module);
    // [人工决策-2026-09-27 20:12:08] 滑动只揭示按钮，必须点击确认；不以滑动距离直接删除。
    // [人工决策-2026-10-23 16:48:13] 用户选「去掉⋯、改左滑」（取代 09-27 的右滑与 10-09 的「⋯与右滑两个入口」）：
    // 两个入口做同一件事是冗余；向左滑露出右侧的按钮，同微信会话、iOS 邮件左滑删除，也不和 Android 从左边缘右滑的返回手势抢。
    // 卡片右侧统一是「›」；按钮是与卡片同圆角的独立圆角块、和卡片留一道缝（以前是贴边的直角红块，按下还冒出一个圆斑）。
    // 读屏用户滑不了，把同一个操作挂在卡片的读屏操作菜单里。
    return MergeSemantics(
      child: Semantics(
        customSemanticsActions: busy ? null : {CustomSemanticsAction(label: label): act},
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = _SwipeAction.widthFor(context, label);
            return Slidable(
              key: ValueKey(module.id),
              groupTag: _slideGroup,
              endActionPane: ActionPane(
                motion: const BehindMotion(),
                extentRatio: (width / constraints.maxWidth).clamp(.2, .6),
                children: [_SwipeAction(label: label, icon: CampusIcons.delete, onPressed: busy ? null : act)],
              ),
              child: card,
            );
          },
        ),
      ),
    );
  }
}

// 同一时刻只开着一张卡的滑动按钮：滑开另一张时前一张自动合上（同微信会话列表）。
const _slideGroup = 'toolbox';

// 卡片左滑露出的按钮：与卡片同圆角、同高的警示红圆角块，左边和卡片之间留一道缝；按下整块变暗（全应用的按压反馈），不冒水波。
class _SwipeAction extends StatelessWidget {
  const _SwipeAction({required this.label, required this.icon, required this.onPressed});
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  static const gap = 8.0;
  static const radius = 24.0;
  static const _style = TextStyle(fontSize: 14, fontWeight: FontWeight.w600);

  // 按钮宽度按文字实际宽度算（大字号下不折行），再加左右内边距与那道缝。
  static double widthFor(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: DefaultTextStyle.of(context).style.merge(_style)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return gap + width + 2 * 20;
  }

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    final onPressed = this.onPressed;
    return Expanded(
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: gap),
        child: Material(
          color: colors.dangerFill.withValues(alpha: onPressed == null ? .6 : 1),
          borderRadius: BorderRadius.circular(radius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed == null
                ? null
                : () {
                    Slidable.of(context)?.close();
                    onPressed();
                  },
            child: Semantics(
              button: true,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CampusIcon(icon, size: 22, color: Colors.white),
                  const SizedBox(height: 6),
                  Text(label, maxLines: 1, softWrap: false, style: _style.copyWith(color: Colors.white)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
