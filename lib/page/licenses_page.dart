import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/domain/campus_log.dart';

// [人工决策-2026-09-25 16:24:31] 应用署名按两行展示，LicenseRegistry原始版权和许可正文完整保留。
class GalaxyousAttribution extends StatelessWidget {
  const GalaxyousAttribution({super.key});
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 24),
    child: Column(
      children: [
        Text(
          'Powered&Design By Galaxyous',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        SizedBox(height: 8),
        Text(
          '基于Flutter框架',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14),
        ),
      ],
    ),
  );
}

class CampusLicensesPage extends StatefulWidget {
  const CampusLicensesPage({super.key, this.licenses});
  final Stream<LicenseEntry>? licenses;
  @override
  State<CampusLicensesPage> createState() => _CampusLicensesPageState();
}

class _CampusLicensesPageState extends State<CampusLicensesPage> {
  late final Future<List<MapEntry<String, List<LicenseEntry>>>> _licenses =
      _load();
  Future<List<MapEntry<String, List<LicenseEntry>>>> _load() async {
    final packages = <String, List<LicenseEntry>>{};
    try {
      await for (final entry in widget.licenses ?? LicenseRegistry.licenses) {
        for (final package in entry.packages) {
          packages.putIfAbsent(package, () => []).add(entry);
        }
      }
      return packages.entries.toList()..sort(
        (left, right) =>
            left.key.toLowerCase().compareTo(right.key.toLowerCase()),
      );
    } catch (error, stack) {
      campusLog('[Licenses] action=load errorType=${error.runtimeType}\n$stack');
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        tooltip: '返回',
        onPressed: () => Navigator.pop(context),
        icon: const CampusIcon(CampusIcons.back),
      ),
      title: const Text('全部依赖许可'),
    ),
    body: CampusScrollFade(child: SafeArea(
      child: FutureBuilder<List<MapEntry<String, List<LicenseEntry>>>>(
        future: _licenses,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('许可读取失败，请返回后重试'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CampusLoading(label: '正在读取依赖许可'));
          }
          final packages = snapshot.data!;
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            itemCount: packages.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) return const GalaxyousAttribution();
              final package = packages[index - 1];
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: CampusSurface(
                  onTap: () => Navigator.push(
                    context,
                    CampusPageRoute<void>(
                      builder: (context) => _LicenseDetail(
                        package: package.key,
                        entries: package.value,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              package.key,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Text('${package.value.length} 份许可'),
                          ],
                        ),
                      ),
                      const CampusIcon(CampusIcons.next),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    )),
  );
}

class _LicenseDetail extends StatelessWidget {
  const _LicenseDetail({required this.package, required this.entries});
  final String package;
  final List<LicenseEntry> entries;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        tooltip: '返回',
        onPressed: () => Navigator.pop(context),
        icon: const CampusIcon(CampusIcons.back),
      ),
      title: Text(package),
    ),
    body: CampusScrollFade(child: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          for (final entry in entries) ...[
            for (final paragraph in entry.paragraphs)
              Padding(
                padding: EdgeInsets.only(
                  left: paragraph.indent > 0 ? paragraph.indent * 12.0 : 0,
                  bottom: 12,
                ),
                child: SelectableText(
                  paragraph.text,
                  textAlign: paragraph.indent == LicenseParagraph.centeredIndent
                      ? TextAlign.center
                      : TextAlign.start,
                  style: const TextStyle(fontSize: 14, height: 1.65),
                ),
              ),
            const Divider(height: 32),
          ],
        ],
      ),
    )),
  );
}
