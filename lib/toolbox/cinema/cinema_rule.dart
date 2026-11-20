import 'dart:convert';

// 电影院的规则包（人工决策见 cinema_service.dart 文件头）：写法沿用 Kazumi 的规则（github.com/Predidit/Kazumi，GPL-3.0，见 assets/third_party_notices.txt），
// 第一版只实现它的 API 模式（JSONPath 取值、选集可以是苹果 CMS 那种 $$$、#、$ 分隔的字符串），外加三处扩展：规则自己的 id、搜索结果的海报年份备注路径、云解析 parsers。
// 规则包由维护者本机签名后经中转下发（不进公开仓库），这里是验签之后的外部输入边界：逐项校验，不合格整包不用。

// 一包最多几条规则、几个云解析，载荷多大；tool/cinema_rules.dart 与中转按同一上限。
const cinemaRuleLimit = 64;
const cinemaParserLimit = 8;
const cinemaPackageMaxBytes = 256 * 1024;
// 规则包写法的版本：客户端只认这一版，以后改写法加一。
const cinemaPackageFormat = 1;

final cinemaRuleIdPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,31}$');

class CinemaRuleException implements Exception {
  const CinemaRuleException(this.message);
  final String message;
  @override
  String toString() => 'CinemaRuleException: $message';
}

// 一次请求的模板（同 Kazumi 的 ApiRequestConfig）：url、query、headers、body 里的 @变量 在用时替换。
class CinemaRequest {
  const CinemaRequest({required this.method, required this.url, this.query = const {}, this.headers = const {}, this.bodyType = 'none', this.body});
  final String method;
  final String url;
  final Map<String, String> query;
  final Map<String, String> headers;
  // none、form、json。
  final String bodyType;
  final Object? body;

  static CinemaRequest decode(Object? raw, String where) {
    final map = _map(raw, where);
    final method = (_string(map['method'], '$where.method', fallback: 'GET')).toUpperCase();
    if (method != 'GET' && method != 'POST') throw CinemaRuleException('$where 只支持 GET、POST');
    final url = _string(map['url'], '$where.url');
    final template = Uri.tryParse(url.replaceAll(RegExp(r'@[A-Za-z_][A-Za-z0-9_]*'), 'x'));
    if (template == null || !(template.isScheme('http') || template.isScheme('https')) || template.host.isEmpty || template.userInfo.isNotEmpty) {
      throw CinemaRuleException('$where.url 要是 http(s) 地址');
    }
    final bodyType = _string(map['bodyType'], '$where.bodyType', fallback: 'none');
    if (!const {'none', 'form', 'json'}.contains(bodyType)) throw CinemaRuleException('$where.bodyType 不认识');
    return CinemaRequest(
      method: method,
      url: url,
      query: _stringMap(map['query'], '$where.query'),
      headers: _stringMap(map['headers'], '$where.headers'),
      bodyType: bodyType,
      body: map['body'],
    );
  }
}

// 搜索：listPath 取出每一条，namePath、sourcePath 必有（sourcePath 取到的是这个源里的影片编号或详情页），其余三项是电影院的扩展、可空。
class CinemaSearchConfig {
  const CinemaSearchConfig({required this.request, required this.listPath, required this.namePath, required this.sourcePath, this.coverPath = '', this.yearPath = '', this.remarksPath = ''});
  final CinemaRequest request;
  final String listPath;
  final String namePath;
  final String sourcePath;
  final String coverPath;
  final String yearPath;
  final String remarksPath;
}

// 选集：delimited 是一个字符串里 $$$ 分线路、# 分集、$ 分集名与地址（苹果 CMS），nested 是 JSON 里一层线路一层集。
class CinemaChapterConfig {
  const CinemaChapterConfig({
    required this.request,
    required this.format,
    this.roadNamesPath = '',
    this.roadEpisodesPath = '',
    this.roadSeparator = r'$$$',
    this.episodeSeparator = '#',
    this.fieldSeparator = r'$',
    this.roadsPath = '',
    this.roadNamePath = '',
    this.episodesPath = '',
    this.episodeNamePath = '',
    this.episodeUrlPath = '',
  });
  final CinemaRequest request;
  final String format;
  final String roadNamesPath;
  final String roadEpisodesPath;
  final String roadSeparator;
  final String episodeSeparator;
  final String fieldSeparator;
  final String roadsPath;
  final String roadNamePath;
  final String episodesPath;
  final String episodeNamePath;
  final String episodeUrlPath;
}

// 一条片源规则（Kazumi 的 Plugin 里 API 模式用得到的部分）。
class CinemaRule {
  const CinemaRule({
    required this.id,
    required this.name,
    required this.version,
    required this.userAgent,
    required this.referer,
    required this.adBlocker,
    required this.search,
    required this.chapters,
  });
  final String id;
  final String name;
  final String version;
  // 请求接口与取流时用的 UA（片源的 CDN 按 UA 掐断播放器自带的 UA）；空表示用电影院默认的桌面浏览器 UA。
  final String userAgent;
  // 空表示一律不带 Referer（交接实测：带任何 Referer 都会被部分 CDN 重置连接）。
  final String referer;
  // 过滤播放清单里插的广告片段（按不连续分段的时长判断，同 Kazumi 的 M3u8AdFilter）。
  final bool adBlocker;
  final CinemaSearchConfig search;
  final CinemaChapterConfig chapters;

  // 规则与同意记录按它认：换了接口地址（主机）要重新征得同意。
  String get host => Uri.parse(search.request.url.replaceAll(RegExp(r'@[A-Za-z_][A-Za-z0-9_]*'), 'x')).host;

  static CinemaRule decode(Object? raw, int index) {
    final where = 'rules[$index]';
    final map = _map(raw, where);
    if (_string(map['searchMode'], '$where.searchMode', fallback: 'xpath') != 'api' || _string(map['chapterMode'], '$where.chapterMode', fallback: 'xpath') != 'api') {
      throw CinemaRuleException('$where 现在只支持 API 模式');
    }
    final id = _string(map['id'], '$where.id');
    if (!cinemaRuleIdPattern.hasMatch(id)) throw CinemaRuleException('$where.id 写法不对');
    final searchMap = _map(map['searchApiConfig'], '$where.searchApiConfig');
    final chapterMap = _map(map['chapterApiConfig'], '$where.chapterApiConfig');
    final format = _string(chapterMap['format'], '$where.chapterApiConfig.format', fallback: 'nested');
    if (format != 'delimited' && format != 'nested') throw CinemaRuleException('$where.chapterApiConfig.format 不认识');
    String path(Map<String, Object?> source, String key, String at, {bool optional = false}) {
      final value = _string(source[key], '$at.$key', fallback: optional ? '' : null);
      if (value.isNotEmpty) validateCinemaJsonPath(value);
      return value;
    }

    final search = CinemaSearchConfig(
      request: CinemaRequest.decode(searchMap['request'], '$where.searchApiConfig.request'),
      listPath: path(searchMap, 'listPath', '$where.searchApiConfig'),
      namePath: path(searchMap, 'namePath', '$where.searchApiConfig'),
      sourcePath: path(searchMap, 'sourcePath', '$where.searchApiConfig'),
      coverPath: path(searchMap, 'coverPath', '$where.searchApiConfig', optional: true),
      yearPath: path(searchMap, 'yearPath', '$where.searchApiConfig', optional: true),
      remarksPath: path(searchMap, 'remarksPath', '$where.searchApiConfig', optional: true),
    );
    final chapterAt = '$where.chapterApiConfig';
    final delimited = format == 'delimited';
    final chapters = CinemaChapterConfig(
      request: CinemaRequest.decode(chapterMap['request'], '$chapterAt.request'),
      format: format,
      roadNamesPath: path(chapterMap, 'roadNamesPath', chapterAt, optional: !delimited),
      roadEpisodesPath: path(chapterMap, 'roadEpisodesPath', chapterAt, optional: !delimited),
      roadSeparator: _separator(chapterMap['roadSeparator'], '$chapterAt.roadSeparator', r'$$$'),
      episodeSeparator: _separator(chapterMap['episodeSeparator'], '$chapterAt.episodeSeparator', '#'),
      fieldSeparator: _separator(chapterMap['fieldSeparator'], '$chapterAt.fieldSeparator', r'$'),
      roadsPath: path(chapterMap, 'roadsPath', chapterAt, optional: true),
      roadNamePath: path(chapterMap, 'roadNamePath', chapterAt, optional: true),
      episodesPath: path(chapterMap, 'episodesPath', chapterAt, optional: delimited),
      episodeNamePath: path(chapterMap, 'episodeNamePath', chapterAt, optional: delimited),
      episodeUrlPath: path(chapterMap, 'episodeUrlPath', chapterAt, optional: delimited),
    );
    final searchUses = '${search.request.url}${jsonEncode(search.request.query)}${jsonEncode(search.request.body)}';
    final chapterUses = '${chapters.request.url}${jsonEncode(chapters.request.query)}${jsonEncode(chapters.request.body)}';
    if (!searchUses.contains('@keyword')) throw CinemaRuleException('$where 的搜索请求没用到 @keyword');
    if (!chapterUses.contains('@source')) throw CinemaRuleException('$where 的选集请求没用到 @source');
    return CinemaRule(
      id: id,
      name: _string(map['name'], '$where.name'),
      version: _string(map['version'], '$where.version', fallback: '1'),
      userAgent: _string(map['userAgent'], '$where.userAgent', fallback: ''),
      referer: _string(map['referer'], '$where.referer', fallback: ''),
      adBlocker: map['adBlocker'] == true,
      search: search,
      chapters: chapters,
    );
  }
}

// 云解析：把视频网站的播放页地址交给第三方解析接口，换成可以直接播的地址（请求里用 @url）。
// 回复里 codePath 取到的值按字符串比（交接实测：同一接口有时给数字 200、有时给字符串 "200"），urlPath 取到的可以是密文（cipher）。
class CinemaParser {
  const CinemaParser({required this.id, required this.name, required this.request, required this.codePath, required this.okCode, required this.urlPath, this.titlePath = '', this.typePath = '', this.cipher});
  final String id;
  final String name;
  final CinemaRequest request;
  final String codePath;
  final String okCode;
  final String urlPath;
  final String titlePath;
  final String typePath;
  final CinemaCipher? cipher;

  String get host => Uri.parse(request.url).host;

  static CinemaParser decode(Object? raw, int index) {
    final where = 'parsers[$index]';
    final map = _map(raw, where);
    final id = _string(map['id'], '$where.id');
    if (!cinemaRuleIdPattern.hasMatch(id)) throw CinemaRuleException('$where.id 写法不对');
    final request = CinemaRequest.decode(map['request'], '$where.request');
    if (!'${request.url}${jsonEncode(request.query)}${jsonEncode(request.body)}'.contains('@url')) throw CinemaRuleException('$where 的请求没用到 @url');
    String path(String key, {bool optional = false}) {
      final value = _string(map[key], '$where.$key', fallback: optional ? '' : null);
      if (value.isNotEmpty) validateCinemaJsonPath(value);
      return value;
    }

    return CinemaParser(
      id: id,
      name: _string(map['name'], '$where.name'),
      request: request,
      codePath: path('codePath'),
      okCode: _string(map['okCode'], '$where.okCode'),
      urlPath: path('urlPath'),
      titlePath: path('titlePath', optional: true),
      typePath: path('typePath', optional: true),
      cipher: map['cipher'] == null ? null : CinemaCipher.decode(map['cipher'], '$where.cipher'),
    );
  }
}

// 回复里地址的加密：现在只有 AES-128-CBC 加 PKCS7（key、iv 是 16 个字符的原文，不是口令派生），密文是 base64。
class CinemaCipher {
  const CinemaCipher({required this.key, required this.iv});
  final List<int> key;
  final List<int> iv;

  static CinemaCipher decode(Object? raw, String where) {
    final map = _map(raw, where);
    if (_string(map['algorithm'], '$where.algorithm') != 'aes-128-cbc') throw CinemaRuleException('$where.algorithm 只支持 aes-128-cbc');
    final key = utf8.encode(_string(map['key'], '$where.key'));
    final iv = utf8.encode(_string(map['iv'], '$where.iv'));
    if (key.length != 16 || iv.length != 16) throw CinemaRuleException('$where 的 key、iv 要各 16 字节');
    return CinemaCipher(key: key, iv: iv);
  }
}

class CinemaPackage {
  const CinemaPackage({required this.version, required this.minClient, required this.rules, required this.parsers});
  // 规则包的版本，只升不降（本机缓存的比拉到的新就不换，挡回放旧包）。
  final int version;
  // 这包至少要哪个构建号的客户端（规则用到新写法时设）；低于它的客户端照旧用本机缓存的旧包。
  final int minClient;
  final List<CinemaRule> rules;
  final List<CinemaParser> parsers;
}

// 验签后的载荷字节 → 规则包；任何一项不合格都抛 CinemaRuleException，整包不用。
CinemaPackage decodeCinemaPackage(List<int> payload) {
  if (payload.length > cinemaPackageMaxBytes) throw const CinemaRuleException('规则包太大');
  final Object? raw;
  try {
    raw = jsonDecode(utf8.decode(payload));
  } on FormatException catch (error) {
    throw CinemaRuleException('规则包不是 JSON：${error.message}');
  }
  final map = _map(raw, '规则包');
  if (map['format'] != cinemaPackageFormat) throw const CinemaRuleException('规则包写法的版本不认识');
  final version = map['version'];
  final minClient = map['minClient'] ?? 0;
  if (version is! int || version < 1 || minClient is! int || minClient < 0) throw const CinemaRuleException('规则包的 version、minClient 要是整数');
  final rawRules = map['rules'];
  final rawParsers = map['parsers'] ?? const <Object?>[];
  if (rawRules is! List || rawRules.isEmpty || rawRules.length > cinemaRuleLimit) throw const CinemaRuleException('rules 要有 1 到 $cinemaRuleLimit 条');
  if (rawParsers is! List || rawParsers.length > cinemaParserLimit) throw const CinemaRuleException('parsers 最多 $cinemaParserLimit 个');
  final rules = [for (var index = 0; index < rawRules.length; index++) CinemaRule.decode(rawRules[index], index)];
  final parsers = [for (var index = 0; index < rawParsers.length; index++) CinemaParser.decode(rawParsers[index], index)];
  if (rules.map((rule) => rule.id).toSet().length != rules.length) throw const CinemaRuleException('rules 的 id 重复');
  if (parsers.map((parser) => parser.id).toSet().length != parsers.length) throw const CinemaRuleException('parsers 的 id 重复');
  return CinemaPackage(version: version, minClient: minClient, rules: rules, parsers: parsers);
}

// 只认 Kazumi 限定的 JSONPath 写法：$ 开头，后面是 .名字、[数字]、[*]、['名字']（同它的 RestrictedJsonPath，挡住过滤表达式这类重活）。
void validateCinemaJsonPath(String expression) {
  if (!RegExp(r'''^\$((\.[A-Za-z0-9_$-]+)|(\[(\d+|\*|'[^']*'|"[^"]*")\]))*$''').hasMatch(expression)) {
    throw CinemaRuleException('不支持的 JSONPath：$expression');
  }
}

Map<String, Object?> _map(Object? raw, String where) {
  if (raw is! Map) throw CinemaRuleException('$where 要是对象');
  return {for (final entry in raw.entries) entry.key.toString(): entry.value};
}

String _string(Object? raw, String where, {String? fallback}) {
  if (raw == null && fallback != null) return fallback;
  if (raw is num) return raw.toString();
  if (raw is! String || (fallback == null && raw.trim().isEmpty)) throw CinemaRuleException('$where 要是非空字符串');
  if (raw.length > 2048) throw CinemaRuleException('$where 太长');
  return raw.trim();
}

String _separator(Object? raw, String where, String fallback) {
  final value = raw ?? fallback;
  if (value is! String || value.isEmpty || value.length > 8) throw CinemaRuleException('$where 要是 1 到 8 个字符');
  return value;
}

Map<String, String> _stringMap(Object? raw, String where) {
  if (raw == null) return const {};
  final map = _map(raw, where);
  if (map.length > 32) throw CinemaRuleException('$where 项太多');
  return {for (final entry in map.entries) entry.key: _string(entry.value, '$where.${entry.key}', fallback: '')};
}
