import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:enough_convert/enough_convert.dart';
import 'package:http/http.dart' as http;

import 'package:superxd/edu/kingo_codec.dart';
import 'package:superxd/edu/login_rules.dart';
import 'package:superxd/edu/parse_bells.dart';
import 'package:superxd/edu/parse_grades.dart';
import 'package:superxd/domain/grades.dart';
import 'package:superxd/edu/parse_schedule.dart';
import 'package:superxd/edu/parse_terms.dart';

const kingoBase = 'http://42.247.18.146';
const kingoUserAgent = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36';

class KingoClient {
  KingoClient({http.Client? client, this.base = kingoBase, this.requestTimeout = const Duration(seconds: 25)}) : _client = client ?? http.Client();

  final Duration requestTimeout;

  final http.Client _client;
  final String base;
  final Map<String, String> jar = {};
  String pageSession = '';
  final Set<Completer<void>> _requests = {};
  int _requestEpoch = 0;
  bool _disposed = false;

  void cancelRequests() {
    _requestEpoch++;
    for (final request in _requests) {
      if (!request.isCompleted) request.complete();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelRequests();
    _client.close();
    jar.clear();
    pageSession = '';
  }

  Future<KingoLoginResult> login(String username, String password, {String captcha = ''}) async {
    if (pageSession.isEmpty) {
      final page = await _get('/cas/login.action');
      pageSession = RegExp(r'_ssessionid\s*=\s*"([^"]+)"').firstMatch(page.body)?.group(1) ?? jar['JSESSIONID'] ?? '';
      if (pageSession.isEmpty) throw StateError('login.action 没有会话');
    }
    final rand = '${DateTime.now().microsecondsSinceEpoch}';
    await _get('/custom/js/GetKingoEncypt.jsp?random=$rand', referer: '/cas/login.action');
    await _get('/custom/js/SetKingoEncypt.jsp?random=$rand', referer: '/cas/login.action');
    final deskey = (await _get('/frame/homepage?method=getTempDeskey', referer: '/cas/login.action')).body.trim();
    final timestamp = (await _get('/frame/homepage?method=getTempNowtime', referer: '/cas/login.action')).body.trim();
    if (deskey.isEmpty || timestamp.isEmpty) throw StateError('临时密钥或时间戳为空');
    final plain = buildLoginPlain(username, password, pageSession, captcha);
    final body = 'params=${encryptLoginParams(plain, deskey)}&token=${loginToken(plain, timestamp)}&timestamp=$timestamp&deskey=&ssessionid=$pageSession';
    final posted = await _post('/cas/logon.action', body, referer: '/cas/login.action');
    Map<String, Object?>? data;
    try {
      data = (jsonDecode(posted.body) as Map).cast<String, Object?>();
    } catch (error, stack) {
      stderr.writeln('[KingoClient] action=login_decode errorType=${error.runtimeType}\n$stack');
      data = null;
    }
    final status = data?['status'];
    final message = data?['message'];
    final needsCaptcha = captchaRequired(status, message);
    CaptchaViewData? captchaView;
    if (needsCaptcha) {
      final image = await _getBytes('/cas/genValidateCode?v=${DateTime.now().millisecondsSinceEpoch % 100 + 1}', accept: 'image/jpeg,image/*');
      captchaView = CaptchaViewData(
        prompt: '请输入图中的验证码',
        hint: captchaHint(status, message),
        contentType: (image.headers['content-type'] ?? 'image/jpeg').split(';').first,
        imageBase64: base64Encode(image.bodyBytes),
      );
    }
    String? loginId;
    String userCode = '';
    String currentXn = '';
    String currentXq = '';
    if (data != null && '$status' == '200' && data['result'] != null) {
      var location = '${data['result']}';
      if (!location.startsWith('http')) location = '$base${location.startsWith('/') ? '' : '/'}$location';
      await _get(location.replaceFirst(base, ''), referer: '/cas/login.action');
      final info = await _get('/frame/home/js/SetMainInfo.jsp', referer: location.replaceFirst(base, ''));
      final profile = _profileOf(info.body);
      loginId = profile.loginId;
      userCode = profile.userCode;
      currentXn = profile.xn;
      currentXq = profile.xq;
    }
    final terms = <({String xn, String xq, String label})>[];
    if (data != null && '$status' == '200') {
      final listed = await listTerms();
      terms.addAll(listed.terms.map((term) => (xn: term.xn, xq: term.xq, label: term.label)));
    }
    return KingoLoginResult(
      ok: data != null && '$status' == '200',
      needsCaptcha: needsCaptcha,
      failure: needsCaptcha ? null : explainLogin(status, message, posted.body),
      captcha: captchaView,
      loginId: loginId,
      userCode: userCode,
      currentXn: currentXn,
      currentXq: currentXq,
      terms: terms,
    );
  }

  Future<CaptchaViewData> fetchCaptcha() async {
    final image = await _getBytes('/cas/genValidateCode?v=${DateTime.now().millisecondsSinceEpoch % 100 + 1}', accept: 'image/jpeg,image/*');
    return CaptchaViewData(
      prompt: '请输入图中的验证码',
      hint: '请输入图中的验证码',
      contentType: (image.headers['content-type'] ?? 'image/jpeg').split(';').first,
      imageBase64: base64Encode(image.bodyBytes),
    );
  }

  Future<KingoProfile> fetchProfile() async {
    final info = await _get('/frame/home/js/SetMainInfo.jsp', referer: '/frame/homes.action');
    _throwIfExpired(info.body);
    final profile = _profileOf(info.body);
    if (profile.userCode.isEmpty || profile.xn.isEmpty || profile.xq.isEmpty) {
      throw KingoCallException(const LoginFailure(code: 'UPSTREAM_FORMAT', message: '教务身份信息格式异常'));
    }
    return profile;
  }

  Future<({List<ParsedTerm> terms, ({String xn, String xq})? published})> listTerms() async {
    final shell = await _get('/public/SchoolTimetable.jsp', accept: 'text/html');
    final posted = await _post(
      '/frame/droplist/getDropLists.action',
      'comboBoxName=MsXnxqDxDesc&paramValue=&isYXB=0&isCDDW=0&isXQ=0&isDJKSLB=0&isZY=0',
      referer: '/public/SchoolTimetable.jsp',
      accept: 'application/json',
    );
    return (terms: parseTerms(jsonDecode(posted.body) as List<Object?>), published: parsePublicCurrent(shell.body));
  }

  Future<ParsedSchedule> fetchSchedule({required String xn, required String xq, required String userCode}) async {
    final plain = 'xn=$xn&xq=$xq&xh=$userCode';
    final params = Uri.encodeQueryComponent(utf8Base64(plain));
    final page = await _get('/wsxk/xkjg.ckdgxsxdkchj_data10319.jsp?params=$params', referer: '/student/xkjg.wdkb.jsp?menucode=S20301');
    _throwIfExpired(page.body);
    try {
      return parseScheduleHtml(page.body);
    } on ScheduleParseException catch (error, stack) {
      stderr.writeln('[KingoClient] action=schedule_parse term=$xn-$xq reason=${error.message}\n$stack');
      throw KingoCallException(LoginFailure(code: 'UPSTREAM_FORMAT', message: '课表解析失败：${error.message}，未覆盖已有缓存'));
    }
  }

  Future<({String rxnj, String nj})> fetchGradeForm() async {
    final page = await _get('/student/xscj.stuckcj.jsp?menucode=S40303', referer: '/frame/homes.action');
    _throwIfExpired(page.body);
    final rxnj = RegExp(r'id="rxnj"[^>]*value="([^"]*)"').firstMatch(page.body)?.group(1) ?? '';
    final nj = RegExp(r'id="nj"[^>]*value="([^"]*)"').firstMatch(page.body)?.group(1) ?? '';
    if (rxnj.isEmpty) {
      throw KingoCallException(const LoginFailure(code: 'UPSTREAM_FORMAT', message: '教务成绩查询页格式异常'));
    }
    return (rxnj: rxnj, nj: nj.isEmpty ? rxnj : nj);
  }

  Future<({ParsedGrades effective, ParsedGrades original})> fetchGrades({
    required String xn,
    required String xq,
    required String rxnj,
    required String nj,
  }) async {
    final effective = await _grades('yxcj', xn: xn, xq: xq, rxnj: rxnj, nj: nj);
    final original = await _grades('yscj', xn: xn, xq: xq, rxnj: rxnj, nj: nj);
    return (effective: effective, original: original);
  }

  Future<ParsedBells> fetchBells({required String xn, required String xq}) async {
    await _get('/public/SchoolTimetable.jsp', accept: 'text/html');
    final page = await _post(
      '/public/SchoolTimetable.show.jsp',
      'menucode=&xn=$xn&xq_m=$xq&is_ssxq=0&btnQry=%BC%EC%CB%F7',
      referer: '/public/SchoolTimetable.jsp',
      accept: 'text/html',
    );
    _throwIfExpired(page.body);
    if (!page.body.contains('作息时间')) throw const FormatException('作息页面结构无法识别');
    final parsed = parseBellsHtml(page.body);
    if (parsed.periods.isEmpty && !page.body.contains('未设置作息时间')) throw const FormatException('作息页面缺少时间数据');
    return parsed;
  }

  Future<ParsedGrades> _grades(String kind, {required String xn, required String xq, required String rxnj, required String nj}) async {
    final page = await _post(
      '/student/xscj.stuckcj_data.jsp',
      buildGradeBody(kind: kind, xn: xn, xq: xq, rxnj: rxnj, nj: nj),
      referer: '/student/xscj.stuckcj.jsp?menucode=S40303',
    );
    _throwIfExpired(page.body);
    return kind == 'yscj' ? parseOriginalGrades(page.body) : parseEffectiveGrades(page.body);
  }

  KingoProfile _profileOf(String html) {
    var userCode = RegExp(r"G_USER_CODE\s*=\s*'([^']*)'").firstMatch(html)?.group(1) ?? '';
    if (userCode == 'kingo.guest') userCode = '';
    return KingoProfile(
      userCode: userCode,
      xn: RegExp(r"_currentXn\s*=\s*'([^']*)'").firstMatch(html)?.group(1) ?? '',
      xq: RegExp(r"_currentXq\s*=\s*'([^']*)'").firstMatch(html)?.group(1) ?? '',
      loginId: RegExp(r"_loginid\s*=\s*'([^']*)'").firstMatch(html)?.group(1) ?? '',
    );
  }

  void _throwIfExpired(String html) {
    final failure = explainPage(html);
    if (failure?.code == 'SESSION_EXPIRED') throw KingoCallException(failure!);
    if (html.contains('请重新登录') || html.contains('/cas/logon.action') || RegExp(r'''location(?:\.href)?\s*=\s*['"][^'"]*cas/login''').hasMatch(html)) {
      throw KingoCallException(const LoginFailure(code: 'SESSION_EXPIRED', message: '教务登录已失效，需要重新登录'));
    }
  }

  Future<KingoResponse> _get(String path, {String? referer, String accept = 'text/plain, */*; q=0.01'}) {
    return _send('GET', path, null, referer: referer, accept: accept);
  }

  Future<KingoResponse> _getBytes(String path, {required String accept}) {
    return _send('GET', path, null, accept: accept);
  }

  Future<KingoResponse> _post(String path, String body, {String? referer, String accept = 'text/html, */*; q=0.01'}) {
    return _send('POST', path, body, referer: referer, accept: accept);
  }

  Future<KingoResponse> _send(String method, String path, String? body, {String? referer, required String accept}) async {
    final uri = Uri.parse(path.startsWith('http') ? path : '$base$path');
    if (_disposed) throw http.RequestAbortedException(uri);
    if (uri.origin != Uri.parse(base).origin) throw const FormatException('教务返回了非同源地址');
    final epoch = _requestEpoch;
    final abort = Completer<void>();
    _requests.add(abort);
    final request = http.AbortableRequest(method, uri, abortTrigger: abort.future)..followRedirects = false;
    request.headers['User-Agent'] = kingoUserAgent;
    request.headers['Accept'] = accept;
    if (jar.isNotEmpty) request.headers['Cookie'] = jar.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');
    if (referer != null) request.headers['Referer'] = referer.startsWith('http') ? referer : '$base$referer';
    if (body != null) {
      request.headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8';
      request.body = body;
    }
    late final http.Response response;
    try {
      response = await Future.any([
        (() async {
          final streamed = await _client.send(request);
          if (uri.path.endsWith('/xscj.stuckcj_data.jsp')) {
            final bytes = <int>[];
            await for (final chunk in streamed.stream) {
              if (bytes.length + chunk.length > gradePayloadLimit) {
                throw const FormatException('成绩响应超过容量上限');
              }
              bytes.addAll(chunk);
            }
            return http.Response.bytes(bytes, streamed.statusCode, headers: streamed.headers, request: request);
          }
          return http.Response.fromStream(streamed);
        })(),
        abort.future.then<http.Response>((_) => throw http.RequestAbortedException(uri)),
      ]).timeout(requestTimeout, onTimeout: () {
        if (!abort.isCompleted) abort.complete();
        throw TimeoutException('教务请求超时', requestTimeout);
      });
    } finally {
      _requests.remove(abort);
    }
    // 即使测试传输或平台未响应 abort，取消后的迟到响应也不能改写 cookie。
    if (_disposed || epoch != _requestEpoch) throw http.RequestAbortedException(uri);
    if (response.statusCode >= 300 && response.statusCode < 400 && (response.headers['location'] ?? '').contains('/cas/login')) {
      throw KingoCallException(const LoginFailure(code: 'SESSION_EXPIRED', message: '教务登录已失效，需要重新登录'));
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KingoCallException(LoginFailure(code: 'UPSTREAM_HTTP', message: '教务请求失败（HTTP ${response.statusCode}）'));
    }
    _mergeCookie(response);
    return KingoResponse(response.statusCode, accept.startsWith('image/') ? '' : _decode(response.bodyBytes, response.headers['content-type']), response.headers, response.bodyBytes);
  }

  void _mergeCookie(http.Response response) {
    final raw = response.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return;
    for (final part in raw.split(RegExp(r', (?=[^ ;,]+=)'))) {
      final pair = part.split(';').first.trim();
      final index = pair.indexOf('=');
      if (index > 0) jar[pair.substring(0, index)] = pair.substring(index + 1);
    }
  }

  String _decode(List<int> bytes, String? contentType) {
    final head = latin1.decode(bytes.take(1000).toList());
    final charset = RegExp(r'''charset\s*=\s*["']?([\w-]+)''', caseSensitive: false).firstMatch('${contentType ?? ''} $head')?.group(1)?.toLowerCase() ?? '';
    if (charset.contains('gb')) return gbk.decode(bytes);
    try {
      return utf8.decode(bytes);
    } on FormatException catch (error, stack) {
      stderr.writeln('[KingoClient] action=decode charset=gbk_fallback errorType=${error.runtimeType}\n$stack');
      return gbk.decode(bytes);
    }
  }
}

class KingoResponse {
  KingoResponse(this.status, this.body, this.headers, this.bodyBytes);
  final int status;
  final String body;
  final Map<String, String> headers;
  final List<int> bodyBytes;
}

class CaptchaViewData {
  const CaptchaViewData({required this.prompt, required this.hint, required this.contentType, required this.imageBase64});
  final String prompt;
  final String hint;
  final String contentType;
  final String imageBase64;
}

class KingoProfile {
  const KingoProfile({required this.userCode, required this.xn, required this.xq, required this.loginId});
  final String userCode;
  final String xn;
  final String xq;
  final String loginId;
}

class KingoCallException implements Exception {
  KingoCallException(this.failure);
  final LoginFailure failure;
}

class KingoLoginResult {
  const KingoLoginResult({
    required this.ok,
    required this.needsCaptcha,
    required this.failure,
    required this.captcha,
    required this.loginId,
    this.userCode = '',
    this.currentXn = '',
    this.currentXq = '',
    this.terms = const [],
  });
  final bool ok;
  final bool needsCaptcha;
  final LoginFailure? failure;
  final CaptchaViewData? captcha;
  final String? loginId;
  final String userCode;
  final String currentXn;
  final String currentXq;
  final List<({String xn, String xq, String label})> terms;
}
