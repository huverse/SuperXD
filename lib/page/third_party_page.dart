import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/theme/scroll_edge_fade.dart';
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
      title: const Text('开源许可'),
    ),
    body: CampusScrollFade(child: SafeArea(
      child: FutureBuilder<String>(
        future: _text,
        builder: (context, snapshot) {
          if (snapshot.hasError) return const Center(child: Text('声明资源读取失败'));
          if (!snapshot.hasData) {
            return const Center(child: CampusLoading(label: '正在读取开源许可'));
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Align(alignment: AlignmentDirectional.centerStart, child: OutlinedButton.icon(
                onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (context) => const CampusLicensesPage())),
                icon: const CampusIcon(CampusIcons.info),
                label: const Text('全部依赖许可'),
              )),
              const SizedBox(height: 16),
              SelectableText(
                snapshot.data!,
                style: const TextStyle(fontSize: 14, height: 1.6),
              ),
            ],
          );
        },
      ),
    )),
  );
}
