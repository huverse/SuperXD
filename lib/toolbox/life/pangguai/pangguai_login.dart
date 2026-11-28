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

// 胖乖生活的登录表单：手机号加短信验证码（没注册过的号胖乖直接注册）；胖乖要人机验证时先弹易盾的验证。
// consent 是第一次发验证码前的同意（由页面给，没同意不发请求）；phone 给了时是重新登录这个账号，手机号不能改。登录成功交回手机号。
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
  final _codeFocus = FocusNode();
  var _busy = false;
  var _sending = false;
  String? _error;
  // 发出验证码后 60 秒才能再发。
  var _wait = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _code.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  bool get _dark => Theme.of(context).brightness == Brightness.dark;

  String? _checkPhone(String phone) => RegExp(r'^1\d{10}$').hasMatch(phone) ? null : '手机号是 11 位数字';

  Future<void> _send() async {
    final phone = _phone.text.trim();
    if (_checkPhone(phone) case final problem?) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      if (!await widget.consent()) return;
      await widget.service.sendCode(phone, dark: _dark);
      if (!mounted) return;
      _countdown();
      _codeFocus.requestFocus();
      showCampusToast(context, '验证码已发出');
    } on PangguaiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=send_code errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '验证码没发出去，稍后再试');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _countdown() {
    _timer?.cancel();
    setState(() => _wait = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _wait <= 1) {
        timer.cancel();
        if (mounted) setState(() => _wait = 0);
        return;
      }
      setState(() => _wait--);
    });
  }

  Future<void> _submit() async {
    final phone = _phone.text.trim(), code = _code.text.trim();
    final problem = _checkPhone(phone) ?? (RegExp(r'^\d{4,6}$').hasMatch(code) ? null : '输入短信验证码');
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await widget.consent()) return;
      await widget.service.signIn(phone, code, dark: _dark);
      TextInput.finishAutofillContext();
      if (mounted) widget.onSignedIn(phone);
    } on PangguaiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error, stack) {
      campusLog('[Pangguai] action=sign_in errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '登录没完成，稍后再试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return AutofillGroup(
      onDisposeAction: AutofillContextAction.cancel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.reason case final reason?) ...[
            Text(reason, style: TextStyle(color: palette.onSurfaceVariant)),
            SizedBox(height: campusFieldGap(context)),
          ],
          TextField(
            controller: _phone,
            enabled: widget.phone == null && !_busy,
            keyboardType: TextInputType.phone,
            maxLength: 11,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            autofillHints: const [AutofillHints.telephoneNumber],
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: '胖乖生活手机号', counterText: ''),
          ),
          SizedBox(height: campusFieldGap(context)),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _code,
                  focusNode: _codeFocus,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  autofillHints: const [AutofillHints.oneTimeCode],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) {
                    if (!_busy) unawaited(_submit());
                  },
                  decoration: const InputDecoration(labelText: '短信验证码', counterText: ''),
                ),
              ),
              const SizedBox(width: CampusGap.small),
              OutlinedButton(
                onPressed: _sending || _busy || _wait > 0 ? null : () => unawaited(_send()),
                child: CampusBusyContent(busy: _sending, label: _wait > 0 ? '$_wait 秒后重发' : '获取验证码', busyLabel: '发送中', icon: const CampusIcon(CampusIcons.send)),
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
            onPressed: _busy ? null : () => unawaited(_submit()),
            child: CampusBusyContent(busy: _busy, label: '登录', busyLabel: '登录中', icon: const CampusIcon(CampusIcons.login)),
          ),
        ],
      ),
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
