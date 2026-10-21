import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/express/express_controller.dart';
import 'package:superxd/toolbox/express/express_models.dart';

// 取件手机号管理弹层：列已绑定的号（⋯里解绑）、一键快速绑定本账号已有号、短信验证绑定其他手机号。
// 绑定/解绑都是账号状态变更，逐步由用户点击确认，不后台自动做。登录失效时控制器回到登录页、本弹层随之关闭。
// 数据由页面先读好再打开（ExpressController.loadMobiles），弹层一出来就是最终内容，不先撑满再缩回。
Future<void> showExpressMobileSheet(BuildContext context, {required ExpressController controller, required ExpressMobiles initial}) =>
    showCampusSheet<void>(context: context, builder: (context) => _ExpressMobileSheet(controller: controller, initial: initial));

class _ExpressMobileSheet extends StatefulWidget {
  const _ExpressMobileSheet({required this.controller, required this.initial});
  final ExpressController controller;
  final ExpressMobiles initial;

  @override
  State<_ExpressMobileSheet> createState() => _ExpressMobileSheetState();
}

class _ExpressMobileSheetState extends State<_ExpressMobileSheet> {
  late ExpressMobiles _data = widget.initial;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
  }

  // 任何绑定操作拿到未登录时，控制器会清会话、回到登录页：此时把弹层关掉，别悬在登录页上。
  // 只在本弹层正处栈顶时关（上面压着绑定对话框时交给对话框自己关，关完 _bindNew 再兜底关本弹层），免得误弹掉对话框。
  void _onController() {
    if (!widget.controller.loggedIn && mounted && (ModalRoute.of(context)?.isCurrent ?? false)) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    super.dispose();
  }

  // 一次只跑一个绑定操作：失败用提示条说明（未登录由控制器带回登录页，这里不再提示）。
  // 成功后保留现有列表、原地换成重读的结果（不切回加载态），再提示。
  Future<void> _guard(Future<void> Function() op, {required String done}) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await op();
      final data = await widget.controller.reloadMobiles();
      if (!mounted) return;
      setState(() => _data = data);
      showCampusToast(context, done);
    } on ExpressFailure catch (failure) {
      if (mounted && !failure.isNotLoggedIn) showCampusToast(context, failure.message);
    } catch (error, stack) {
      campusLog('[Express] action=bind_op errorType=${error.runtimeType}\n$stack');
      if (mounted) showCampusToast(context, '出错了，请稍后重试');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _fastBind(PddBindPreCheck pre) => _guard(() => widget.controller.fastBind(pre), done: '已绑定本账号手机号');

  Future<void> _bindNew() async {
    final bound = await showCampusDialog<bool>(context: context, builder: (_) => _BindMobileDialog(controller: widget.controller));
    if (!mounted) return;
    // 对话框里若会话失效（_onController 当时在对话框栈顶、没关本弹层），对话框关完回到这里再兜底关掉本弹层。
    if (!widget.controller.loggedIn) {
      Navigator.of(context).pop();
      return;
    }
    // 绑定已在对话框里做完，这里只原地重读列表。
    if (bound == true) await _guard(() async {}, done: '已绑定');
  }

  Future<void> _unbind(BuildContext anchor, PddBoundMobile mobile) async {
    final choice = await showCampusMenu<String>(anchor, items: const [CampusMenuItem(value: 'unbind', label: '解绑', icon: CampusIcons.unbind, destructive: true)]);
    if (choice != 'unbind' || !mounted) return;
    final name = mobile.alias.isEmpty ? mobile.maskedMobile : '${mobile.maskedMobile}（${mobile.alias}）';
    final agreed = await showCampusConfirm(context, title: '解绑 $name？', message: '解绑后，寄到这个手机号的快递就不能用本账号的身份码取件了。', action: '解绑', destructive: true);
    if (agreed && mounted) await _guard(() => widget.controller.unbind(mobile), done: '已解绑');
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    final (:pre, :mobiles) = _data;
    // 快速绑定只在预检查给了已有号、且它还没在列表里时才提示。
    final showFastBind = pre.canFastBind && mobiles.every((mobile) => mobile.mobileId != pre.mobileId);
    final list = ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      children: [
        if (mobiles.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('还没有绑定取件手机号', style: secondary))
        else
          for (final mobile in mobiles)
            CampusSurface(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
              radius: 16,
              child: Row(
                children: [
                  const Padding(padding: EdgeInsets.only(right: 12), child: CampusIcon(CampusIcons.phone)),
                  Expanded(
                    child: Text(
                      mobile.alias.isEmpty ? mobile.maskedMobile : '${mobile.maskedMobile}（${mobile.alias}）',
                      style: TextStyle(fontSize: 16, color: palette.onSurface),
                    ),
                  ),
                  Builder(builder: (anchor) => IconButton(tooltip: '更多操作', onPressed: _working ? null : () => _unbind(anchor, mobile), icon: const CampusIcon(CampusIcons.manage))),
                ],
              ),
            ),
        const SizedBox(height: 8),
        Text('绑定后，寄到该手机号的快递都能用这个账号的身份码取件。拼多多不支持多端登录，建议用小号登录后把大号的手机号绑进来。', style: secondary),
        const SizedBox(height: 16),
        if (showFastBind)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton(
              onPressed: _working ? null : () => _fastBind(pre),
              child: CampusBusyContent(busy: _working, label: pre.mobileDesc.isEmpty ? '绑定本账号手机号' : '绑定本账号手机号（${pre.mobileDesc}）', busyLabel: '绑定中', icon: const CampusIcon(CampusIcons.add)),
            ),
          ),
        FilledButton(
          style: campusProminent,
          onPressed: _working ? null : _bindNew,
          child: const CampusBusyContent(busy: false, label: '绑定其他手机号', busyLabel: '绑定中', icon: CampusIcon(CampusIcons.add)),
        ),
      ],
    );
    return CampusSheetPanel(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 12, 4),
            child: Row(
              children: [
                Expanded(child: Text('取件手机号', style: textTheme.titleLarge)),
                IconButton(tooltip: '关闭', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.close)),
              ],
            ),
          ),
          // 绑定、解绑后列表增减时高度平滑过渡；减少动画时直接换（AnimatedSize 时长为 0 会在自己的布局里报错）。
          Flexible(
            child: MediaQuery.disableAnimationsOf(context)
                ? list
                : AnimatedSize(duration: campusEnter, curve: Curves.easeInOutCubic, alignment: Alignment.topCenter, child: list),
          ),
        ],
      ),
    );
  }
}

// 短信验证绑定新手机号：先输手机号发验证码，再输 6 位验证码完成绑定。验证码由拼多多发给该手机号，只有用户点击才发、才绑。
class _BindMobileDialog extends StatefulWidget {
  const _BindMobileDialog({required this.controller});
  final ExpressController controller;

  @override
  State<_BindMobileDialog> createState() => _BindMobileDialogState();
}

class _BindMobileDialogState extends State<_BindMobileDialog> {
  final _mobile = TextEditingController();
  final _code = TextEditingController();
  String _mobileId = '';
  bool _sent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _mobile.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() op) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await op();
    } on ExpressFailure catch (failure) {
      if (!mounted) return;
      // 未登录由控制器带回登录页：关掉对话框，让外层弹层也随之关闭。
      if (failure.isNotLoggedIn) {
        Navigator.pop(context, false);
        return;
      }
      setState(() => _error = failure.message);
    } catch (error, stack) {
      campusLog('[Express] action=bind_dialog errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '出错了，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    final mobile = _mobile.text.trim();
    if (!RegExp(r'^1\d{10}$').hasMatch(mobile)) {
      setState(() => _error = '请输入 11 位手机号');
      return;
    }
    await _run(() async {
      final mobileId = await widget.controller.sendBindSms(mobile);
      if (!mounted) return;
      if (mobileId.isEmpty) {
        setState(() => _error = '发送验证码失败，请稍后重试');
        return;
      }
      setState(() {
        _mobileId = mobileId;
        _sent = true;
      });
    });
  }

  Future<void> _confirm() async {
    final code = _code.text.trim();
    if (code.length < 4) {
      setState(() => _error = '请输入收到的验证码');
      return;
    }
    await _run(() async {
      final sessionId = await widget.controller.verifyBindSms(_mobileId, code);
      if (!mounted) return;
      if (sessionId.isEmpty) {
        setState(() => _error = '验证码不正确或已过期');
        return;
      }
      await widget.controller.completeBind(sessionId);
      if (mounted) Navigator.pop(context, true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return CampusGlassDialog(
      title: Text(_sent ? '输入验证码' : '绑定其他手机号'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_sent)
            TextField(
              controller: _mobile,
              autofocus: true,
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
              decoration: const InputDecoration(labelText: '手机号', counterText: ''),
            )
          else ...[
            Text('验证码已发送至 ${_mobile.text.trim()}', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              decoration: const InputDecoration(labelText: '验证码', counterText: ''),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: _busy ? null : _send, style: campusLink, child: const Text('重新发送')),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(fontSize: 14, color: palette.danger)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(
          onPressed: _busy ? null : (_sent ? _confirm : _send),
          child: CampusBusyContent(busy: _busy, label: _sent ? '确认绑定' : '发送验证码', busyLabel: _sent ? '绑定中' : '发送中'),
        ),
      ],
    );
  }
}
