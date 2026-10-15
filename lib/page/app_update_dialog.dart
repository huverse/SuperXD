import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:superxd/application/app_updates.dart';
import 'package:superxd/domain/app_update.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_transitions.dart';

// 安装包大小：10MB 以下保留一位小数。
String appPackageSize(int bytes) => '${(bytes / 1048576).toStringAsFixed(bytes < 10 * 1048576 ? 1 : 0)} MB';

Future<bool> _launch(Uri url) => launchUrl(url, mode: LaunchMode.externalApplication);

// [人工决策-2026-10-15 14:06:35] 更新弹窗（同大厂做法）：显示版本、安装包大小与更新说明；可选更新给「更新」「稍后」「跳过这个版本」，
// 点更新才下载，进度、校验、等授权、安装都在弹窗里原地切换，下载中可「后台下载」收起；必须更新时遮罩与返回键都关不掉，只留更新相关的操作。
// 下载失败或没有这个架构的安装包时给浏览器打开发布页。
Future<void> showAppUpdateDialog(BuildContext context, AppUpdates updates, {Future<bool> Function(Uri url)? openUrl}) {
  final forced = updates.urgency == AppUpdateUrgency.forced;
  return showCampusDialog<void>(
    context: context,
    barrierDismissible: !forced,
    builder: (context) => PopScope(
      canPop: !forced,
      child: ListenableBuilder(listenable: updates, builder: (context, _) => _AppUpdateDialog(updates: updates, forced: forced, openUrl: openUrl ?? _launch)),
    ),
  );
}

class _AppUpdateDialog extends StatelessWidget {
  const _AppUpdateDialog({required this.updates, required this.forced, required this.openUrl});
  final AppUpdates updates;
  final bool forced;
  final Future<bool> Function(Uri url) openUrl;

  Future<void> _openReleasePage(BuildContext context, Uri page) async {
    var opened = false;
    try {
      opened = await openUrl(page);
    } catch (error, stack) {
      campusLog('[AppUpdate] action=open_release_page errorType=${error.runtimeType}\n$stack');
    }
    if (!opened && context.mounted) await showCampusNotice(context, '没有可打开链接的浏览器。\n$page');
  }

  @override
  Widget build(BuildContext context) {
    final release = updates.release!;
    final apk = release.apk;
    final palette = CampusPalette.of(context);
    final phase = updates.phase;
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    // 版本号放说明行不放标题：标题里的「1.0.0-alpha.4」会在连字符处折行。
    final summary = [
      ['版本 ${release.versionName}', if (apk != null) '安装包 ${appPackageSize(apk.size)}'].join(' · '),
      if (forced) '当前版本已停用，更新后才能使用',
    ];
    // 图标对齐首行文字，多行时不悬在中间。
    Widget line(IconData icon, String text, {bool warning = false}) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 2), child: CampusIcon(icon, size: 18, color: warning ? palette.danger : palette.onSurfaceVariant)),
      const SizedBox(width: 6),
      Expanded(child: Text(text, style: TextStyle(color: warning ? palette.danger : palette.onSurfaceVariant, fontWeight: FontWeight.w600))),
    ]);
    final status = switch (phase) {
      AppUpdatePhase.downloading => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        line(CampusIcons.download, '正在下载 ${(updates.progress * 100).floor()}%'),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: updates.progress, borderRadius: BorderRadius.circular(4)),
        if (apk != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('${(updates.progress * apk.size / 1048576).toStringAsFixed(1)} / ${(apk.size / 1048576).toStringAsFixed(1)} MB', style: secondary),
          ),
      ]),
      AppUpdatePhase.verifying => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        line(CampusIcons.download, '正在核对安装包'),
        const SizedBox(height: 8),
        LinearProgressIndicator(borderRadius: BorderRadius.circular(4)),
      ]),
      AppUpdatePhase.needsPermission => line(CampusIcons.warning, '要先允许 SuperXD 安装应用，开启后返回会接着安装'),
      AppUpdatePhase.readyToInstall => line(CampusIcons.success, '安装包已核对，按系统提示完成安装'),
      AppUpdatePhase.failed => line(CampusIcons.warning, updates.error ?? '更新没完成，请重试', warning: true),
      _ => null,
    };
    final later = TextButton(onPressed: () => Navigator.pop(context), child: const Text('稍后'));
    final browser = TextButton(onPressed: () => _openReleasePage(context, release.releasePage), child: const Text('浏览器下载'));
    final actions = switch (phase) {
      _ when apk == null => [if (!forced) later, FilledButton(onPressed: () => _openReleasePage(context, release.releasePage), child: const Text('去发布页下载'))],
      AppUpdatePhase.downloading => [
        TextButton(onPressed: updates.cancel, child: const Text('取消下载')),
        if (!forced) TextButton(onPressed: () => Navigator.pop(context), child: const Text('后台下载')),
      ],
      AppUpdatePhase.verifying => <Widget>[],
      AppUpdatePhase.needsPermission => [if (!forced) later, FilledButton(onPressed: updates.openInstallSettings, child: const Text('去开启'))],
      AppUpdatePhase.readyToInstall => [if (!forced) later, FilledButton(onPressed: updates.install, child: const Text('安装'))],
      AppUpdatePhase.failed => [browser, FilledButton(onPressed: updates.update, child: const Text('重试'))],
      _ => [
        if (!forced) ...[
          TextButton(
            onPressed: () async {
              await updates.skip();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('跳过这个版本'),
          ),
          later,
        ],
        FilledButton(onPressed: updates.update, child: const Text('更新')),
      ],
    };
    return CampusGlassDialog(
      title: Text(forced ? '需要更新' : '发现新版本'),
      content: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (summary.isNotEmpty) Text(summary.join('\n'), style: secondary),
          if (release.notes.isNotEmpty) ...[const SizedBox(height: 12), Text(release.notes)],
          if (status != null) ...[const SizedBox(height: 16), status],
        ]),
      ),
      actions: actions,
    );
  }
}
