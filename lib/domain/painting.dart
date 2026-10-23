import 'dart:convert';

// 开屏与关于页「开屏画作」用的画作（人工决策见 page/painting_splash.dart）。画作不写死在代码里：清单 assets/paintings/paintings.json 逐幅列出，
// 加一幅只放图、加清单一行（颜色用 tool/painting_colors.dart 算），清单顺序即开屏的轮换顺序。
class Painting {
  const Painting({required this.id, required this.title, required this.note, required this.asset, required this.width, required this.height, required this.focus, required this.horizon, required this.sky});
  final String id;
  final String title;
  // 画作说明（「仿莫奈风格 · AI 生成」），开屏与画作页都写在标题旁。
  final String note;
  // 随安装包分发的图片路径（assets/paintings/<文件名>）。
  final String asset;
  final int width;
  final int height;
  // 画作比屏幕宽、要裁两边时保留哪一处：0 最左、1 最右。
  final double focus;
  // 画作顶边从左到右几段背后的天空色（ARGB），画作上方的天空按它横向铺开，与画作顶边逐段接上；工具按顶边平均色给建议，前景挡住天空的段在清单里手改。
  final List<int> horizon;
  // 屏幕顶端的天空色（ARGB），应用名写在它上面。
  final int sky;

  double get aspect => width / height;
}

class PaintingFormatException implements Exception {
  const PaintingFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

// 画作的来源：清单里的画作、这次冷启动开屏用的哪一幅，以及把原图存进本机公共目录（相册里可见）。
abstract class PaintingGallery {
  List<Painting> get paintings;
  Painting? get current;
  // 存好返回 true；同名的已经存过时直接算存好，不重复存。
  Future<bool> save(Painting painting);
}

final _color = RegExp(r'^#[0-9A-Fa-f]{6}$');
final _id = RegExp(r'^[a-z0-9_]{1,40}$');
final _file = RegExp(r'^[a-z0-9_]{1,60}\.(jpg|png|webp)$');

int _argb(Object? value) {
  if (value is! String || !_color.hasMatch(value)) throw const PaintingFormatException('颜色须为 #RRGGBB');
  return 0xFF000000 | int.parse(value.substring(1), radix: 16);
}

// 读清单：结构、长度、取值逐项校验，有一项不对整份报错（清单随安装包发布，测试守着它能读出来）。
List<Painting> decodePaintings(String source, {String directory = 'assets/paintings'}) {
  final root = jsonDecode(source);
  final entries = root is Map ? root['paintings'] : null;
  if (entries is! List || entries.length > 100) throw const PaintingFormatException('清单须有 paintings 列表，最多 100 幅');
  final ids = <String>{};
  return [
    for (final entry in entries)
      if (entry is Map)
        switch ((entry['id'], entry['file'], entry['title'], entry['note'], entry['width'], entry['height'], entry['focus'], entry['horizon'])) {
          (final String id, final String file, final String title, final String note, final int width, final int height, final num focus, final List<Object?> horizon)
              when _id.hasMatch(id) && ids.add(id) && _file.hasMatch(file) && title.trim().isNotEmpty && title.length <= 20 && note.length <= 40 &&
                  width > 0 && height > 0 && focus >= 0 && focus <= 1 && horizon.isNotEmpty && horizon.length <= 12 =>
            Painting(
              id: id,
              title: title.trim(),
              note: note.trim(),
              asset: '$directory/$file',
              width: width,
              height: height,
              focus: focus.toDouble(),
              horizon: [for (final color in horizon) _argb(color)],
              sky: _argb(entry['sky']),
            ),
          _ => throw PaintingFormatException('画作 ${entry['id']} 的字段不对'),
        }
      else
        throw const PaintingFormatException('每一幅须是一个对象'),
  ];
}
