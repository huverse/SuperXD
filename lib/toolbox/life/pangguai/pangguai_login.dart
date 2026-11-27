import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_service.dart';

// 胖乖生活的登录表单：手机号加 4 位短信验证码（胖乖没有密码登录）。发码前经页面给的 consent 取同意（没同意不发请求），发码后 60 秒才能再发。
// phone 给了时是重新登录这个账号（凭据失效了），手机号不能改。登录成功交回手机号。
class PangguaiLoginForm extends StatefulWidget {
  const PangguaiLoginForm({super.key, required this.service, required this.consent, required this.onSignedIn, this.phone, this.reason});
  final PangguaiService service;
  final Future<bool> Function() consent;
  final ValueChanged<String> onSignedIn;
  final String? phone;
  // 为什么要重新登录（凭据失效时带过来的原话），写在表单上面。
  final String? reason;
  @override
  State<PangguaiLoginForm> createState() => _PangguaiLoginFormState();
}

class _PangguaiLoginFormState extends State<PangguaiLoginForm> {
  late final _phone = TextEditingController(text: widget.phone);
  final _code = TextEditingController();
  var _sending = false;
  var _signing = false;
  var _wait = 0;
  Timer? _timer;
  String? _error;

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  bool get _phoneValid => RegExp(r'^1\d{10}$').hasMatch(_phone.text.trim());

  Future<void> _send() async {
    if (!_phoneValid) {
      setState(() => _error = '手机号是 11 位数字');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      if (!await widget.consent()) return;
      await widget.service.sendCode(_phone.text.trim());
      if (!mounted) return;
      setState(() => _wait = 60);
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return timer.cancel();
        setState(() => _wait--);
        if (_wait <= 0) timer.cancel();
      });
      showCampusToast(context, '验证码已发到手机');
    } on PangguaiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=send_code errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '验证码没发出去，稍后再试');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _submit() async {
    final phone = _phone.text.trim(), code = _code.text.trim();
    final problem = !_phoneValid ? '手机号是 11 位数字' : !RegExp(r'^\d{4,6}$').hasMatch(code) ? '输入短信验证码' : null;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _signing = true;
      _error = null;
    });
    try {
      if (!await widget.consent()) return;
      await widget.service.signIn(phone, code);
      if (mounted) widget.onSignedIn(phone);
    } on PangguaiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=sign_in errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '登录没完成，稍后再试');
    } finally {
      if (mounted) setState(() => _signing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final busy = _sending || _signing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.reason case final reason?) ...[
          Text(reason, style: TextStyle(color: palette.onSurfaceVariant)),
          SizedBox(height: campusFieldGap(context)),
        ],
        TextField(
          controller: _phone,
          enabled: widget.phone == null && !busy && _wait == 0,
          keyboardType: TextInputType.phone,
          maxLength: 11,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          autofillHints: const [AutofillHints.telephoneNumber],
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: '胖乖生活手机号', counterText: ''),
        ),
        SizedBox(height: campusFieldGap(context)),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _code,
                enabled: !_signing,
                keyboardType: TextInputType.number,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                autofillHints: const [AutofillHints.oneTimeCode],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (!busy) unawaited(_submit());
                },
                decoration: const InputDecoration(labelText: '短信验证码', counterText: ''),
              ),
            ),
            const SizedBox(width: CampusGap.small),
            OutlinedButton.icon(
              onPressed: busy || _wait > 0 ? null : () => unawaited(_send()),
              icon: const CampusIcon(CampusIcons.messages),
              label: CampusBusyContent(busy: _sending, label: _wait > 0 ? '$_wait 秒后重发' : '获取验证码', busyLabel: '发送中'),
            ),
          ],
        ),
        if (_error case final error?) ...[
          const SizedBox(height: CampusGap.medium),
          Text(error, style: TextStyle(color: palette.danger)),
        ],
        const SizedBox(height: CampusGap.section),
        FilledButton(
          style: campusProminent,
          onPressed: busy ? null : () => unawaited(_submit()),
          child: CampusBusyContent(busy: _signing, label: '登录', busyLabel: '登录中', icon: const CampusIcon(CampusIcons.login)),
        ),
      ],
    );
  }
}

// 加账号或重新登录某个账号的页面：登录成功交回手机号。
class PangguaiLoginPage extends StatelessWidget {
  const PangguaiLoginPage({super.key, required this.service, required this.consent, this.phone, this.reason});
  final PangguaiService service;
  final Future<bool> Function() consent;
  final String? phone;
  final String? reason;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
      title: Text(phone == null ? '添加胖乖账号' : '重新登录'),
    ),
    body: CampusScrollFade(
      child: SafeArea(
        bottom: false,
        child: ListView(
          padding: campusScrollPadding(context, const EdgeInsets.all(16)),
          children: [
            CampusSurface(
              padding: EdgeInsets.fromLTRB(16, campusFieldGap(context), 16, 16),
              child: PangguaiLoginForm(service: service, consent: consent, phone: phone, reason: reason, onSignedIn: (phone) => Navigator.pop(context, phone)),
            ),
          ],
        ),
      ),
    ),
  );
}
