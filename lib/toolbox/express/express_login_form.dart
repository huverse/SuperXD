import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_rolling_text.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/toolbox/express/express_controller.dart';
import 'package:superxd/toolbox/express/express_models.dart';

// 拼多多短信登录表单（[人工决策] 见 express_models.dart 的登录常量）：手机号加短信验证码，在应用里直接发给拼多多，号码与验证码不保存。
// 发码与登录前都经 consent 取同意（同意过的直接过）；登录前要勾选拼多多自己的服务协议与隐私政策（openTerms 打开官方条款页）；
// 拼多多要求验证时经 verify 打开官方验证页，本人过了再用令牌完成登录。失败原因在表单里原地写。
class ExpressLoginForm extends StatefulWidget {
  const ExpressLoginForm({super.key, required this.controller, required this.consent, required this.verify, required this.openTerms});
  final ExpressController controller;
  final Future<bool> Function() consent;
  final Future<bool> Function(Uri page) verify;
  final VoidCallback openTerms;

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
  bool _agreed = false;
  String? _error;

  static const _agreementHint = '请先勾选同意拼多多服务协议与隐私政策';

  @override
  void dispose() {
    _ticker?.cancel();
    _mobile.dispose();
    _code.dispose();
    super.dispose();
  }

  String? _invalidMobile() => RegExp(r'^1\d{10}$').hasMatch(_mobile.text.trim()) ? null : '请输入 11 位手机号';

  bool get _busy => _sending || _submitting;

  Future<void> _send() async {
    if (_busy) return;
    final invalid = _invalidMobile();
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    final mobile = _mobile.text.trim();
    // 等同意弹窗的那段也算忙：一帧里连点两下不会弹两个同意、发两次码。
    await _guard(() => _sending = true, () => _sending = false, () async {
      if (!await widget.consent() || !mounted) return;
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
    if (_busy) return;
    final code = _code.text.trim();
    // 同官方登录页的检查顺序：手机号、验证码、拼多多协议。
    final invalid = _invalidMobile() ?? (code.length < 4 ? '请输入收到的验证码' : null) ?? (_agreed ? null : _agreementHint);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    final mobile = _mobile.text.trim();
    // 登录成功后页面换成已登录视图、本表单随之销毁。
    await _guard(() => _submitting = true, () => _submitting = false, () async {
      if (!await widget.consent() || !mounted) return;
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
    final busy = _busy;
    // CampusBusyContent 按两段文案里较宽的留宽：两段都放最宽的「重新发送(60)」，倒数和发送中时验证码框都不跟着变宽变窄。
    const widest = '重新发送(60)';
    // 协议行的首行与左边 48 的勾选框居中对齐（同登录页的同意行）。
    const agreementStyle = TextStyle(fontSize: 14);
    final line = campusTextPainter(context, '我', style: agreementStyle);
    final agreementTop = math.max(0.0, (48 - line.height - 8) / 2);
    line.dispose();
    final link = campusLink.copyWith(padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)), minimumSize: const WidgetStatePropertyAll(Size.zero), tapTargetSize: MaterialTapTargetSize.shrinkWrap);
    final motion = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 220);
    // [人工决策-2026-10-31 21:34:45] 用户选「胶囊框、验证码按钮嵌在框里」（未选「一张卡两行」「保留现在的框只加动效」，只改快递登录页）：
    // 胶囊形同应用的搜索框，占位文字不用浮动标签；「获取验证码」在验证码框里右侧，大字号下不挤；聚焦时描边渐变成主色、底色微亮；
    // 倒数时数字滚动；出错提示展开淡入。
    final error = Text(_error ?? '', style: TextStyle(fontSize: 14, color: palette.danger));
    return AutofillGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CapsuleField(
            controller: _mobile,
            hint: '手机号',
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumberNational],
            textInputAction: TextInputAction.next,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
            leading: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('+86', style: TextStyle(fontSize: 16, color: palette.onSurface)),
              const SizedBox(width: 12),
              SizedBox(width: 1, height: 20, child: ColoredBox(color: palette.outlineSubtle)),
            ]),
          ),
          const SizedBox(height: 12),
          // 按钮放在验证码框里右侧；大字号的窄屏上放不下按钮加六位验证码时，按钮挪到框下面靠右（按钮按最宽的 widest 留宽，
          // 文字 16、图标与间距 32、左右内边距各 12 同主题；胶囊左 20、右 6、按钮与文字间 8）。
          LayoutBuilder(builder: (context, constraints) {
            final send = FilledButton(
              onPressed: busy || _countdown > 0 ? null : () => unawaited(_send()),
              child: _countdown > 0 && !_sending
                  ? _Countdown(seconds: _countdown, widest: widest)
                  : CampusBusyContent(busy: _sending, label: _sending ? widest : '获取验证码', busyLabel: _sending ? '发送中' : widest, icon: const CampusIcon(CampusIcons.send)),
            );
            final button = campusTextWidth(context, widest, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)).ceilToDouble() + 32 + 24;
            final inline = constraints.maxWidth - 20 - 6 - 8 - button >= campusTextWidth(context, '000000', style: const TextStyle(fontSize: 16)) + 8;
            final field = _CapsuleField(
              controller: _code,
              hint: '验证码',
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              textInputAction: TextInputAction.done,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              onSubmitted: (_) {
                if (!busy) unawaited(_submit());
              },
              trailing: inline ? send : null,
            );
            return inline ? field : Column(crossAxisAlignment: CrossAxisAlignment.end, children: [field, const SizedBox(height: 8), send]);
          }),
          const SizedBox(height: 8),
          // [人工决策-2026-10-30 23:07:44] 复审查到原生表单跳过了拼多多自己的协议确认：官方登录页默认要勾选「同意服务协议与隐私政策」才让登录
          //（未注册的号码可能被直接注册成拼多多账号）。用户选「勾选框」（未选「只写一行登录即表示同意」「不加」）：同官方默认不勾、点登录时检查，
          // 点「同意拼多多」几个字也能勾选、读屏读整句；「服务协议与隐私政策」用系统浏览器打开拼多多官方条款页（terms_list.html）。
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 48, height: 48, child: Checkbox(semanticLabel: '同意拼多多服务协议与隐私政策', value: _agreed, onChanged: busy ? null : (value) => setState(() => _agreed = value == true))),
            Expanded(child: Padding(padding: EdgeInsets.only(top: agreementTop), child: Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              ExcludeSemantics(child: GestureDetector(
                onTap: busy ? null : () => setState(() => _agreed = !_agreed),
                child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text('同意拼多多', style: agreementStyle.copyWith(color: palette.onSurfaceVariant))),
              )),
              TextButton(style: link, onPressed: widget.openTerms, child: const Text('服务协议与隐私政策', style: agreementStyle)),
            ]))),
          ]),
          // 出错提示展开淡入、清掉时淡出收起；减少动画时直接换（AnimatedSize 时长为 0 会在布局里报错）。
          if (motion == Duration.zero) ...[
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: error),
          ] else
            AnimatedSize(
              duration: motion,
              curve: Curves.easeOutCubic,
              alignment: Alignment.topLeft,
              child: AnimatedSwitcher(
                duration: motion,
                layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
                child: _error == null ? const SizedBox(key: ValueKey(null), width: double.infinity) : Padding(key: ValueKey(_error), padding: const EdgeInsets.only(top: 12), child: error),
              ),
            ),
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

// 胶囊输入框（[人工决策] 见 ExpressLoginForm.build）：形状、底色与描边同应用的搜索框 CampusSearchField，占位文字不用浮动标签（标签凸出会顶破胶囊上沿）；
// 聚焦时描边渐变成主色、底色由半透明变实（微亮），胶囊由 AnimatedContainer 画、里面的 TextField 不画边框，点胶囊里文字以外的地方（如 +86）也聚焦输入。
class _CapsuleField extends StatefulWidget {
  const _CapsuleField({
    required this.controller,
    required this.hint,
    required this.keyboardType,
    required this.autofillHints,
    required this.textInputAction,
    required this.inputFormatters,
    this.onSubmitted,
    this.leading,
    this.trailing,
  });
  final TextEditingController controller;
  final String hint;
  final TextInputType keyboardType;
  final List<String> autofillHints;
  final TextInputAction textInputAction;
  final List<TextInputFormatter> inputFormatters;
  final ValueChanged<String>? onSubmitted;
  final Widget? leading;
  final Widget? trailing;

  @override
  State<_CapsuleField> createState() => _CapsuleFieldState();
}

class _CapsuleFieldState extends State<_CapsuleField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _focusChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final focused = _focus.hasFocus;
    final opaque = MediaQuery.highContrastOf(context) || MediaQuery.accessibleNavigationOf(context);
    return GestureDetector(
      onTap: _focus.requestFocus,
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        constraints: const BoxConstraints(minHeight: 52),
        padding: EdgeInsets.only(left: 20, right: widget.trailing == null ? 20 : 6),
        decoration: ShapeDecoration(
          color: palette.surface.withValues(alpha: focused || opaque ? 1 : .91),
          shape: StadiumBorder(side: BorderSide(color: focused ? palette.primary : palette.surfaceBorder, width: focused ? 1.5 : 1)),
        ),
        child: Row(children: [
          if (widget.leading != null) ...[widget.leading!, const SizedBox(width: 12)],
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              keyboardType: widget.keyboardType,
              autofillHints: widget.autofillHints,
              textInputAction: widget.textInputAction,
              inputFormatters: widget.inputFormatters,
              onSubmitted: widget.onSubmitted,
              style: TextStyle(fontSize: 16, color: palette.onSurface),
              decoration: InputDecoration(
                hintText: widget.hint,
                filled: false,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),
          if (widget.trailing != null) ...[const SizedBox(width: 8), widget.trailing!],
        ]),
      ),
    );
  }
}

// 倒数中的「重新发送(59)」：数字滚动（同今天页的倒计时），宽度同 CampusBusyContent 按最宽的 widest 留，按钮不变宽变窄；读屏读整句。
class _Countdown extends StatelessWidget {
  const _Countdown({required this.seconds, required this.widest});
  final int seconds;
  final String widest;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '重新发送($seconds)',
    child: ExcludeSemantics(
      child: SizedBox(
        width: campusTextWidth(context, widest).ceilToDouble() + 32,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const SizedBox.square(dimension: 24, child: CampusIcon(CampusIcons.send)),
          const SizedBox(width: 8),
          const Text('重新发送('),
          CampusRollingText('$seconds', countsDown: true),
          const Text(')'),
        ]),
      ),
    ),
  );
}
