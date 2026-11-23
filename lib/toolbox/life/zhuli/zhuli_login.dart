import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

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
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_service.dart';

// 住理生活的登录表单：手机号加 6 位数字密码；住理要图形验证码时原地出验证码（SVG，可换一张）再登；忘了密码进短信找回（人工决策见 zhuli_service.dart 文件头）。
// consent 是第一次登录前的同意（由页面给，没同意不发请求）；phone 给了时是重新登录这个账号，手机号不能改。登录成功交回手机号。
class ZhuliLoginForm extends StatefulWidget {
  const ZhuliLoginForm({super.key, required this.service, required this.consent, required this.onSignedIn, this.phone, this.reason});
  final ZhuliService service;
  final Future<bool> Function() consent;
  final ValueChanged<String> onSignedIn;
  final String? phone;
  // 为什么要重新登录（会话恢复不了时带过来的原话），写在表单上面。
  final String? reason;
  @override
  State<ZhuliLoginForm> createState() => _ZhuliLoginFormState();
}

class _ZhuliLoginFormState extends State<ZhuliLoginForm> {
  late final _phone = TextEditingController(text: widget.phone);
  final _password = TextEditingController();
  final _captcha = TextEditingController();
  var _obscure = true;
  var _busy = false;
  String? _error;
  // 住理要过图形验证码时才有：验证码图（SVG 文本），取图中为空。
  String? _captchaSvg;
  var _needsCaptcha = false;
  var _loadingCaptcha = false;

  @override
  void dispose() {
    _phone.dispose();
    _password.dispose();
    _captcha.dispose();
    super.dispose();
  }

  Future<void> _refreshCaptcha() async {
    setState(() {
      _loadingCaptcha = true;
      _captchaSvg = null;
    });
    try {
      final svg = await widget.service.client.captcha(_phone.text.trim());
      if (mounted) setState(() => _captchaSvg = svg);
    } on ZhuliException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loadingCaptcha = false);
    }
  }

  Future<void> _submit() async {
    final phone = _phone.text.trim(), password = _password.text.trim(), captcha = _captcha.text.trim();
    final problem = !RegExp(r'^1\d{10}$').hasMatch(phone)
        ? '手机号是 11 位数字'
        : !RegExp(r'^\d{6}$').hasMatch(password)
        ? '密码是 6 位数字'
        : _needsCaptcha && captcha.isEmpty
        ? '输入图形验证码'
        : null;
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
      await widget.service.signIn(phone, password, captcha: _needsCaptcha ? captcha : '');
      TextInput.finishAutofillContext();
      if (mounted) widget.onSignedIn(phone);
    } on ZhuliException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
      if (error.failure == ZhuliFailure.captchaRequired) {
        _needsCaptcha = true;
        _captcha.clear();
        unawaited(_refreshCaptcha());
      }
    } catch (error, stack) {
      campusLog('[Zhuli] action=sign_in errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '登录没完成，稍后再试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgot() async {
    final phone = await Navigator.of(context).push<String>(CampusPageRoute(builder: (_) => ZhuliResetPage(service: widget.service, phone: _phone.text.trim())));
    if (phone != null && mounted) {
      _phone.text = phone;
      _password.clear();
      setState(() => _error = null);
      showCampusToast(context, '密码已重设，用新密码登录');
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
            autofillHints: const [AutofillHints.telephoneNumber, AutofillHints.username],
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: '住理生活手机号', counterText: ''),
          ),
          SizedBox(height: campusFieldGap(context)),
          TextField(
            controller: _password,
            enabled: !_busy,
            obscureText: _obscure,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            autofillHints: const [AutofillHints.password],
            textInputAction: _needsCaptcha ? TextInputAction.next : TextInputAction.done,
            onSubmitted: (_) {
              if (!_busy && !_needsCaptcha) unawaited(_submit());
            },
            decoration: InputDecoration(
              labelText: '密码（6 位数字）',
              counterText: '',
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示密码' : '隐藏密码',
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: CampusIcon(_obscure ? CampusIcons.eye : CampusIcons.eyeClosed),
              ),
            ),
          ),
          if (_needsCaptcha) ...[
            SizedBox(height: campusFieldGap(context)),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _captcha,
                    enabled: !_busy,
                    maxLength: 4,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      if (!_busy) unawaited(_submit());
                    },
                    decoration: const InputDecoration(labelText: '图形验证码', counterText: ''),
                  ),
                ),
                const SizedBox(width: CampusGap.small),
                // 验证码图是深色笔画、背景透明：垫白底，深色模式下也看得清。
                Container(
                  width: 120,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(CampusGap.small)),
                  child: switch (_captchaSvg) {
                    final svg? => SvgPicture.string(svg, width: 120, height: 48, fit: BoxFit.contain),
                    null => _loadingCaptcha ? const CampusLoader(size: 24) : const SizedBox.shrink(),
                  },
                ),
                IconButton(tooltip: '换一张', onPressed: _loadingCaptcha || _busy ? null : () => unawaited(_refreshCaptcha()), icon: const CampusIcon(CampusIcons.sync)),
              ],
            ),
          ],
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
          const SizedBox(height: CampusGap.small),
          Align(
            child: TextButton.icon(onPressed: _busy ? null : () => unawaited(_forgot()), icon: const CampusIcon(CampusIcons.lock), label: const Text('忘记密码')),
          ),
        ],
      ),
    );
  }
}

// 加账号或重新登录某个账号的页面：登录成功交回手机号。
class ZhuliLoginPage extends StatelessWidget {
  const ZhuliLoginPage({super.key, required this.service, required this.consent, this.phone, this.reason});
  final ZhuliService service;
  final Future<bool> Function() consent;
  final String? phone;
  final String? reason;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
      title: Text(phone == null ? '添加住理账号' : '重新登录'),
    ),
    body: CampusScrollFade(
      child: SafeArea(
        bottom: false,
        child: ListView(
          padding: campusScrollPadding(context, const EdgeInsets.all(16)),
          children: [
            CampusSurface(
              padding: EdgeInsets.fromLTRB(16, campusFieldGap(context), 16, 16),
              child: ZhuliLoginForm(service: service, consent: consent, phone: phone, reason: reason, onSignedIn: (phone) => Navigator.pop(context, phone)),
            ),
          ],
        ),
      ),
    ),
  );
}

// 短信找回密码（同原 App 重置密码页的「短信验证」）：发验证码（60 秒后才能再发）、输验证码与两次新密码（6 位数字），重设成功交回手机号。
class ZhuliResetPage extends StatefulWidget {
  const ZhuliResetPage({super.key, required this.service, this.phone = ''});
  final ZhuliService service;
  final String phone;
  @override
  State<ZhuliResetPage> createState() => _ZhuliResetPageState();
}

class _ZhuliResetPageState extends State<ZhuliResetPage> {
  late final _phone = TextEditingController(text: widget.phone);
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _again = TextEditingController();
  var _sending = false;
  var _saving = false;
  var _wait = 0;
  Timer? _timer;
  String? _error;

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _code.dispose();
    _password.dispose();
    _again.dispose();
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
      await widget.service.client.sendResetCode(_phone.text.trim());
      if (!mounted) return;
      setState(() => _wait = 60);
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return timer.cancel();
        setState(() => _wait--);
        if (_wait <= 0) timer.cancel();
      });
      showCampusToast(context, '验证码已发到手机');
    } on ZhuliException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _save() async {
    final code = _code.text.trim(), password = _password.text.trim();
    final problem = !_phoneValid
        ? '手机号是 11 位数字'
        : code.isEmpty
        ? '输入短信验证码'
        : !RegExp(r'^\d{6}$').hasMatch(password)
        ? '新密码是 6 位数字'
        : password != _again.text.trim()
        ? '两次输入的新密码不一样'
        : null;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.service.client.resetPassword(_phone.text.trim(), code: code, password: password);
      if (mounted) Navigator.pop(context, _phone.text.trim());
    } on ZhuliException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _sending || _saving;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => context.canPop() ? context.pop() : Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('找回密码'),
      ),
      body: CampusScrollFade(
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: campusScrollPadding(context, const EdgeInsets.all(16)),
            children: [
              CampusSurface(
                padding: EdgeInsets.fromLTRB(16, campusFieldGap(context), 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _phone,
                      enabled: !busy && _wait == 0,
                      keyboardType: TextInputType.phone,
                      maxLength: 11,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(labelText: '住理生活手机号', counterText: ''),
                    ),
                    SizedBox(height: campusFieldGap(context)),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _code,
                            enabled: !_saving,
                            keyboardType: TextInputType.number,
                            maxLength: 8,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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
                    SizedBox(height: campusFieldGap(context)),
                    TextField(
                      controller: _password,
                      enabled: !_saving,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(labelText: '新密码（6 位数字）', counterText: ''),
                    ),
                    SizedBox(height: campusFieldGap(context)),
                    TextField(
                      controller: _again,
                      enabled: !_saving,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(labelText: '再输一次新密码', counterText: ''),
                    ),
                    if (_error case final error?) ...[
                      const SizedBox(height: CampusGap.medium),
                      Text(error, style: TextStyle(color: CampusPalette.of(context).danger)),
                    ],
                    const SizedBox(height: CampusGap.section),
                    FilledButton(
                      style: campusProminent,
                      onPressed: busy ? null : () => unawaited(_save()),
                      child: CampusBusyContent(busy: _saving, label: '重设密码', busyLabel: '重设中', icon: const CampusIcon(CampusIcons.lock)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
