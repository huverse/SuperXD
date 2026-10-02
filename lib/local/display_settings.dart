import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/local/wallpaper_store.dart';

// wallpaperDirectory 为 null 时不支持自定义壁纸（测试与内存实例）。
class DisplaySettings extends ChangeNotifier {
  DisplaySettings.memory({Directory? wallpaperDirectory})
    : _database = null,
      _wallpaper = wallpaperDirectory == null ? null : WallpaperStore(wallpaperDirectory);
  DisplaySettings._(
    this._database,
    this._wallpaper,
    this._scale,
    this._paletteId,
    this._fontId,
    this._themeMode,
    this._glassMode,
    this._wallpaperFile,
    this._wallpaperTone,
    this._wallpaperBlur,
    this._wallpaperFade,
  );
  final Database? _database;
  final WallpaperStore? _wallpaper;
  final Lock _saveLock = Lock();
  double _scale = 1;
  String _paletteId = 'sage';
  String _fontId = 'maple';
  ThemeMode _themeMode = ThemeMode.system;
  String _glassMode = 'auto';
  String? _wallpaperFile;
  String? _wallpaperTone;
  int _wallpaperBlur = 1;
  int _wallpaperFade = 0;
  ThemeMode get themeMode => _themeMode;
  double get scale => _scale;
  String get paletteId => _paletteId;
  String get fontId => _fontId;
  String get fontFamily => fontFamilies[_fontId]!;
  String get glassMode => _glassMode;
  bool get supportsWallpaper => _wallpaper != null;
  File? get wallpaperFile => _wallpaperFile == null ? null : _wallpaper?.file(_wallpaperFile!);
  // 色调网格由 theme/wallpaper_tone.dart 编码，这里只原样保存。
  String? get wallpaperTone => _wallpaperTone;
  int get wallpaperBlur => _wallpaperBlur;
  int get wallpaperFade => _wallpaperFade;
  static const scales = [1.0, 1.1, 1.25, 1.4];
  static const labels = ['标准', '较大', '大', '特大'];
  static const paletteIds = ['sage', 'mist', 'rose', 'dusk', 'oat'];
  static const glassModes = ['auto', 'full', 'reduced'];
  // 壁纸模糊与淡化各三档，存档位下标；默认轻度模糊、标准淡化。
  static const wallpaperLevels = 3;
  static const wallpaperMaxBytes = WallpaperStore.maxBytes;
  static const fontFamilies = {
    'maple': 'Maple Mono NF CN',
    'serif': 'Noto Serif SC',
  };

  static Future<DisplaySettings> open({String? databasePath, Directory? wallpaperDirectory}) async {
    final db = await openDatabase(
      databasePath ??
          path.join(await getDatabasesPath(), 'display_settings.db'),
      version: 5,
      onCreate: (db, _) async {
        await db.execute(
          "CREATE TABLE display_settings (id INTEGER PRIMARY KEY CHECK(id=1), text_scale REAL NOT NULL, palette_id TEXT NOT NULL DEFAULT 'sage', font_id TEXT NOT NULL DEFAULT 'maple', theme_mode TEXT NOT NULL DEFAULT 'system', glass_mode TEXT NOT NULL DEFAULT 'auto', wallpaper_file TEXT, wallpaper_tone TEXT, wallpaper_blur INTEGER NOT NULL DEFAULT 1, wallpaper_fade INTEGER NOT NULL DEFAULT 0)",
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
        if (oldVersion < 3) {
          await db.execute(
            "ALTER TABLE display_settings ADD COLUMN theme_mode TEXT NOT NULL DEFAULT 'system'",
          );
        }
        if (oldVersion < 4) {
          await db.execute(
            "ALTER TABLE display_settings ADD COLUMN glass_mode TEXT NOT NULL DEFAULT 'auto'",
          );
        }
        if (oldVersion < 5) {
          await db.execute('ALTER TABLE display_settings ADD COLUMN wallpaper_file TEXT');
          await db.execute('ALTER TABLE display_settings ADD COLUMN wallpaper_tone TEXT');
          await db.execute('ALTER TABLE display_settings ADD COLUMN wallpaper_blur INTEGER NOT NULL DEFAULT 1');
          await db.execute('ALTER TABLE display_settings ADD COLUMN wallpaper_fade INTEGER NOT NULL DEFAULT 0');
        }
      },
    );
    final rows = await db.query('display_settings', where: 'id = 1', limit: 1);
    final row = rows.firstOrNull;
    final scale = row?['text_scale'];
    final palette = row?['palette_id'];
    final font = row?['font_id'];
    final mode = row?['theme_mode'];
    final glass = row?['glass_mode'];
    final wallpaper = wallpaperDirectory == null ? null : WallpaperStore(wallpaperDirectory);
    final file = row?['wallpaper_file'], tone = row?['wallpaper_tone'];
    final blur = row?['wallpaper_blur'], fade = row?['wallpaper_fade'];
    // 文件被外部删除、或缺少色调网格时按未设置处理，落库并清掉残留文件。
    final hasWallpaper = wallpaper != null && file is String && tone is String && await wallpaper.file(file).exists();
    final settings = DisplaySettings._(
      db,
      wallpaper,
      scale is num && scales.contains(scale.toDouble()) ? scale.toDouble() : 1,
      palette is String && paletteIds.contains(palette) ? palette : 'sage',
      font is String && fontFamilies.containsKey(font) ? font : 'maple',
      ThemeMode.values.where((value) => value.name == mode).firstOrNull ??
          ThemeMode.system,
      glass is String && glassModes.contains(glass) ? glass : 'auto',
      hasWallpaper ? file : null,
      hasWallpaper ? tone : null,
      blur is int && blur >= 0 && blur < wallpaperLevels ? blur : 1,
      fade is int && fade >= 0 && fade < wallpaperLevels ? fade : 0,
    );
    if (file != null && !hasWallpaper) {
      await db.update('display_settings', {'wallpaper_file': null, 'wallpaper_tone': null}, where: 'id = 1');
    }
    // 启动时清理异常中断留下的旧文件；清理失败不影响启动。
    await wallpaper?.prune(settings._wallpaperFile).catchError((Object error, StackTrace stack) {
      campusLog('[DisplaySettings] action=prune_wallpaper errorType=${error.runtimeType}\n$stack');
    });
    return settings;
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

  // [人工决策-2026-09-27 18:22:49] 新旧安装默认跟随系统，可手动浅色/深色；模式属于设备，和配色字体字号锁内合并持久化，切账号保留。
  Future<void> setThemeMode(ThemeMode value) => _save(themeMode: value);

  Future<void> setGlassMode(String value) {
    if (!glassModes.contains(value)) throw ArgumentError.value(value, 'glass');
    return _save(glassMode: value);
  }

  Future<void> setWallpaperBlur(int level) {
    if (level < 0 || level >= wallpaperLevels) throw ArgumentError.value(level, 'blur');
    return _save(wallpaperBlur: level);
  }

  Future<void> setWallpaperFade(int level) {
    if (level < 0 || level >= wallpaperLevels) throw ArgumentError.value(level, 'fade');
    return _save(wallpaperFade: level);
  }

  // 复制图片、落库、删旧文件在同一把锁内完成，连续换图不会删掉刚导入的文件。
  Future<void> setWallpaper(String source, String tone) {
    final wallpaper = _wallpaper;
    if (wallpaper == null) throw StateError('不支持自定义壁纸');
    return _saveLock.synchronized(() async {
      final name = await wallpaper.import(source);
      await _write(wallpaperFile: name, wallpaperTone: tone);
      await wallpaper.prune(name);
    });
  }

  Future<void> clearWallpaper() => _saveLock.synchronized(() async {
    await _write(clearWallpaper: true);
    await _wallpaper?.prune(null);
  });

  // [人工决策-2026-09-25 17:43:48] 配色/字体/字号属于设备，切账号保留；锁内合并完整快照，防快速切换覆盖其他设置。
  Future<void> _save({
    double? scale,
    String? paletteId,
    String? fontId,
    ThemeMode? themeMode,
    String? glassMode,
    int? wallpaperBlur,
    int? wallpaperFade,
  }) => _saveLock.synchronized(() => _write(
    scale: scale,
    paletteId: paletteId,
    fontId: fontId,
    themeMode: themeMode,
    glassMode: glassMode,
    wallpaperBlur: wallpaperBlur,
    wallpaperFade: wallpaperFade,
  ));

  // 合并完整快照并落库，调用方须已持有 _saveLock；壁纸也属于设备，同一份快照里保存。
  Future<void> _write({
    double? scale,
    String? paletteId,
    String? fontId,
    ThemeMode? themeMode,
    String? glassMode,
    String? wallpaperFile,
    String? wallpaperTone,
    int? wallpaperBlur,
    int? wallpaperFade,
    bool clearWallpaper = false,
  }) async {
    final nextScale = scale ?? _scale,
        nextPalette = paletteId ?? _paletteId,
        nextFont = fontId ?? _fontId,
        nextMode = themeMode ?? _themeMode,
        nextGlass = glassMode ?? _glassMode,
        nextFile = clearWallpaper ? null : wallpaperFile ?? _wallpaperFile,
        nextTone = clearWallpaper ? null : wallpaperTone ?? _wallpaperTone,
        nextBlur = wallpaperBlur ?? _wallpaperBlur,
        nextFade = wallpaperFade ?? _wallpaperFade;
    if (nextScale == _scale &&
        nextPalette == _paletteId &&
        nextFont == _fontId &&
        nextMode == _themeMode &&
        nextGlass == _glassMode &&
        nextFile == _wallpaperFile &&
        nextTone == _wallpaperTone &&
        nextBlur == _wallpaperBlur &&
        nextFade == _wallpaperFade) {
      return;
    }
    await _database?.insert('display_settings', {
      'id': 1,
      'text_scale': nextScale,
      'palette_id': nextPalette,
      'font_id': nextFont,
      'theme_mode': nextMode.name,
      'glass_mode': nextGlass,
      'wallpaper_file': nextFile,
      'wallpaper_tone': nextTone,
      'wallpaper_blur': nextBlur,
      'wallpaper_fade': nextFade,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _scale = nextScale;
    _paletteId = nextPalette;
    _fontId = nextFont;
    _themeMode = nextMode;
    _glassMode = nextGlass;
    _wallpaperFile = nextFile;
    _wallpaperTone = nextTone;
    _wallpaperBlur = nextBlur;
    _wallpaperFade = nextFade;
    notifyListeners();
  }
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
