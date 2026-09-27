import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:synchronized/synchronized.dart';

class DisplaySettings extends ChangeNotifier {
  DisplaySettings.memory() : _database = null;
  DisplaySettings._(this._database, this._scale, this._paletteId, this._fontId);
  final Database? _database;
  final Lock _saveLock = Lock();
  double _scale = 1;
  String _paletteId = 'sage';
  String _fontId = 'maple';
  double get scale => _scale;
  String get paletteId => _paletteId;
  String get fontId => _fontId;
  String get fontFamily => fontFamilies[_fontId]!;
  static const scales = [1.0, 1.1, 1.25, 1.4];
  static const labels = ['标准', '较大', '大', '特大'];
  static const paletteIds = ['sage', 'mist', 'rose', 'dusk', 'oat'];
  static const fontFamilies = {
    'maple': 'Maple Mono NF CN',
    'serif': 'Noto Serif SC',
  };

  static Future<DisplaySettings> open({String? databasePath}) async {
    final db = await openDatabase(
      databasePath ??
          path.join(await getDatabasesPath(), 'display_settings.db'),
      version: 2,
      onCreate: (db, _) async {
        await db.execute(
          "CREATE TABLE display_settings (id INTEGER PRIMARY KEY CHECK(id=1), text_scale REAL NOT NULL, palette_id TEXT NOT NULL DEFAULT 'sage', font_id TEXT NOT NULL DEFAULT 'maple')",
        );
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE display_settings ADD COLUMN palette_id TEXT NOT NULL DEFAULT 'sage'",
          );
          await db.execute(
            "ALTER TABLE display_settings ADD COLUMN font_id TEXT NOT NULL DEFAULT 'maple'",
          );
        }
      },
    );
    final rows = await db.query('display_settings', where: 'id = 1', limit: 1);
    final row = rows.firstOrNull;
    final scale = row?['text_scale'];
    final palette = row?['palette_id'];
    final font = row?['font_id'];
    return DisplaySettings._(
      db,
      scale is num && scales.contains(scale.toDouble()) ? scale.toDouble() : 1,
      palette is String && paletteIds.contains(palette) ? palette : 'sage',
      font is String && fontFamilies.containsKey(font) ? font : 'maple',
    );
  }

  Future<void> setScale(double value) {
    if (!scales.contains(value)) throw ArgumentError.value(value, 'scale');
    return _save(scale: value);
  }

  Future<void> setPalette(String value) {
    if (!paletteIds.contains(value)) {
      throw ArgumentError.value(value, 'palette');
    }
    return _save(paletteId: value);
  }

  Future<void> setFont(String value) {
    if (!fontFamilies.containsKey(value)) {
      throw ArgumentError.value(value, 'font');
    }
    return _save(fontId: value);
  }

  // [人工决策-2026-09-25 17:43:48] 配色/字体/字号属于设备，切账号保留；锁内合并完整快照，防快速切换覆盖其他设置。
  Future<void> _save({double? scale, String? paletteId, String? fontId}) =>
      _saveLock.synchronized(() async {
        final nextScale = scale ?? _scale,
            nextPalette = paletteId ?? _paletteId,
            nextFont = fontId ?? _fontId;
        if (nextScale == _scale &&
            nextPalette == _paletteId &&
            nextFont == _fontId) {
          return;
        }
        await _database?.insert('display_settings', {
          'id': 1,
          'text_scale': nextScale,
          'palette_id': nextPalette,
          'font_id': nextFont,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        _scale = nextScale;
        _paletteId = nextPalette;
        _fontId = nextFont;
        notifyListeners();
      });
  Future<void> close() async {
    await _database?.close();
    dispose();
  }
}

class DisplayScope extends InheritedNotifier<DisplaySettings> {
  const DisplayScope({
    super.key,
    required DisplaySettings settings,
    required super.child,
  }) : super(notifier: settings);
  static DisplaySettings of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DisplayScope>()!.notifier!;
}

class CampusTextScaler extends TextScaler {
  const CampusTextScaler(this.system, this.multiplier);
  final TextScaler system;
  final double multiplier;
  @override
  double scale(double fontSize) => system.scale(fontSize) * multiplier;
  @override
  double get textScaleFactor => system.scale(14) / 14 * multiplier;
}
