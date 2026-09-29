import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/domain/campus_log.dart';

Future<void> showLegacyImport(BuildContext context, AppSession session, {bool automatic = false}) async {
  final accounts = session.gateway;
  final generation = accounts.generation;
  final identity = accounts.activeIdentity;
  if (identity == null || accounts.activeSession == null) return;
  bool active() => context.mounted && accounts.generation == generation;
  try {
    final state = await accounts.legacyImportState();
    if (!context.mounted || !active() || (automatic && state.deferred)) return;
    if (!state.available) {
      if (!automatic) await showCampusNotice(context, '没有可导入的未归属旧数据。');
      return;
    }
    // [人工决策-2026-09-24 20:40:27] 旧库没有可信账号归属；本人确认后仅导入一次，不导入旧会话，不自动认领。
    final confirmed = await showCampusConfirm(
      context,
      barrierDismissible: false,
      title: state.resumable ? '继续导入旧数据？' : '确认旧数据归属',
      message: '当前账号：${identity.loginId}\n\n旧版本未记录每条缓存的账号归属，可能包含以前使用过的其他账号数据。只有确认全部旧数据属于此账号时才导入。\n\n课表、成绩、开学日、作息和历史版本会迁入这个账号，已有当前课表不被覆盖；合并后每学期最多保留100个历史版本，超限旧版本会清理；旧登录态不迁入，原文件保留。\n\n不能确认时请选择“暂不导入”，不影响正常使用。',
      cancel: '暂不导入',
      action: '确认属于我并导入',
    );
    if (!active()) return;
    if (!confirmed) {
      await accounts.deferLegacyImport();
      return;
    }
    // 操作与状态存储在应用层；完成后会话代次变化，原确认页面随路由一起销毁。
    if (!context.mounted) return;
    await showCampusWaiting(context, label: '正在导入已确认归属的数据', operation: session.importLegacy);
  } catch (error, stack) {
    campusLog('[AccountImport] errorType=${error.runtimeType}\n$stack');
    if (context.mounted && active()) await showCampusNotice(context, '旧数据导入未完成，原文件保留，请重试。');
  }
}

class LegacyImportGate extends StatefulWidget {
  const LegacyImportGate({super.key, required this.session, required this.child});
  final AppSession session;
  final Widget child;

  @override
  State<LegacyImportGate> createState() => _LegacyImportGateState();
}

class _LegacyImportGateState extends State<LegacyImportGate> {
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_noticeChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _showNotice();
      if (mounted) await showLegacyImport(context, widget.session, automatic: true);
    });
  }

  void _noticeChanged() {
    if (widget.session.pendingNotice == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _showNotice(); });
  }

  Future<void> _showNotice() async {
    final message = widget.session.takeNotice();
    if (message != null && mounted) await showCampusNotice(context, message);
  }

  @override
  void dispose() {
    widget.session.removeListener(_noticeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
