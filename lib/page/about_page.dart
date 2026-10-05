import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/page/licenses_page.dart';
import 'package:superxd/page/third_party_page.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

const sourceRepositoryUrl = 'https://github.com/huverse/SuperXD';

// [人工决策-2026-10-05 01:28:53] “我的”只留“关于”一个入口：版本、用户协议、隐私政策、开源许可（原“开源与第三方声明”并入）、源代码与反馈都在关于页。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key, this.packageInfo, this.openUrl});
  // 测试注入版本信息与打开链接，默认读安装包、交给系统浏览器。
  final Future<PackageInfo>? packageInfo;
  final Future<bool> Function(Uri url)? openUrl;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late final Future<PackageInfo> _info = widget.packageInfo ?? PackageInfo.fromPlatform();

  Future<void> _open(String url) async {
    var opened = false;
    try {
      opened = await (widget.openUrl ?? (uri) => launchUrl(uri, mode: LaunchMode.externalApplication))(Uri.parse(url));
    } catch (error, stack) {
      campusLog('[About] action=openUrl errorType=${error.runtimeType}\n$stack');
    }
    if (!opened && mounted) await showCampusNotice(context, '没有可打开链接的浏览器。\n$url');
  }

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    const rowPadding = EdgeInsets.symmetric(horizontal: 20);
    Widget row(IconData icon, String title, VoidCallback onTap, {bool external = false}) => ListTile(
      contentPadding: rowPadding, leading: CampusIcon(icon), title: Text(title), onTap: onTap,
      trailing: CampusIcon(external ? CampusIcons.open : CampusIcons.next),
    );
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('关于'),
      ),
      body: CampusScrollFade(child: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: FutureBuilder<PackageInfo>(
            future: _info,
            builder: (context, snapshot) {
              final info = snapshot.data;
              return Column(children: [
                Text(info?.appName ?? 'SuperXD', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text(info == null ? ' ' : '版本 ${info.version}（${info.buildNumber}）', style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant)),
              ]);
            },
          )),
          CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(children: [
            row(CampusIcons.terms, '用户协议', () => context.push('/legal/service')),
            row(CampusIcons.privacy, '隐私政策', () => context.push('/legal/privacy')),
          ])),
          const SizedBox(height: 16),
          CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(children: [
            row(CampusIcons.info, '开源许可', () => Navigator.push(context, CampusPageRoute<void>(builder: (context) => const ThirdPartyPage()))),
            row(CampusIcons.sourceCode, '源代码', () => _open(sourceRepositoryUrl), external: true),
            row(CampusIcons.feedback, '反馈问题', () => _open('$sourceRepositoryUrl/issues'), external: true),
          ])),
          const GalaxyousAttribution(),
        ],
      ))))),
    );
  }
}
