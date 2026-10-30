import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/express/express_controller.dart';
import 'package:superxd/toolbox/express/express_models.dart';

// 拼多多短信登录表单（[人工决策] 见 express_models.dart 的登录常量）：手机号加短信验证码，在应用里直接发给拼多多，号码与验证码不保存。
// 发码与登录前都经 consent 取同意（同意过的直接过）；拼多多要求验证时经 verify 打开官方验证页，本人过了再用令牌完成登录。失败原因在表单里原地写。
class ExpressLoginForm extends StatefulWidget {
  const ExpressLoginForm({super.key, required this.controller, required this.consent, required this.verify});
  final ExpressController controller;
  final Future<bool> Function() consent;
  final Future<bool> Function(Uri page) verify;

  @override
  State<ExpressLoginForm> createState() => _ExpressLoginFormState();
}

class _ExpressLoginFormState extends State<ExpressLoginForm> {
  final _mobile = TextEditingController();
  final _code = TextEditingController();
  // 同官方：这次已成功发过几次验证码，随发码请求带上。
  var _requestTimes = 0;
  // 发出后 60 秒内不能重发（同官方），按钮上倒数；0 表示可以发。
  var _countdown = 0;
  Timer? _ticker;
  bool _sending = false;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _ticker?.cancel();
    _mobile.dispose();
    _code.dispose();
    super.dispose();
  }

  String? _invalidMobile() => RegExp(r'^1\d{10}$').hasMatch(_mobile.text.trim()) ? null : '请输入 11 位手机号';

  Future<void> _send() async {
    final invalid = _invalidMobile();
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    if (!await widget.consent() || !mounted) return;
    final mobile = _mobile.text.trim();
    await _guard(() => _sending = true, () => _sending = false, () async {
      final needCall = await widget.controller.sendLoginSms(mobile, requestTimes: _requestTimes);
      _requestTimes++;
      if (needCall) {
        // 拼多多这次没发短信、改要电话告知验证码（同官方的语音验证码弹窗）：本人同意了再发一次。
        if (!mounted) return;
        final call = await showCampusConfirm(context, title: '改用电话接收验证码', message: '拼多多这次要打电话告诉你验证码，请留意来电。', action: '接听电话');
        if (!call || !mounted) return;
        await widget.controller.sendLoginSms(mobile, requestTimes: _requestTimes, voice: true);
        _requestTimes++;
      }
      if (mounted) _startCountdown();
    });
  }

  void _startCountdown() {
    _ticker?.cancel();
    setState(() => _countdown = 60);
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() => _countdown--);
      if (_countdown == 0) timer.cancel();
    });
  }

  Future<void> _submit() async {
    final code = _code.text.trim();
    final invalid = _invalidMobile() ?? (code.length < 4 ? '请输入收到的验证码' : null);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    if (!await widget.consent() || !mounted) return;
    final mobile = _mobile.text.trim();
    // 登录成功后页面换成已登录视图、本表单随之销毁。
    await _guard(() => _submitting = true, () => _submitting = false, () async {
      try {
        await widget.controller.loginWithSms(mobile, code);
      } on ExpressFailure catch (failure) {
        final page = failure.verifyPage;
        if (page == null || !await widget.verify(page)) rethrow;
        await widget.controller.verifiedLogin(failure.verifyToken);
      }
    });
  }

  // 一次只跑一个请求，发起的按钮原地转圈；失败原因写在表单里。
  Future<void> _guard(VoidCallback start, VoidCallback end, Future<void> Function() action) async {
    setState(() {
      start();
      _error = null;
    });
    try {
      await action();
    } on ExpressFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } catch (error, stack) {
      campusLog('[Express] action=login_form errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '出错了，请稍后重试');
    } finally {
      if (mounted) setState(end);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final busy = _sending || _submitting;
    // CampusBusyContent 按两段文案里较宽的留宽：两段都放最宽的「重新发送(60)」，倒数和发送中时验证码框都不跟着变宽变窄。
    const widest = '重新发送(60)';
    return AutofillGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _mobile,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumberNational],
            textInputAction: TextInputAction.next,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
            decoration: const InputDecoration(labelText: '手机号', prefixText: '+86 '),
          ),
          SizedBox(height: campusFieldGap(context)),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  textInputAction: TextInputAction.done,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                  onSubmitted: (_) {
                    if (!busy) unawaited(_submit());
                  },
                  decoration: const InputDecoration(labelText: '验证码'),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: busy || _countdown > 0 ? null : () => unawaited(_send()),
                child: CampusBusyContent(
                  busy: _sending,
                  label: _sending ? widest : (_countdown > 0 ? '重新发送($_countdown)' : '获取验证码'),
                  busyLabel: _sending ? '发送中' : widest,
                  icon: const CampusIcon(CampusIcons.send),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(fontSize: 14, color: palette.danger)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            style: campusProminent,
            onPressed: busy ? null : () => unawaited(_submit()),
            child: CampusBusyContent(busy: _submitting, label: '登录', busyLabel: '登录中', icon: const CampusIcon(CampusIcons.login)),
          ),
        ],
      ),
    );
  }
}
