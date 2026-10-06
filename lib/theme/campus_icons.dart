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
  static const audio = LucideIcons.music;
  static const pause = LucideIcons.pause;
  static const resume = LucideIcons.play;
  static const open = LucideIcons.externalLink;
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
  static const login = LucideIcons.logIn;
  static const restore = LucideIcons.rotateCcw;
  static const share = LucideIcons.share2;
  static const send = LucideIcons.send;
  static const qrCode = LucideIcons.qrCode;
  static const scan = LucideIcons.scanQrCode;
  static const addFriend = LucideIcons.userPlus;
  static const removeFriend = LucideIcons.userMinus;
  static const palette = LucideIcons.palette;
  static const commonFree = LucideIcons.calendarCheck2;
  static const scanImage = LucideIcons.imageUp;
  static const flashlight = LucideIcons.flashlight;
  static const terms = LucideIcons.fileText;
  static const privacy = LucideIcons.shieldCheck;
  static const sourceCode = LucideIcons.codeXml;
  static const feedback = LucideIcons.messageSquareWarning;
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
    final child = Icon(
      icon,
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
