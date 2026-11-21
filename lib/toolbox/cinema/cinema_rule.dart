import 'dart:convert';

// 电影院的规则包（人工决策见 cinema_service.dart 文件头）：写法沿用 Kazumi 的规则（github.com/Predidit/Kazumi，GPL-3.0，见 assets/third_party_notices.txt），
// 第一版只实现它的 API 模式（JSONPath 取值、选集可以是苹果 CMS 那种 $$$、#、$ 分隔的字符串），外加三处扩展：规则自己的 id、搜索结果的海报年份备注路径、云解析 parsers。
// 11-20 起另有片名目录型的源 catalogRules（采集站接口不给搜索的，如 wsy，见 CinemaCatalogConfig；片名目录在中转上）：放在单独的顶层字段，1.0.0-alpha.34 不认这个字段、直接忽略，不会整包拒收。
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

// 搜索：listPath 取出每一条，namePath、sourcePath 必有（sourcePath 取到的是这个源里的影片编号或详情页），其余是电影院的扩展、可空。
// chapters（11-20 起，可空）：搜索回复里每一条自带的剧集（苹果 CMS 的 ac=detail 搜索就带全部播放地址），路径相对每一条记录、格式与分隔符同 chapterApiConfig；
// 写了的源搜到就记下选集，点开不再请求详情（见 CinemaService.chapters）。旧版本不认这个字段、照旧忽略。
class CinemaSearchConfig {
  const CinemaSearchConfig({required this.request, required this.listPath, required this.namePath, required this.sourcePath, this.coverPath = '', this.yearPath = '', this.remarksPath = '', this.chapters});
  final CinemaRequest request;
  final String listPath;
  final String namePath;
  final String sourcePath;
  final String coverPath;
  final String yearPath;
  final String remarksPath;
  // 路径相对每一条记录，request 不用（同搜索请求）。
  final CinemaChapterConfig? chapters;
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

// 片名目录型的源：采集站把关键字搜索关了（wsy 的 ?ac=list&wd= 回「暂不支持搜索」），只能按编号取详情。
// 片名目录由中转维护（人工决策见 cinema_catalog.dart 文件头）：中转按 update 请求（@hours 是离上次多少小时、@page 第几页）定时向源取片名，
// 这里只核对写法（中转读同一份规则包），手机不用它；手机搜索时请中转查出编号，再按这个源的 searchApiConfig 请求（@ids 是逗号连起来的编号）取详情。
class CinemaCatalogConfig {
  const CinemaCatalogConfig({required this.update, required this.listPath, required this.idPath, required this.namePath, required this.pageCountPath});
  final CinemaRequest update;
  final String listPath;
  final String idPath;
  final String namePath;
  final String pageCountPath;

  static CinemaCatalogConfig decode(Object? raw, String where) {
    final map = _map(raw, where);
    final updateMap = _map(map['update'], '$where.update');
    final update = CinemaRequest.decode(updateMap['request'], '$where.update.request');
    if (update.method != 'GET') throw CinemaRuleException('$where.update 只支持 GET');
    final uses = '${update.url}${jsonEncode(update.query)}';
    if (!uses.contains('@hours') || !uses.contains('@page')) throw CinemaRuleException('$where.update 的请求要用到 @hours 与 @page');
    String path(String key) {
      final value = _string(updateMap[key], '$where.update.$key');
      validateCinemaJsonPath(value);
      return value;
    }

    return CinemaCatalogConfig(update: update, listPath: path('listPath'), idPath: path('idPath'), namePath: path('namePath'), pageCountPath: path('pageCountPath'));
  }
}

// 一条片源规则（Kazumi 的 Plugin 里 API 模式用得到的部分）；catalog 不为空的是片名目录型（搜索请求用 @ids）。
class CinemaRule {
  const CinemaRule({
    required this.id,
    required this.name,
    required this.version,
    required this.userAgent,
    required this.referer,
    required this.search,
    required this.chapters,
    this.catalog,
  });
  final String id;
  final String name;
  final String version;
  // 请求接口与取流时用的 UA（片源的 CDN 按 UA 掐断播放器自带的 UA）；空表示用电影院默认的桌面浏览器 UA。
  final String userAgent;
  // 空表示一律不带 Referer（交接实测：带任何 Referer 都会被部分 CDN 重置连接）。
  final String referer;
  // 规则里的 adBlocker（去广告）不再读：播放清单一个分片都不删，人工决策见 cinema_playlist.dart 文件头。
  final CinemaSearchConfig search;
  final CinemaChapterConfig chapters;
  final CinemaCatalogConfig? catalog;

  // 规则与同意记录按它认：换了接口地址（主机）要重新征得同意。
  String get host => Uri.parse(search.request.url.replaceAll(RegExp(r'@[A-Za-z_][A-Za-z0-9_]*'), 'x')).host;

  static CinemaRule decode(Object? raw, int index, {bool catalog = false}) {
    final where = catalog ? 'catalogRules[$index]' : 'rules[$index]';
    final map = _map(raw, where);
    if (_string(map['searchMode'], '$where.searchMode', fallback: 'xpath') != (catalog ? 'catalog' : 'api') || _string(map['chapterMode'], '$where.chapterMode', fallback: 'xpath') != 'api') {
      throw CinemaRuleException(catalog ? '$where 要是片名目录加 API 选集' : '$where 现在只支持 API 模式');
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

    final chapterAt = '$where.chapterApiConfig';
    final delimited = format == 'delimited';
    // 选集的路径一组：chapterApiConfig 自己的（相对详情回复），或搜索配置里 chapters 的（相对每一条记录）；格式与分隔符都用 chapterApiConfig 的。
    CinemaChapterConfig chapterPaths(Map<String, Object?> source, String at, CinemaRequest request) => CinemaChapterConfig(
      request: request,
      format: format,
      roadNamesPath: path(source, 'roadNamesPath', at, optional: !delimited),
      roadEpisodesPath: path(source, 'roadEpisodesPath', at, optional: !delimited),
      roadSeparator: _separator(chapterMap['roadSeparator'], '$chapterAt.roadSeparator', r'$$$'),
      episodeSeparator: _separator(chapterMap['episodeSeparator'], '$chapterAt.episodeSeparator', '#'),
      fieldSeparator: _separator(chapterMap['fieldSeparator'], '$chapterAt.fieldSeparator', r'$'),
      roadsPath: path(source, 'roadsPath', at, optional: true),
      roadNamePath: path(source, 'roadNamePath', at, optional: true),
      episodesPath: path(source, 'episodesPath', at, optional: delimited),
      episodeNamePath: path(source, 'episodeNamePath', at, optional: delimited),
      episodeUrlPath: path(source, 'episodeUrlPath', at, optional: delimited),
    );
    final chapters = chapterPaths(chapterMap, chapterAt, CinemaRequest.decode(chapterMap['request'], '$chapterAt.request'));
    final searchRequest = CinemaRequest.decode(searchMap['request'], '$where.searchApiConfig.request');
    final search = CinemaSearchConfig(
      request: searchRequest,
      listPath: path(searchMap, 'listPath', '$where.searchApiConfig'),
      namePath: path(searchMap, 'namePath', '$where.searchApiConfig'),
      sourcePath: path(searchMap, 'sourcePath', '$where.searchApiConfig'),
      coverPath: path(searchMap, 'coverPath', '$where.searchApiConfig', optional: true),
      yearPath: path(searchMap, 'yearPath', '$where.searchApiConfig', optional: true),
      remarksPath: path(searchMap, 'remarksPath', '$where.searchApiConfig', optional: true),
      chapters: searchMap['chapters'] == null ? null : chapterPaths(_map(searchMap['chapters'], '$where.searchApiConfig.chapters'), '$where.searchApiConfig.chapters', searchRequest),
    );
    final searchUses = '${search.request.url}${jsonEncode(search.request.query)}${jsonEncode(search.request.body)}';
    final chapterUses = '${chapters.request.url}${jsonEncode(chapters.request.query)}${jsonEncode(chapters.request.body)}';
    if (!searchUses.contains(catalog ? '@ids' : '@keyword')) throw CinemaRuleException(catalog ? '$where 的详情请求没用到 @ids' : '$where 的搜索请求没用到 @keyword');
    if (!chapterUses.contains('@source')) throw CinemaRuleException('$where 的选集请求没用到 @source');
    return CinemaRule(
      id: id,
      name: _string(map['name'], '$where.name'),
      version: _string(map['version'], '$where.version', fallback: '1'),
      userAgent: _string(map['userAgent'], '$where.userAgent', fallback: ''),
      referer: _string(map['referer'], '$where.referer', fallback: ''),
      search: search,
      chapters: chapters,
      catalog: catalog ? CinemaCatalogConfig.decode(map['catalog'], '$where.catalog') : null,
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
  final rawCatalogs = map['catalogRules'] ?? const <Object?>[];
  final rawParsers = map['parsers'] ?? const <Object?>[];
  if (rawRules is! List || rawCatalogs is! List || rawRules.isEmpty || rawRules.length + rawCatalogs.length > cinemaRuleLimit) throw const CinemaRuleException('rules 要有 1 条起，连同 catalogRules 最多 $cinemaRuleLimit 条');
  if (rawParsers is! List || rawParsers.length > cinemaParserLimit) throw const CinemaRuleException('parsers 最多 $cinemaParserLimit 个');
  // 片名目录型的接在普通源后面（规则包里的先后就是聚合与列失败的先后）。
  final rules = [
    for (var index = 0; index < rawRules.length; index++) CinemaRule.decode(rawRules[index], index),
    for (var index = 0; index < rawCatalogs.length; index++) CinemaRule.decode(rawCatalogs[index], index, catalog: true),
  ];
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
