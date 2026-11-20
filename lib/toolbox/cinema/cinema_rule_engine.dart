import 'dart:convert';

import 'package:json_path/json_path.dart';

import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';

// 规则引擎（API 模式，移植自 Kazumi 的 ApiRuleStrategy）：把请求模板填成一次请求，把回复按 JSONPath 取成搜索结果与选集。
// 只做纯计算，不发请求（请求在 cinema_http.dart）。

class CinemaPreparedRequest {
  const CinemaPreparedRequest({required this.method, required this.uri, required this.headers, this.body});
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String? body;
}

// 填模板：url 里的 @变量按 URL 编码替换，query、headers、body 里的原样替换（交给 Uri 与表单编码）。没给的变量抛错。
CinemaPreparedRequest prepareCinemaRequest(CinemaRequest request, Map<String, String> variables) {
  String render(String template, {bool encode = false}) => template.replaceAllMapped(RegExp(r'(?<![A-Za-z0-9_])@([A-Za-z_][A-Za-z0-9_]*)'), (match) {
    final value = variables[match.group(1)!];
    if (value == null) throw CinemaRuleException('缺少模板变量 @${match.group(1)}');
    return encode ? Uri.encodeComponent(value) : value;
  });
  Object? renderValue(Object? value) => switch (value) {
    final String text => render(text),
    final List<Object?> list => [for (final item in list) renderValue(item)],
    final Map<Object?, Object?> map => {for (final entry in map.entries) render(entry.key.toString()): renderValue(entry.value)},
    _ => value,
  };
  final base = Uri.parse(render(request.url, encode: true));
  final query = {...base.queryParameters, for (final entry in request.query.entries) render(entry.key): render(entry.value)};
  final uri = query.isEmpty ? base : base.replace(queryParameters: query);
  final headers = {for (final entry in request.headers.entries) entry.key.toLowerCase(): render(entry.value)};
  String? body;
  if (request.method == 'POST' && request.bodyType != 'none') {
    final rendered = renderValue(request.body);
    if (request.bodyType == 'json') {
      headers.putIfAbsent('content-type', () => 'application/json');
      body = jsonEncode(rendered);
    } else {
      if (rendered is! Map) throw const CinemaRuleException('表单 body 要是对象');
      headers.putIfAbsent('content-type', () => 'application/x-www-form-urlencoded');
      body = rendered.entries.map((entry) => '${Uri.encodeQueryComponent(entry.key.toString())}=${Uri.encodeQueryComponent('${entry.value ?? ''}')}').join('&');
    }
  }
  return CinemaPreparedRequest(method: request.method, uri: uri, headers: headers, body: body);
}

// 采集站的回复常是 Content-Type: text/html 但内容是 JSON（交接踩坑第 5 条），不看头直接按 JSON 解。
Object? decodeCinemaJson(String raw) {
  try {
    return jsonDecode(raw);
  } on FormatException {
    throw const CinemaRuleException('返回的不是 JSON');
  }
}

List<Object?> readCinemaPath(Object? document, String expression) {
  validateCinemaJsonPath(expression);
  return JsonPath(expression).readValues(document).toList();
}

String _first(Object? document, String expression) {
  if (expression.isEmpty) return '';
  final values = readCinemaPath(document, expression);
  final value = values.isEmpty ? null : values.first;
  return switch (value) {
    null => '',
    final String text => text.trim(),
    final num number => number.toString(),
    _ => '',
  };
}

List<CinemaHit> parseCinemaSearch(String raw, CinemaRule rule) {
  final config = rule.search;
  final document = decodeCinemaJson(raw);
  final hits = <CinemaHit>[];
  for (final node in readCinemaPath(document, config.listPath)) {
    final name = _first(node, config.namePath);
    final source = _first(node, config.sourcePath);
    if (name.isEmpty || source.isEmpty) continue;
    hits.add(CinemaHit(
      ruleId: rule.id,
      source: source,
      name: name,
      cover: _first(node, config.coverPath),
      year: cinemaYear(_first(node, config.yearPath)),
      remarks: _first(node, config.remarksPath),
    ));
  }
  return hits;
}

// 选集：只留能直接播的媒体地址（见 cinemaMediaUrl），去掉后空了的线路整条不要（采集站常同时给分享页与直链两组，交接 03.2）。
// 相对地址按选集请求的地址补全。
List<CinemaRoad> parseCinemaChapters(String raw, CinemaRule rule, Uri requestUri) {
  final config = rule.chapters;
  final document = decodeCinemaJson(raw);
  final roads = <CinemaRoad>[];
  void add(String name, List<(String, String)> entries) {
    final episodes = <CinemaEpisode>[];
    for (final (index, (episodeName, rawUrl)) in entries.indexed) {
      final url = rawUrl.isEmpty ? '' : requestUri.resolve(rawUrl.trim()).toString();
      if (!cinemaMediaUrl(url)) continue;
      episodes.add(CinemaEpisode(name: episodeName.isEmpty ? '第 ${index + 1} 集' : episodeName, url: url));
    }
    if (episodes.isNotEmpty) roads.add(CinemaRoad(name: name.isEmpty ? '线路 ${roads.length + 1}' : name, episodes: episodes));
  }

  if (config.format == 'delimited') {
    final names = _first(document, config.roadNamesPath).split(config.roadSeparator);
    final groups = _first(document, config.roadEpisodesPath).split(config.roadSeparator);
    for (final (index, group) in groups.indexed) {
      final entries = <(String, String)>[];
      for (final entry in group.split(config.episodeSeparator)) {
        final text = entry.trim();
        if (text.isEmpty) continue;
        // 集名可以缺省（只有地址），这时按序号起名；Kazumi 原版会跳过这种条目。
        final at = text.indexOf(config.fieldSeparator);
        entries.add(at < 0 ? ('', text) : (text.substring(0, at).trim(), text.substring(at + config.fieldSeparator.length).trim()));
      }
      add(index < names.length ? names[index].trim() : '', entries);
    }
    return roads;
  }
  final roadNodes = config.roadsPath.isEmpty ? [document] : readCinemaPath(document, config.roadsPath);
  for (final node in roadNodes) {
    add(_first(node, config.roadNamePath), [
      for (final episode in readCinemaPath(node, config.episodesPath)) (_first(episode, config.episodeNamePath), _first(episode, config.episodeUrlPath)),
    ]);
  }
  return roads;
}

// 云解析的回复：codePath 按字符串比 okCode，地址按 cipher 解密在 cinema_cloud_parse.dart，这里只取原值。
({String code, String title, String url, String type}) parseCinemaParserReply(String raw, CinemaParser parser) {
  final document = decodeCinemaJson(raw);
  return (code: _first(document, parser.codePath), title: _first(document, parser.titlePath), url: _first(document, parser.urlPath), type: _first(document, parser.typePath));
}
