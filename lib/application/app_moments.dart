import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:superxd/application/developer_notes.dart';
import 'package:superxd/application/festivals.dart';
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

class NoteLetterMoment extends AppMoment {
  const NoteLetterMoment(this.note);
  final DeveloperNote note;
}

// 快捷入口拉起前后这么久之内回到前台的，算作那一次前台（系统先报回到前台还是先交入口，先后不定）。
const _launchSlack = Duration(seconds: 3);

// [人工决策-2026-10-23 23:25:34] 打扰时机（用户要求不在迫切的时候打扰、不迫切时立即出现；安静期见 domain/interruption.dart）。
// 一次只出现一件，先后是节日动画、没揭晓的奖品、新信（节日只有那一天，信两周内都能弹）。
// 业务条件在这里：每次回到前台最多出现一件；从快捷入口进来的那次前台不出现（用户有明确要做的事）；在上下课安静期里不出现，安静期一结束再提醒组合根看一眼。
// 界面条件在组合根（main.dart 的 _promptMoment）：只在底栏四个根页、没有弹窗弹层、协议与政策已同意且没有待弹的提示、开屏走完，停稳一会儿再出现。
class AppMoments extends ChangeNotifier {
  AppMoments({this.notes, this.festivals, required this.timetable, DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    _foregroundAt = _clock();
    notes?.addListener(notifyListeners);
    festivals?.addListener(notifyListeners);
  }
  final DeveloperNotes? notes;
  final Festivals? festivals;
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

  AppMoment? get _candidate => switch ((festivals?.due, festivals?.unrevealed, notes?.letter)) {
    (final occasion?, _, _) => CelebrationMoment(occasion),
    (_, final prize?, _) => RewardMoment(prize),
    (_, _, final letter?) => NoteLetterMoment(letter),
    _ => null,
  };

  // 出现了：这次前台用掉，播过的节日、弹出的信记下（揭晓过的奖品由揭晓那一步记）。
  void begin(AppMoment moment) {
    _spent = true;
    campusLog('[AppMoments] action=begin kind=${moment.runtimeType}');
    switch (moment) {
      case CelebrationMoment(:final occasion):
        unawaited(festivals?.markPlayed(occasion));
      case RewardMoment():
        break;
      case NoteLetterMoment(:final note):
        unawaited(notes?.markLetterShown(note));
    }
  }

  @override
  void dispose() {
    _quiet?.cancel();
    notes?.removeListener(notifyListeners);
    festivals?.removeListener(notifyListeners);
    super.dispose();
  }
}
