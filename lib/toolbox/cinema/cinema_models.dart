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
  const CinemaSourceRef({required this.ruleId, required this.source, required this.name, required this.remarks});
  final String ruleId;
  final String source;
  // 这个源里的原名与备注（各源的写法略有不同，选源时看得出版本）。
  final String name;
  final String remarks;
}

// 同一部片在各源里编号不同、名字略有出入，按 cinemaTitleKey 聚合成一条（同交接里懒猫站点的 mediaKey）。
class CinemaTitle {
  CinemaTitle({required this.key, required this.name, required this.year, required String cover, required this.remarks}) {
    addCover(cover);
  }
  final String key;
  final String name;
  final String year;
  final String remarks;
  final sources = <CinemaSourceRef>[];
  // 各源给的海报，按源的先后：一家的图床连不上时换下一家的（11-19 模拟器上实测有一家图床整片超时）。
  final covers = <String>[];

  String get cover => covers.firstOrNull ?? '';

  void addCover(String url) {
    if (url.isNotEmpty && !covers.contains(url)) covers.add(url);
  }
}

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
  const CinemaFailure({required this.ruleId, required this.message, this.paused = false});
  final String ruleId;
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
