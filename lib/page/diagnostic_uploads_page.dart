import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/application/account_diagnostics.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/diagnostic_upload.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 我上传的诊断包（人工决策见 domain/diagnostic_upload.dart）：记在当前应用账号下的诊断包，从新到旧；打开时读一次（用户点进来才联网）。
// 点一行复制诊断编号，⋯里删除（先确认，服务器上的包与记录一起删）。
class DiagnosticUploadsPage extends StatefulWidget {
  const DiagnosticUploadsPage({super.key, required this.diagnostics});
  final AccountDiagnostics diagnostics;

  @override
  State<DiagnosticUploadsPage> createState() => _DiagnosticUploadsPageState();
}

class _DiagnosticUploadsPageState extends State<DiagnosticUploadsPage> {
  List<DiagnosticRecord>? _records;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final records = await widget.diagnostics.list();
      if (mounted) setState(() => _records = records);
    } on DiagnosticUploadException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _copy(DiagnosticRecord record) async {
    await Clipboard.setData(ClipboardData(text: record.id));
    if (mounted) showCampusToast(context, '已复制诊断编号');
  }

  Future<void> _more(BuildContext anchor, DiagnosticRecord record) async {
    final choice = await showCampusMenu<String>(anchor, items: const [CampusMenuItem(value: 'delete', label: '删除', icon: CampusIcons.delete, destructive: true)]);
    if (!mounted || choice != 'delete') return;
    final confirmed = await showCampusConfirm(context, title: '删除诊断包 ${record.id}？', message: '服务器上的这个诊断包会删除，开发者也看不到了。', action: '删除', destructive: true);
    if (!mounted || !confirmed) return;
    String? failure;
    await showCampusWaiting(context, label: '正在删除', operation: () async {
      try {
        await widget.diagnostics.delete(record.id);
      } on DiagnosticUploadException catch (error) {
        failure = error.message;
      }
    });
    if (!mounted) return;
    if (failure case final message?) return showCampusNotice(context, message);
    setState(() => _records = [...?_records?.where((item) => item.id != record.id)]);
    showCampusToast(context, '已删除');
  }

  static String _size(int bytes) => bytes < 1024 * 1024 ? '${math.max(1, (bytes / 1024).round())} KB' : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

  // 还有几天删除：不满一天也算一天（刚传完写 30 天，同确认框；服务器在到点后的清理轮次才删）。
  static int _daysLeft(DateTime expiresAt) => math.max(0, (expiresAt.difference(DateTime.now().toUtc()).inMinutes / Duration.minutesPerDay).ceil());

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final inset = MediaQuery.paddingOf(context).bottom;
    final records = _records;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('我上传的诊断包'),
      ),
      body: records == null
          ? _error == null ? const CampusLoading(label: '正在读取') : CampusLoadError(message: _error!, onRetry: () => unawaited(_load()))
          : CampusScrollFade(bottom: inset, child: ListView(padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + inset), children: [
              if (records.isEmpty) Padding(padding: const EdgeInsets.only(top: 48), child: Text('应用账号下还没有诊断包', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant))),
              for (final record in records)
                CampusSurface(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
                  onTap: () => unawaited(_copy(record)),
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('诊断编号 ${record.id}', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 2),
                      DotSeparatedText(
                        ['上传于 ${formatCampusRelative(record.uploadedAt.toIso8601String())}', _size(record.bytes), '${_daysLeft(record.expiresAt)} 天后删除'].join(' · '),
                        style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
                      ),
                    ])),
                    Builder(builder: (anchor) => IconButton(tooltip: '更多操作', onPressed: () => unawaited(_more(anchor, record)), icon: const CampusIcon(CampusIcons.manage))),
                  ]),
                ),
            ])),
    );
  }
}
