import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/local/wallpaper_store.dart';

// wallpaperDirectory 为 null 时不支持自定义壁纸（测试与内存实例）。
class DisplaySettings extends ChangeNotifier {
  DisplaySettings.memory({Directory? wallpaperDirectory})
    : _database = null,
      _wallpaper = wallpaperDirectory == null ? null : WallpaperStore(wallpaperDirectory);
  DisplaySettings._(
    this._database,
    this._wallpaper,
    this._textSize,
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
  double _textSize = 0;
  String _paletteId = defaultPaletteId;
  String _fontId = defaultFontId;
  ThemeMode _themeMode = ThemeMode.system;
  String _glassMode = 'auto';
  String? _wallpaperFile;
  String? _wallpaperTone;
  int _wallpaperBlur = defaultWallpaperBlur;
  int _wallpaperFade = 0;
  // 壁纸模糊与淡化的当前外观。拖动滑杆时 previewWallpaper 只改它、不落库，背景单独监听它实时重画，
  // 不重建整个应用；落库后同步为已保存的值。
  late final wallpaperLook = ValueNotifier<({int blur, int fade})>((blur: _wallpaperBlur, fade: _wallpaperFade));
  ThemeMode get themeMode => _themeMode;
  // 字号：为空是跟随系统，否则是字号条上选的实际显示大小（标准字号的倍数，同一个数在每台手机上一样大），人工决策见 textSizeMin。
  double? get textSize => _textSize == 0 ? null : _textSize;
  String get paletteId => _paletteId;
  String get fontId => _fontId;
  // 为空是系统字体（交给平台默认：iOS 西文 SF、中文苹方）。
  String? get fontFamily => _fontId == systemFont ? null : fontFamilies[_fontId]!;
  String get glassMode => _glassMode;
  bool get supportsWallpaper => _wallpaper != null;
  File? get wallpaperFile => _wallpaperFile == null ? null : _wallpaper?.file(_wallpaperFile!);
  // 色调网格由 theme/wallpaper_tone.dart 编码，这里只原样保存。
  String? get wallpaperTone => _wallpaperTone;
  int get wallpaperBlur => _wallpaperBlur;
  int get wallpaperFade => _wallpaperFade;
  // [人工决策-2026-10-27 21:20:28] 字号改成字号条（用户要求）：条上的数是实际显示大小（100% 是标准），同一个数在每台手机上一样大，
  // 默认跟随系统、拖动后改用自己选的大小（用户选定，同 iOS「仅限此应用」的文字大小；没选「仍是系统字号上的倍数」「固定大小、完全不看系统」）；
  // 最小 100%，跟随系统时系统字号比标准还小也按 100%（用户选定，同项目「文字最小 14px」）；每 5% 一档，最大 200%。
  // 老设置在 v8 换算成看起来不变的值：原来的「标准」跟随系统，较大及以上换成当时的实际大小（系统字号 × 原倍数）。
  // [人工决策-2026-10-28 00:18:15] 最小改为 80%（用户要求，取代上一条的「最小 100%」）：可以拖到比标准小，跟随系统时系统字号比 80% 还小也按 80%；
  // 「文字最小 14px」指标准字号下的设计尺寸，用户自己调小时按比例缩小。推荐范围仍从标准 100% 标起（见 page/text_size_range.dart）。
  static const textSizeMin = .8;
  static const textSizeMax = 2.0;
  static const textSizeStep = .05;
  static double effectiveTextSize(double? chosen, double system) => chosen ?? math.max(textSizeMin, system);
  static double snapTextSize(double value) => (value.clamp(textSizeMin, textSizeMax) / textSizeStep).round() * 5 / 100;
  static bool knownTextSize(double value) => value == 0 || value >= textSizeMin && value <= textSizeMax;
  // [人工决策-2026-10-27 20:11:01] 删掉苔灰配色（用户要求），剩雾蓝、藕粉、暮紫、燕麦四套；存着苔灰的在 v7 升级时换成默认的雾蓝，
  // 好友分享的界面配置里是苔灰时按不支持的配色跳过。
  static const paletteIds = ['mist', 'rose', 'dusk', 'oat'];
  // [人工决策-2026-10-22 21:44:49] 默认配色由苔灰改为雾蓝（用户要求）：只改默认值、不动已存的设置——新装与从没存过显示设置的升级后是雾蓝，
  // 存过任何一项显示设置的（整份快照连当时的苔灰一起存了）保持原样（用户选定，未选「只给新装」「苔灰的全换成雾蓝」）。苔灰本身已在 10-27 删掉（见上一条）。
  // 启动窗口底色（android res 的 launch_background）跟着默认配色走。
  static const defaultPaletteId = 'mist';
  static const glassModes = ['auto', 'full', 'reduced'];
  // 壁纸模糊与淡化为 0–100 的连续量（v6 起；此前是三档下标，升级时按原效果换算）；默认轻度模糊、不额外淡化。
  static const wallpaperMax = 100;
  static const defaultWallpaperBlur = 27;
  static const wallpaperMaxBytes = WallpaperStore.maxBytes;
  static const fontFamilies = {
    'maple': 'Maple Mono NF CN',
    'serif': 'Noto Serif SC',
  };
  // [人工决策-2026-10-26 21:40:32] iOS 可用系统字体（西文 SF、中文苹方），字体列表多一项「系统字体」；安卓没有这一项。
  // [人工决策-2026-10-27 20:11:01] iOS 默认字体改回 Maple（用户要求，取代上一条的「iOS 新装默认系统字体」），系统字体仍可选；
  // iOS 上存着系统字体的在 v7 升级时一次性换成 Maple（用户选定：iOS 测试包 10-26 才有，存着的系统字体基本是默认值、分不清谁主动选的；未选「只改默认值」），
  // 之后再选系统字体的不再改动。
  static const systemFont = 'system';
  static bool get supportsSystemFont => defaultTargetPlatform == TargetPlatform.iOS;
  static const defaultFontId = 'maple';
  static bool knownFont(String id) => fontFamilies.containsKey(id) || id == systemFont && supportsSystemFont;

  // systemTextScale 是这时的系统字号，只在 v8 换算老字号时用；默认读窗口的。
  static Future<DisplaySettings> open({String? databasePath, Directory? wallpaperDirectory, double? systemTextScale}) async {
    final system = systemTextScale ?? ui.PlatformDispatcher.instance.textScaleFactor;
    final db = await openDatabase(
      databasePath ??
          path.join(await getDatabasesPath(), 'display_settings.db'),
      version: 8,
      onCreate: (db, _) async {
        await db.execute(
          "CREATE TABLE display_settings (id INTEGER PRIMARY KEY CHECK(id=1), text_scale REAL NOT NULL, palette_id TEXT NOT NULL DEFAULT '$defaultPaletteId', font_id TEXT NOT NULL DEFAULT 'maple', theme_mode TEXT NOT NULL DEFAULT 'system', glass_mode TEXT NOT NULL DEFAULT 'auto', wallpaper_file TEXT, wallpaper_tone TEXT, wallpaper_blur INTEGER NOT NULL DEFAULT $defaultWallpaperBlur, wallpaper_fade INTEGER NOT NULL DEFAULT 0)",
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
        if (oldVersion < 6) {
          // 三档下标换成连续量，观感基本不变：模糊 sigma 0/8/20、淡化“下限之上再加 .2/.4”按常见下限约 .4 换算的百分比。
          await db.execute(
            'UPDATE display_settings SET wallpaper_blur = CASE wallpaper_blur WHEN 0 THEN 0 WHEN 2 THEN 67 ELSE $defaultWallpaperBlur END, '
            'wallpaper_fade = CASE wallpaper_fade WHEN 1 THEN 33 WHEN 2 THEN 67 ELSE 0 END',
          );
        }
        if (oldVersion < 7) {
          // 苔灰删掉后换成默认的雾蓝；iOS 上存着的系统字体一次性换成 Maple（安卓存不进系统字体，这句不影响安卓），人工决策见常量处。
          await db.execute("UPDATE display_settings SET palette_id = '$defaultPaletteId' WHERE palette_id = 'sage'");
          await db.execute("UPDATE display_settings SET font_id = 'maple' WHERE font_id = '$systemFont'");
        }
        if (oldVersion < 8) {
          // 字号从「系统字号上的倍数」改成实际显示大小（0 是跟随系统），看起来不变：原来的标准跟随系统，较大及以上换成系统字号 × 原倍数（人工决策见 textSizeMin）。
          await db.execute('UPDATE display_settings SET text_scale = CASE WHEN text_scale <= 1 THEN 0 ELSE MIN($textSizeMax, MAX($textSizeMin, ROUND(text_scale * $system * 20) / 20.0)) END');
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
      scale is num && knownTextSize(scale.toDouble()) ? (scale == 0 ? 0.0 : snapTextSize(scale.toDouble())) : 0.0,
      palette is String && paletteIds.contains(palette) ? palette : defaultPaletteId,
      font is String && knownFont(font) ? font : defaultFontId,
      ThemeMode.values.where((value) => value.name == mode).firstOrNull ??
          ThemeMode.system,
      glass is String && glassModes.contains(glass) ? glass : 'auto',
      hasWallpaper ? file : null,
      hasWallpaper ? tone : null,
      blur is int && blur >= 0 && blur <= wallpaperMax ? blur : defaultWallpaperBlur,
      fade is int && fade >= 0 && fade <= wallpaperMax ? fade : 0,
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

  // 为空回到跟随系统；否则按 5% 一档取整，夹在 100%–200%。
  Future<void> setTextSize(double? value) {
    if (value != null && !value.isFinite) throw ArgumentError.value(value, 'textSize');
    return _save(textSize: value == null ? 0 : snapTextSize(value));
  }

  Future<void> setPalette(String value) {
    if (!paletteIds.contains(value)) {
      throw ArgumentError.value(value, 'palette');
    }
    return _save(paletteId: value);
  }

  Future<void> setFont(String value) {
    if (!knownFont(value)) {
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

  // 拖动中的实时预览：只改 wallpaperLook，不落库、不通知整个应用；停手后用 setWallpaperLook 保存。
  void previewWallpaper({int? blur, int? fade}) {
    final next = (blur: blur ?? wallpaperLook.value.blur, fade: fade ?? wallpaperLook.value.fade);
    _checkLook(next);
    wallpaperLook.value = next;
  }

  // 保存壁纸模糊与淡化（0–100）。外观立即更新，落库在保存锁内排队完成；落库后不回写外观，
  // 否则保存期间继续拖动的预览会被拽回刚保存的旧值。
  Future<void> setWallpaperLook({required int blur, required int fade}) {
    final look = (blur: blur, fade: fade);
    _checkLook(look);
    wallpaperLook.value = look;
    return _save(wallpaperBlur: blur, wallpaperFade: fade);
  }

  void _checkLook(({int blur, int fade}) look) {
    if (look.blur < 0 || look.blur > wallpaperMax || look.fade < 0 || look.fade > wallpaperMax) throw ArgumentError.value(look, 'look');
  }

  // 当前界面配置，用于分享给好友与套用前的撤销点；壁纸图片属于本机，不在其中。
  AppearanceShare get appearance => AppearanceShare(
    paletteId: _paletteId,
    fontId: _fontId,
    scale: _textSize,
    themeMode: _themeMode.name,
    glassMode: _glassMode,
    wallpaperBlur: _wallpaperBlur,
    wallpaperFade: _wallpaperFade,
  );

  // 套用好友分享的界面配置：本版本支持的取值一并在保存锁内落库，不支持的保持不变；返回被跳过的项名。
  Future<List<String>> applyAppearance(AppearanceShare shared) async {
    final skipped = <String>[];
    T? pick<T>(bool supported, T value, String name) {
      if (supported) return value;
      skipped.add(name);
      return null;
    }

    final mode = ThemeMode.values.where((value) => value.name == shared.themeMode).firstOrNull;
    await _save(
      paletteId: pick(paletteIds.contains(shared.paletteId), shared.paletteId, '配色'),
      fontId: pick(knownFont(shared.fontId), shared.fontId, '字体'),
      textSize: pick(knownTextSize(shared.scale), shared.scale == 0 ? 0.0 : snapTextSize(shared.scale), '字号'),
      themeMode: pick<ThemeMode?>(mode != null, mode, '深浅色'),
      glassMode: pick(glassModes.contains(shared.glassMode), shared.glassMode, '玻璃效果'),
      wallpaperBlur: shared.wallpaperBlur,
      wallpaperFade: shared.wallpaperFade,
    );
    wallpaperLook.value = (blur: _wallpaperBlur, fade: _wallpaperFade);
    return skipped;
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
    double? textSize,
    String? paletteId,
    String? fontId,
    ThemeMode? themeMode,
    String? glassMode,
    int? wallpaperBlur,
    int? wallpaperFade,
  }) => _saveLock.synchronized(() => _write(
    textSize: textSize,
    paletteId: paletteId,
    fontId: fontId,
    themeMode: themeMode,
    glassMode: glassMode,
    wallpaperBlur: wallpaperBlur,
    wallpaperFade: wallpaperFade,
  ));

  // 合并完整快照并落库，调用方须已持有 _saveLock；壁纸也属于设备，同一份快照里保存。
  Future<void> _write({
    double? textSize,
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
    final nextTextSize = textSize ?? _textSize,
        nextPalette = paletteId ?? _paletteId,
        nextFont = fontId ?? _fontId,
        nextMode = themeMode ?? _themeMode,
        nextGlass = glassMode ?? _glassMode,
        nextFile = clearWallpaper ? null : wallpaperFile ?? _wallpaperFile,
        nextTone = clearWallpaper ? null : wallpaperTone ?? _wallpaperTone,
        nextBlur = wallpaperBlur ?? _wallpaperBlur,
        nextFade = wallpaperFade ?? _wallpaperFade;
    if (nextTextSize == _textSize &&
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
      'text_scale': nextTextSize,
      'palette_id': nextPalette,
      'font_id': nextFont,
      'theme_mode': nextMode.name,
      'glass_mode': nextGlass,
      'wallpaper_file': nextFile,
      'wallpaper_tone': nextTone,
      'wallpaper_blur': nextBlur,
      'wallpaper_fade': nextFade,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _textSize = nextTextSize;
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

  @override
  void dispose() {
    wallpaperLook.dispose();
    super.dispose();
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

// [人工决策-2026-10-23 16:48:13] 改应用字号时连续过渡（用户反馈从大字号切到小字号整页跳动、按钮变形，要「流畅优雅的自然变形」）：
// 以前新字号在一帧里整体生效，内容一下变矮、滚动位置被截断，按钮里的文字瞬间变小而勾号让位动画还按旧尺寸在播。
// 现在把字号在 duration 内平滑插值，全应用的文字、按钮、卡片跟着一起连续缩放（同 iOS 改文字大小时界面连续变化）；
// 界面页另用 theme 的 CampusAnchoredScrollController 让点的那一项停在手指下。减少动画时直接换。
// 字号条上选的大小（为空跟随系统，最小 80%）按线性缩放交给全应用，人工决策见 DisplaySettings.textSizeMin。
class CampusTextScale extends StatelessWidget {
  const CampusTextScale({super.key, required this.textSize, required this.child});
  final double? textSize;
  final Widget child;
  static const duration = Duration(milliseconds: 280);

  // 系统字号（标准字号的倍数）：这下面的 MediaQuery 已换成字号条的大小，界面页要系统本来的从这里取。
  static double systemOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_SystemTextScale>()?.value ?? MediaQuery.textScalerOf(context).scale(14) / 14;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final system = media.textScaler.scale(14) / 14;
    return _SystemTextScale(
      value: system,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: DisplaySettings.effectiveTextSize(textSize, system)),
        duration: media.disableAnimations ? Duration.zero : duration,
        curve: Curves.easeInOutCubic,
        builder: (context, value, child) => MediaQuery(data: media.copyWith(textScaler: TextScaler.linear(value)), child: child!),
        child: child,
      ),
    );
  }
}

class _SystemTextScale extends InheritedWidget {
  const _SystemTextScale({required this.value, required super.child});
  final double value;
  @override
  bool updateShouldNotify(_SystemTextScale oldWidget) => oldWidget.value != value;
}
