// 电影院的数据：一个源搜到的一条（CinemaHit）、按片名加年份聚合后的一部片（CinemaTitle）、选集（CinemaRoad、CinemaEpisode）与看过的记录（CinemaHistory）。

class CinemaHit {
  const CinemaHit({required this.ruleId, required this.source, required this.name, this.cover = '', this.year = '', this.remarks = ''});
  final String ruleId;
  // 这个源里认这部片的值（苹果 CMS 是影片编号），选集请求的 @source。
  final String source;
  final String name;
  final String cover;
  // 只留四位数字，其余当没有。
  final String year;
  final String remarks;
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

// 一个源搜失败了：哪个源、给用户看的原因。
class CinemaFailure {
  const CinemaFailure({required this.ruleId, required this.message});
  final String ruleId;
  final String message;
}

class CinemaSearchResult {
  const CinemaSearchResult({required this.titles, required this.failures});
  final List<CinemaTitle> titles;
  final List<CinemaFailure> failures;
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
String cinemaTitleKey(String name, String year) {
  final buffer = StringBuffer();
  for (final rune in name.runes) {
    final folded = rune == 0x3000 ? 0x20 : (rune >= 0xFF01 && rune <= 0xFF5E ? rune - 0xFEE0 : rune);
    final char = String.fromCharCode(folded);
    if (char.trim().isNotEmpty) buffer.write(char.toLowerCase());
  }
  return '$buffer|${cinemaYear(year)}';
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
