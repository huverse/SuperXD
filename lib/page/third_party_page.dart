import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/page/licenses_page.dart';
import 'package:superxd/theme/campus_loading.dart';

class ThirdPartyPage extends StatefulWidget {
  const ThirdPartyPage({super.key});
  @override
  State<ThirdPartyPage> createState() => _ThirdPartyPageState();
}

class _ThirdPartyPageState extends State<ThirdPartyPage> {
  late final _text = rootBundle.loadString('assets/third_party_notices.txt');
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        tooltip: '返回',
        onPressed: () => Navigator.pop(context),
        icon: const CampusIcon(CampusIcons.back),
      ),
      title: const Text('开源与第三方声明'),
    ),
    body: SafeArea(
      child: FutureBuilder<String>(
        future: _text,
        builder: (context, snapshot) {
          if (snapshot.hasError) return const Center(child: Text('声明资源读取失败'));
          if (!snapshot.hasData) {
            return const Center(child: CampusLoading(label: '正在读取第三方声明'));
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const GalaxyousAttribution(),
              OutlinedButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (context) => const CampusLicensesPage())),
                child: const Text('查看所有依赖许可'),
              ),
              const SizedBox(height: 16),
              SelectableText(
                snapshot.data!,
                style: const TextStyle(fontSize: 14, height: 1.6),
              ),
            ],
          );
        },
      ),
    ),
  );
}
