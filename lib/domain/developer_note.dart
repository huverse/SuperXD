// [人工决策-2026-10-23 23:25:34] 开发者的话（用户要求，内容全部由维护者亲手写，助手不代写）：维护者在仓库 notes 目录写信，合并到 main 后
// 由流水线传到自建中转，应用联网拉取，不用发版（用户选「仓库写、自动下发」，未选「不进仓库、命令上传」「随版本内置」）。
// 入口在「我的」页一行，有没读过的信时这一行与底栏「我的」各一个小圆点；新信在不迫切的时候弹出来（用户在推荐项上加的，规则见 application/app_moments.dart）。
// 只读：没有评论、点赞，不收集任何回应。
class DeveloperNote {
  const DeveloperNote({required this.id, required this.title, required this.publishedAt, required this.body});
  // notes 目录里的文件名（不含 .txt）：发出去之后不改，已读与弹过都按它记。
  final String id;
  final String title;
  // UTC 绝对时刻；维护者按校园时区写，tool/developer_notes.dart 换算。
  final DateTime publishedAt;
  final String body;
}

// 上限：工具按它出清单、中转按它校验、客户端按它解析（外部输入的边界）。只留最近的 developerNoteLimit 封，更早的不再下发。
const developerNoteLimit = 30;
const developerNoteTitleMax = 40;
const developerNoteBodyMax = 4000;
final developerNoteId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');

// 新信只在发出后这么久之内弹出：新装或很久没打开的人不会被一封旧信弹到，旧信只在入口处标没读。
const developerNoteLetterFresh = Duration(days: 14);

// 清单是外部输入：逐项校验，不合格抛 FormatException；按发出时刻从新到旧排。
List<DeveloperNote> decodeDeveloperNotes(Object? json) {
  if (json is! Map || json['notes'] is! List) throw const FormatException('不是开发者的话清单');
  final items = json['notes'] as List;
  if (items.length > developerNoteLimit) throw const FormatException('条数超过上限');
  final notes = [
    for (final item in items)
      switch (item) {
        {'id': final String id, 'title': final String title, 'publishedAt': final String publishedAt, 'body': final String body}
            when developerNoteId.hasMatch(id) && title.trim().isNotEmpty && title.length <= developerNoteTitleMax && body.trim().isNotEmpty && body.length <= developerNoteBodyMax && DateTime.tryParse(publishedAt) != null =>
          DeveloperNote(id: id, title: title, publishedAt: DateTime.parse(publishedAt).toUtc(), body: body),
        _ => throw const FormatException('有一封信格式不对'),
      },
  ];
  if (notes.map((note) => note.id).toSet().length != notes.length) throw const FormatException('编号重复');
  return notes..sort(compareDeveloperNotes);
}

Map<String, Object?> encodeDeveloperNotes(List<DeveloperNote> notes) => {
  'notes': [for (final note in notes) {'id': note.id, 'title': note.title, 'publishedAt': note.publishedAt.toUtc().toIso8601String(), 'body': note.body}],
};

// 从新到旧；同一时刻按编号，顺序稳定。
int compareDeveloperNotes(DeveloperNote a, DeveloperNote b) {
  final time = b.publishedAt.compareTo(a.publishedAt);
  return time != 0 ? time : a.id.compareTo(b.id);
}

// 该弹的那封：最新一封没弹过、且还新鲜（发出不满 developerNoteLetterFresh）。弹过一次就把当时所有的信都记成弹过，其余没读的只在入口标出。
DeveloperNote? developerNoteLetter(List<DeveloperNote> notes, Set<String> shown, DateTime now) => switch (notes.firstOrNull) {
  final latest? when !shown.contains(latest.id) && now.difference(latest.publishedAt) < developerNoteLetterFresh => latest,
  _ => null,
};

class DeveloperNoteException implements Exception {
  const DeveloperNoteException(this.message);
  final String message;
  @override
  String toString() => message;
}

// 拉取最新的信（device 实现：自建中转）。连不上、限流或格式不对抛 DeveloperNoteException。
abstract class DeveloperNoteFeed {
  Future<List<DeveloperNote>> fetch();
}

// 本机记录（local 实现）：上次拉到的信（离线时照样能看）、读过与弹过的编号、上次拉取成功的时刻。
class DeveloperNoteRecord {
  const DeveloperNoteRecord({this.notes = const [], this.read = const {}, this.shown = const {}, this.fetchedAt});
  final List<DeveloperNote> notes;
  final Set<String> read;
  final Set<String> shown;
  final DateTime? fetchedAt;
}

abstract class DeveloperNoteMemory {
  DeveloperNoteRecord get record;
  // 整份替换；读过、弹过的编号只留还在清单里的，记录大小随清单封顶。
  Future<void> save(DeveloperNoteRecord record);
}
