import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:superxd/application/app_updates.dart';
import 'package:superxd/application/auto_sync.dart';
import 'package:superxd/application/developer_notes.dart';
import 'package:superxd/application/festivals.dart';
import 'package:superxd/domain/auto_sync.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/developer_note.dart';
import 'package:superxd/domain/festival.dart';
import 'package:superxd/domain/interruption.dart';

// 打扰时机里要出现的一件事。
sealed class AppMoment {
  const AppMoment();
}

// 节日动画（同时去抽签，抽中的放完动画接着揭晓）。
class CelebrationMoment extends AppMoment {
  const CelebrationMoment(this.occasion);
  final FestivalOccasion occasion;
}

// 抽中了还没揭晓的奖品：动画放完时结果还没回来，或揭晓前被打断的，下次单独揭晓。
class RewardMoment extends AppMoment {
  const RewardMoment(this.prize);
  final FestivalPrize prize;
}

// 自动同步拿到的教务课表和本地改过的不一样，问要不要逐项合并（人工决策见 domain/auto_sync.dart）。
class SyncConflictMoment extends AppMoment {
  const SyncConflictMoment(this.held);
  final HeldScheduleSync held;
}

class NoteLetterMoment extends AppMoment {
  const NoteLetterMoment(this.note);
  final DeveloperNote note;
}

// 快捷入口拉起前后这么久之内回到前台的，算作那一次前台（系统先报回到前台还是先交入口，先后不定）。
const _launchSlack = Duration(seconds: 3);

// [人工决策-2026-10-23 23:25:34] 打扰时机（用户要求不在迫切的时候打扰、不迫切时立即出现；安静期见 domain/interruption.dart）。
// 一次只出现一件，先后是节日动画、没揭晓的奖品、新信（节日只有那一天，信两周内都能弹）。
// [人工决策-2026-11-05 17:18:44] 用户要求自动同步的课表冲突按同一套打扰时机弹出：排在奖品之后、新信之前（关乎自己的课表，比信要紧；节日只有那一天）。
// 业务条件在这里：每次回到前台最多出现一件；从快捷入口进来的那次前台不出现（用户有明确要做的事）；在上下课安静期里不出现，安静期一结束再提醒组合根看一眼。
// 界面条件在组合根（app_shell.dart 的 _promptMoment）：只在底栏四个根页、没有弹窗弹层、协议与政策已同意且没有待弹的提示、开屏走完，停稳一会儿再出现。
// [人工决策-2026-11-18 23:24:41] 信在用户关掉时才记成弹过（closed），有强制更新还没装时不弹信：11-18 欢迎信在旧版里刚弹出就被强制更新盖住，
// 用户直接去更新，新版认为弹过、再也不弹（用户要求修好、让它在新版里再弹一次，人工决策另见 local/developer_note_memory.dart）。
class AppMoments extends ChangeNotifier {
  AppMoments({this.notes, this.festivals, this.autoSync, this.updates, required this.timetable, DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    _foregroundAt = _clock();
    notes?.addListener(notifyListeners);
    festivals?.addListener(notifyListeners);
    autoSync?.addListener(notifyListeners);
    updates?.addListener(notifyListeners);
  }
  final DeveloperNotes? notes;
  final Festivals? festivals;
  final AutoSync? autoSync;
  final AppUpdates? updates;
  // 今天的课（当前账号本机课表，只读本地）；未登录或缺开学日、作息时为空，也就没有安静期。
  final Future<CampusTimetable> Function() timetable;
  final DateTime Function() _clock;
  late DateTime _foregroundAt;
  DateTime? _taskAt;
  bool _spent = false;
  Timer? _quiet;

  // 应用又被看到（从后台回来）：重新计这一次前台。
  void foreground() {
    _foregroundAt = _clock();
    _spent = false;
    notifyListeners();
  }

  // 从快捷入口进来（冷启动或在后台被拉起）：这次前台不打扰。
  void taskLaunch() => _taskAt = _clock();

  bool get _task => _taskAt != null && _taskAt!.isAfter(_foregroundAt.subtract(_launchSlack));

  // 现在该出现的一件；不出现返回 null。只看不记，真的出现了再调 begin。
  Future<AppMoment?> next() async {
    if (_spent || _task) return null;
    final candidate = _candidate;
    if (candidate == null) return null;
    final CampusTimetable today;
    try {
      today = await timetable();
    } catch (error, stack) {
      campusLog('[AppMoments] action=timetable errorType=${error.runtimeType}\n$stack');
      return null;
    }
    final now = _clock();
    final until = classQuietUntil(now.toUtc(), today.items);
    if (until != null) {
      _quiet?.cancel();
      _quiet = Timer(until.difference(now.toUtc()), notifyListeners);
      campusLog('[AppMoments] action=defer reason=class until=${until.toIso8601String()}');
      return null;
    }
    return candidate;
  }

  AppMoment? get _candidate => switch ((festivals?.due, festivals?.unrevealed, autoSync?.held.firstOrNull, notes?.letter)) {
    (final occasion?, _, _, _) => CelebrationMoment(occasion),
    (_, final prize?, _, _) => RewardMoment(prize),
    (_, _, final held?, _) => SyncConflictMoment(held),
    (_, _, _, final letter?) when !(updates?.forced ?? false) => NoteLetterMoment(letter),
    _ => null,
  };

  // 出现了：这次前台用掉，播过的节日记下（揭晓过的奖品由揭晓那一步记，信等用户关掉，见 closed）。
  void begin(AppMoment moment) {
    _spent = true;
    campusLog('[AppMoments] action=begin kind=${moment.runtimeType}');
    if (moment case CelebrationMoment(:final occasion)) unawaited(festivals?.markPlayed(occasion));
  }

  // 用户把它关掉了：信这时才记成弹过（被强制更新盖住、没关就换了新版的，新版里再弹）。
  void closed(AppMoment moment) {
    campusLog('[AppMoments] action=closed kind=${moment.runtimeType}');
    if (moment case NoteLetterMoment(:final note)) unawaited(notes?.markLetterShown(note));
  }

  @override
  void dispose() {
    _quiet?.cancel();
    notes?.removeListener(notifyListeners);
    festivals?.removeListener(notifyListeners);
    autoSync?.removeListener(notifyListeners);
    updates?.removeListener(notifyListeners);
    super.dispose();
  }
}
