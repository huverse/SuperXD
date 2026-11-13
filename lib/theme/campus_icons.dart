import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:morphnext/morphnext.dart';

import 'package:superxd/theme/campus_motion.dart';

abstract final class CampusIcons {
  static const today = LucideIcons.calendar;
  static const todaySelected = LucideIcons.calendarDays;
  static const services = LucideIcons.layoutGrid;
  static const servicesSelected = LucideIcons.layoutDashboard;
  static const messages = LucideIcons.messageSquare;
  static const messagesSelected = LucideIcons.messagesSquare;
  static const account = LucideIcons.userRound;
  static const mainAccount = LucideIcons.userRoundCheck;
  static const tag = LucideIcons.tag;
  static const tags = LucideIcons.tags;
  static const accountSelected = LucideIcons.contactRound;
  static const grades = LucideIcons.fileChartColumn;
  static const back = LucideIcons.arrowLeft;
  static const next = LucideIcons.chevronRight;
  static const previous = LucideIcons.chevronLeft;
  static const expand = LucideIcons.chevronDown;
  static const collapse = LucideIcons.chevronUp;
  static const arrowUp = LucideIcons.arrowUp;
  static const close = LucideIcons.x;
  static const eye = LucideIcons.eye;
  static const eyeClosed = LucideIcons.eyeClosed;
  static const search = LucideIcons.search;
  static const filter = LucideIcons.slidersHorizontal;
  static const sync = LucideIcons.refreshCw;
  static const edit = LucideIcons.pencil;
  static const manageSchedule = LucideIcons.calendarCog;
  static const history = LucideIcons.history;
  static const add = LucideIcons.plus;
  static const lock = LucideIcons.lockKeyhole;
  static const switchAccount = LucideIcons.usersRound;
  static const download = LucideIcons.download;
  static const toolbox = LucideIcons.box;
  static const video = LucideIcons.video;
  static const image = LucideIcons.image;
  static const images = LucideIcons.images;
  static const camera = LucideIcons.camera;
  static const dragHandle = LucideIcons.gripVertical;
  static const audio = LucideIcons.music;
  static const pause = LucideIcons.pause;
  static const resume = LucideIcons.play;
  static const open = LucideIcons.externalLink;
  static const web = LucideIcons.globe;
  static const settings = LucideIcons.settings;
  static const paste = LucideIcons.clipboardPaste;
  static const copy = LucideIcons.copy;
  static const manage = LucideIcons.ellipsis;
  static const delete = LucideIcons.trash2;
  static const logout = LucideIcons.logOut;
  static const success = LucideIcons.circleCheck;
  static const warning = LucideIcons.circleAlert;
  static const info = LucideIcons.info;
  static const check = LucideIcons.check;
  static const reminder = LucideIcons.bell;
  static const exportCalendar = LucideIcons.calendarArrowUp;
  static const parse = LucideIcons.wandSparkles;
  static const termStart = LucideIcons.calendar1;
  static const jumpToday = LucideIcons.locateFixed;
  static const locateMe = LucideIcons.navigation;
  static const fullscreen = LucideIcons.maximize2;
  static const satelliteMap = LucideIcons.satellite;
  static const flatMap = LucideIcons.map;
  static const addPlace = LucideIcons.mapPinPlus;
  static const place = LucideIcons.mapPin;
  static const login = LucideIcons.logIn;
  static const restore = LucideIcons.rotateCcw;
  static const share = LucideIcons.share2;
  static const send = LucideIcons.send;
  static const qrCode = LucideIcons.qrCode;
  static const scanFace = LucideIcons.scanFace;
  static const scan = LucideIcons.scanQrCode;
  static const addFriend = LucideIcons.userPlus;
  static const removeFriend = LucideIcons.userMinus;
  static const palette = LucideIcons.palette;
  static const commonFree = LucideIcons.calendarCheck2;
  static const importSchedule = LucideIcons.import;
  static const replaceSchedule = LucideIcons.replace;
  static const mergeSchedule = LucideIcons.gitMerge;
  static const scanImage = LucideIcons.imageUp;
  static const flashlight = LucideIcons.flashlight;
  static const terms = LucideIcons.fileText;
  static const privacy = LucideIcons.shieldCheck;
  static const sourceCode = LucideIcons.codeXml;
  static const feedback = LucideIcons.messageSquareWarning;
  static const pin = LucideIcons.pin;
  static const unpin = LucideIcons.pinOff;
  static const course = LucideIcons.bookOpen;
  static const dayOff = LucideIcons.coffee;
  static const parcel = LucideIcons.package;
  static const phone = LucideIcons.smartphone;
  static const unbind = LucideIcons.unlink;
  static const logistics = LucideIcons.truck;
  static const developer = LucideIcons.bug;
  static const logs = LucideIcons.scrollText;
  static const exportLogs = LucideIcons.fileArchive;
  static const letter = LucideIcons.mailOpen;
  static const gift = LucideIcons.gift;
  static const celebrate = LucideIcons.partyPopper;
  // 游乐场：入口、益智板块、换一道题、新纪录、撤销与各游戏的图标。
  static const playground = LucideIcons.gamepad2;
  static const puzzle = LucideIcons.puzzle;
  static const shuffle = LucideIcons.shuffle;
  static const trophy = LucideIcons.trophy;
  static const undo = LucideIcons.undo2;
  static const flag = LucideIcons.flag;
  static const hanoi = LucideIcons.layers;
  static const nonogram = LucideIcons.grid3x3;
  static const queens = LucideIcons.crown;
  static const ice = LucideIcons.snowflake;
  static const boxes = LucideIcons.boxes;
  static const lights = LucideIcons.lightbulb;
  // 骑士与无赖：游戏图标是半边实心的盾（一半真话一半假话），标签上骑士是盾、无赖是面具。
  static const knights = LucideIcons.shieldHalf;
  static const knight = LucideIcons.shield;
  static const knave = LucideIcons.venetianMask;
  static const river = LucideIcons.sailboat;
  // 24 点：游戏图标是计算器，对局页的运算键是加减乘除号，困难起多乘方（x 带上标）与开方（根号）。
  static const twentyfour = LucideIcons.calculator;
  static const operatorAdd = LucideIcons.plus;
  static const operatorSubtract = LucideIcons.minus;
  static const operatorMultiply = LucideIcons.x;
  static const operatorDivide = LucideIcons.divide;
  static const operatorPower = LucideIcons.superscript;
  static const operatorRoot = LucideIcons.radical;
  static const flash = LucideIcons.brain;
  // 天平称球：游戏图标与「称一下」是天平；自己做的记号「可能偏重」是向下的箭头（沉下去），「可能偏轻」用 arrowUp，「好球」用 check。
  static const balance = LucideIcons.scale;
  static const arrowDown = LucideIcons.arrowDown;
  static const mines = LucideIcons.bomb;
  // 数回：套索是一笔绕成的圈。
  static const loop = LucideIcons.lasso;
}

void configureCampusIcons() =>
    MorphCache.configure(maxMorphs: 32, maxBytes: 4 * 1024 * 1024);

class CampusIcon extends StatelessWidget {
  const CampusIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
  });
  final IconData icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;
  @override
  Widget build(BuildContext context) {
    // iOS 的返回是向左的尖角（同系统导航栏），安卓是箭头。
    final glyph = icon == CampusIcons.back && defaultTargetPlatform == TargetPlatform.iOS ? CampusIcons.previous : icon;
    final child = Icon(
      glyph,
      size: size,
      color: color,
      semanticLabel: semanticLabel,
    );
    return icon == CampusIcons.back || icon == CampusIcons.next
        ? Transform.flip(
            flipX: Directionality.of(context) == TextDirection.rtl,
            child: child,
          )
        : child;
  }
}

class CampusMorphIcon extends StatefulWidget {
  const CampusMorphIcon({
    super.key,
    required this.from,
    required this.to,
    required this.selected,
    this.size = 24,
    this.color,
  });
  final IconData from;
  final IconData to;
  final bool selected;
  final double size;
  final Color? color;
  @override
  State<CampusMorphIcon> createState() => _CampusMorphIconState();
}

class _CampusMorphIconState extends State<CampusMorphIcon>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: widget.selected ? 1 : 0,
  );
  bool _allowed = false;
  void _update({bool animate = false}) {
    final target = widget.selected ? 1.0 : 0.0;
    if (!_allowed || !animate) {
      _controller.stop();
      _controller.value = target;
      return;
    }
    _controller.animateTo(target, curve: Curves.easeInOutCubic);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final allowed = CampusMotion.allowed(context);
    if (allowed != _allowed) {
      _allowed = allowed;
      _update();
    }
  }

  @override
  void didUpdateWidget(CampusMorphIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) _update(animate: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // [人工决策-2026-09-25 14:45:43] 图标仅随真实选中/展开状态形变；260ms无弹跳，减少动画或不可见时直接显示目标态。
  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: !_allowed
        ? CampusIcon(
            widget.selected ? widget.to : widget.from,
            size: widget.size,
            color: widget.color,
          )
        : MorphIcon(
            from: widget.from,
            to: widget.to,
            progress: _controller,
            size: widget.size,
            color: widget.color,
          ),
  );
}
