import 'package:superxd/edu/kingo_codec.dart';

class LoginFailure {
  const LoginFailure({required this.code, required this.message, this.detail, this.failCount});
  final String code;
  final String message;
  final String? detail;
  final int? failCount;
}

LoginFailure explainLogin(Object? status, Object? message, Object? rawBody) {
  final raw = message == null ? '' : '$message';
  final bar = raw.indexOf('|');
  final text = bar >= 0 ? raw.substring(0, bar) : raw;
  final failCount = bar >= 0 ? int.tryParse(raw.substring(bar + 1)) : null;
  final code = status == null ? '' : '$status';
  if (code == '200') return const LoginFailure(code: 'OK', message: '登录成功');
  if (raw.isEmpty && (rawBody == null || '$rawBody'.trim().isEmpty)) {
    return const LoginFailure(code: 'SERVER_UNAVAILABLE', message: '教务系统没有返回登录结果');
  }
  if (code == '505' || text.contains('短信')) {
    return LoginFailure(code: 'SMS_REQUIRED', message: '教务要求先完成短信验证才能登录', detail: text);
  }
  if (code == '401' || text.contains('验证码')) {
    return LoginFailure(
      code: 'CAPTCHA_REQUIRED',
      message: '需要填写验证码，或验证码不正确',
      detail: text,
      failCount: failCount,
    );
  }
  if (text.contains('已输错')) {
    return LoginFailure(code: 'PASSWORD_WRONG_COUNT', message: text, detail: text, failCount: failCount);
  }
  if (text.contains('锁定')) {
    return LoginFailure(code: 'ACCOUNT_LOCKED', message: text.isEmpty ? '账号已锁定' : text, detail: text, failCount: failCount);
  }
  if (text.contains('账号或密码')) {
    return LoginFailure(code: 'PASSWORD_WRONG', message: '账号或密码不正确', detail: text);
  }
  if (code == '407' || code == '410') {
    return LoginFailure(code: 'ACCOUNT_STATE', message: text.isEmpty ? '账号状态异常，教务拒绝登录' : text, detail: text);
  }
  if (text.contains('凭证已失效') || text.contains('请重新登录')) {
    return LoginFailure(code: 'SESSION_EXPIRED', message: '教务登录已失效，需要重新登录', detail: text);
  }
  return LoginFailure(code: 'LOGIN_FAILED', message: text.isEmpty ? '登录失败' : text, detail: text);
}

LoginFailure? explainPage(String? html) {
  final text = html ?? '';
  if (text.contains('凭证已失效') || text.contains('kingo.guest')) {
    return const LoginFailure(code: 'SESSION_EXPIRED', message: '教务登录已失效，需要重新登录');
  }
  if (text.contains('未设置作息时间')) {
    return const LoginFailure(code: 'EMPTY', message: '教务系统当前学期未设置作息时间');
  }
  return null;
}

bool captchaRequired(Object? status, Object? message) {
  final raw = message == null ? '' : '$message';
  final bar = raw.indexOf('|');
  final text = bar >= 0 ? raw.substring(0, bar) : raw;
  final failCount = bar >= 0 ? int.tryParse(raw.substring(bar + 1)) : null;
  final code = status == null ? '' : '$status';
  if (code == '200') return false;
  if (code == '401' || text.contains('验证码')) return true;
  if (failCount != null && failCount >= 2) return true;
  return false;
}

String captchaHint(Object? status, Object? message) {
  final code = status == null ? '' : '$status';
  final raw = message == null ? '' : '$message';
  final bar = raw.indexOf('|');
  final text = bar >= 0 ? raw.substring(0, bar) : raw;
  if (code == '401' || text.contains('验证码')) return '验证码不正确，请重新输入';
  if (text.isNotEmpty) return text;
  return '请输入图中的验证码';
}

String charBits(String password) {
  var result = 0;
  for (final code in password.codeUnits) {
    if (code >= 48 && code <= 57) {
      result |= 8;
    } else if (code >= 97 && code <= 122) {
      result |= 4;
    } else if (code >= 65 && code <= 90) {
      result |= 2;
    } else {
      result |= 1;
    }
  }
  return '$result';
}

String buildLoginPlain(String username, String passwordPlain, String pageSession, String captcha) {
  final randnumber = captcha;
  final hidFlag = captcha.isEmpty ? '1' : '';
  final password = hexMd5(hexMd5(passwordPlain) + hexMd5(randnumber.toLowerCase()));
  final expression = charBits(passwordPlain);
  final length = '${passwordPlain.length}';
  final userzh = passwordPlain.toLowerCase().trim().contains(username.toLowerCase().trim()) ? '1' : '0';
  final policy = (passwordPlain.length < 6 || passwordPlain == username) ? '0' : '1';
  final userEncoded = kingoBase64('$username;;$pageSession');
  return '_u$randnumber=$userEncoded'
      '&_p$randnumber=$password'
      '&randnumber=$randnumber'
      '&isPasswordPolicy=$policy'
      '&txt_mm_expression=$expression'
      '&txt_mm_length=$length'
      '&txt_mm_userzh=$userzh'
      '&hid_flag=$hidFlag'
      '&hidlag=1&hid_dxyzm=';
}
