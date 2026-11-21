import 'dart:math';

import 'package:flutter/foundation.dart';

// 电影院的数据：一个源搜到的一条（CinemaHit）、按片名加年份聚合后的一部片（CinemaTitle）、选集（CinemaRoad、CinemaEpisode）与看过的记录（CinemaHistory）。

class CinemaHit {
  const CinemaHit({required this.ruleId, required this.source, required this.name, this.cover = '', this.year = '', this.remarks = '', this.roads});
  final String ruleId;
  // 这个源里认这部片的值（苹果 CMS 是影片编号），选集请求的 @source。
  final String source;
  final String name;
  final String cover;
  // 只留四位数字，其余当没有。
  final String year;
  final String remarks;
  // 搜索回复自带的剧集（规则写了 search.chapters 才有）。
  final List<CinemaRoad>? roads;
}

class CinemaSourceRef {
  const CinemaSourceRef({required this.ruleId, required this.source, required this.name, required this.remarks, this.carried});
  final String ruleId;
  final String source;
  // 这个源里的原名与备注（各源的写法略有不同，选源时看得出版本）。
  final String name;
  final String remarks;
  // 搜索回复自带的剧集与取到的时刻：跟着这一次的搜索结果走，换一次搜索就随旧结果释放，不进选集缓存
  // （11-21 Codex 指出：一次搜索 14 个源各 20 条都写进 64 条的缓存，先回来的被自己挤掉，点开又请求一次）。过了 chaptersLifetime 不用。
  final (DateTime, List<CinemaRoad>)? carried;

  bool same(CinemaSourceRef other) => other.ruleId == ruleId && other.source == source;
}

// 同一部片在各源里编号不同、名字略有出入，按 cinemaTitleKey 聚合成一条（同交接里懒猫站点的 mediaKey）。
// 片源会在页面打开以后继续增加（边搜边回来的源、播放页「找其他片源」补到的），经 addSource 加并通知，已打开的选集页与播放页把新源接在菜单末尾。
class CinemaTitle with ChangeNotifier {
  CinemaTitle({required this.key, required this.name, required this.year, required String cover, required this.remarks}) {
    addCover(cover);
  }
  final String key;
  final String name;
  final String year;
  final String remarks;
  final _sources = <CinemaSourceRef>[];
  // 各源给的海报，按源的先后：一家的图床连不上时换下一家的（11-19 模拟器上实测有一家图床整片超时）。
  final covers = <String>[];

  List<CinemaSourceRef> get sources => List.unmodifiable(_sources);

  String get cover => covers.firstOrNull ?? '';

  void addCover(String url) {
    if (url.isNotEmpty && !covers.contains(url)) covers.add(url);
  }

  // 同一个源的同一部只留一条，加上了为真。
  bool addSource(CinemaSourceRef ref) {
    if (_sources.any(ref.same)) return false;
    _sources.add(ref);
    notifyListeners();
    return true;
  }
}

// 新来的片源接在已排好的后面（已显示的顺序与选中的不动；新源即使记录更好也不往前插，选源由用户）。
List<CinemaSourceRef> appendCinemaSources(List<CinemaSourceRef> shown, List<CinemaSourceRef> all) => [...shown, for (final ref in all) if (!shown.any(ref.same)) ref];

class CinemaEpisode {
  const CinemaEpisode({required this.name, required this.url});
  final String name;
  final String url;
}

class CinemaRoad {
  const CinemaRoad({required this.name, required this.episodes});
  final String name;
  final List<CinemaEpisode> episodes;
}

// 一个片源在这台手机上最近的播放结果（本机 cinema.db 的 source_stat）：最近一次播成、没播成的时刻（UTC）与播成那次的首帧用时。
class CinemaSourceStat {
  const CinemaSourceStat({this.okAt, this.failAt, this.firstFrame});
  final DateTime? okAt;
  final DateTime? failAt;
  final Duration? firstFrame;

  // 最近一次是播成了（true）还是没播成（false）。
  bool get lastOk => failAt == null || (okAt != null && okAt!.isAfter(failAt!));
}

// 片源名后面的标注：没有记录不标。
String? cinemaSourceStatLabel(CinemaSourceStat? stat) => switch (stat?.lastOk) {
  true => '上次能播',
  false => '上次没播成',
  null => null,
};

// 选集页的片源顺序：最近一次播成的在前（首帧快的在前），没记录的按搜到的先后，最近一次没播成的放最后；同一组里照搜到的先后。
List<CinemaSourceRef> rankCinemaSources(List<CinemaSourceRef> sources, Map<String, CinemaSourceStat> stats) {
  int group(CinemaSourceRef ref) => switch (stats[ref.ruleId]?.lastOk) {
    true => 0,
    null => 1,
    false => 2,
  };
  int frame(CinemaSourceRef ref) => stats[ref.ruleId]?.firstFrame?.inMilliseconds ?? 1 << 30;
  final ordered = [...sources.indexed]
    ..sort((a, b) {
      final byGroup = group(a.$2).compareTo(group(b.$2));
      if (byGroup != 0) return byGroup;
      final byFrame = group(a.$2) == 0 ? frame(a.$2).compareTo(frame(b.$2)) : 0;
      return byFrame != 0 ? byFrame : a.$1.compareTo(b.$1);
    });
  return [for (final (_, ref) in ordered) ref];
}

// 一个源搜失败了：哪个源、给用户看的原因。
class CinemaFailure {
  const CinemaFailure({required this.ruleId, required this.name, required this.message, this.paused = false});
  final String ruleId;
  // 片源名（页面只写这个）；message 是原因，只进日志。
  final String name;
  final String message;
  // 连续失败暂停着、这次没去搜（CinemaService.pauseAfter）。
  final bool paused;
}

// 边搜边给的一份快照：哪个源先回来先合进去，pending 是还没回来的源数，0 就是搜完了。
class CinemaSearchResult {
  const CinemaSearchResult({required this.titles, required this.failures, this.pending = 0});
  final List<CinemaTitle> titles;
  final List<CinemaFailure> failures;
  final int pending;
}

// 看过的一部片（本机 cinema.db，最多 cinemaHistoryLimit 条）：接着看用哪个源、哪条线路、第几集、看到哪。
class CinemaHistory {
  const CinemaHistory({
    required this.key,
    required this.name,
    required this.cover,
    required this.ruleId,
    required this.source,
    required this.road,
    required this.episode,
    required this.episodeName,
    required this.position,
    required this.duration,
    required this.updatedAt,
  });
  final String key;
  final String name;
  final String cover;
  final String ruleId;
  final String source;
  final int road;
  final int episode;
  final String episodeName;
  final Duration position;
  final Duration duration;
  // UTC。
  final DateTime updatedAt;

  // [人工决策-2026-11-21 11:59:29] 看完了（用户选，同 Netflix、B 站）：剩下的不到片长的 cinemaFinishedShare 或 cinemaFinishedTail，两者取更短的
  // （短片不至于看一半就算看完）。再打开时电影从头播、剧集接下一集（最后一集从头播），不再停在片尾；海报条上的进度照旧按看到哪画。
  bool get finished => duration > Duration.zero && duration - position <= Duration(microseconds: min((duration.inMicroseconds * cinemaFinishedShare).round(), cinemaFinishedTail.inMicroseconds));
}

const cinemaFinishedShare = 0.05;
const cinemaFinishedTail = Duration(minutes: 3);

// 集号：「第01集」「第1集」「01」「EP1」「1」「第1话」都是 1；带别的字（特别篇、预告、花絮、上下集、HD中字、正片）的没有集号，只按原名配。
int? cinemaEpisodeNumber(String name) {
  final match = RegExp(r'^(?:第?0*(\d{1,4})(?:集|话|話|期)?|e(?:p)?0*(\d{1,4}))$').firstMatch(cinemaFold(name));
  return match == null ? null : int.parse(match.group(1) ?? match.group(2)!);
}

// 换源时在新源的一条线路里找同一集（11-21 Codex 指出原来集名要一字不差）：先比原名，再比集号，都没有时两边都只有一集（电影的「正片」与「HD中字」）
// 算同一集；name 为空（原来的源一直没取到选集）时按第 index 集。找不到为 -1。不同源可能是不同剪辑，配上同一集不代表时间轴一致。
int cinemaMatchEpisode(List<CinemaEpisode> episodes, String? name, {required int index, required bool single}) {
  if (name == null) return index < episodes.length ? index : -1;
  final exact = episodes.indexWhere((episode) => episode.name == name);
  if (exact >= 0) return exact;
  final number = cinemaEpisodeNumber(name);
  final numbered = number == null ? -1 : episodes.indexWhere((episode) => cinemaEpisodeNumber(episode.name) == number);
  if (numbered >= 0) return numbered;
  return single && episodes.length == 1 ? 0 : -1;
}

// 聚合键：片名去掉空白、全角折成半角、转小写，加「|」加四位年份（没有年份为空）。交接原版用 NFKC，Dart 没有现成的规范化，
// 这里只折全角 ASCII 与全角空格（交接的测试向量都在这个范围），其余写法不同的当成两部片，不会误合并。
String cinemaTitleKey(String name, String year) => '${cinemaFold(name)}|${cinemaYear(year)}';

// 片名的折叠写法：去空白、全角折半角、小写。聚合键用，中转的片名目录按同样的写法折叠（服务端 cinema_catalog_source.ts 的 cinemaFold）。
String cinemaFold(String name) {
  final buffer = StringBuffer();
  for (final rune in name.runes) {
    final folded = rune == 0x3000 ? 0x20 : (rune >= 0xFF01 && rune <= 0xFF5E ? rune - 0xFEE0 : rune);
    final char = String.fromCharCode(folded);
    if (char.trim().isNotEmpty) buffer.write(char.toLowerCase());
  }
  return buffer.toString();
}

String cinemaYear(String raw) => RegExp(r'^\d{4}$').hasMatch(raw.trim()) ? raw.trim() : '';

// 能直接交给播放器的媒体地址：http(s)、不带用户名密码、路径以 .m3u8、.mp4、.flv、.mkv 结尾。分享页、播放页这类网页地址第一版播不了（要网页嗅探，下一轮做），选集时去掉。
bool cinemaMediaUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty || uri.userInfo.isNotEmpty) return false;
  final path = uri.path.toLowerCase();
  return path.endsWith('.m3u8') || path.endsWith('.mp4') || path.endsWith('.flv') || path.endsWith('.mkv');
}

bool cinemaPlaylistUrl(String value) => Uri.tryParse(value)?.path.toLowerCase().endsWith('.m3u8') ?? false;
