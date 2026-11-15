import 'package:flutter/foundation.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/playground/challenge/play_challenge.dart';

// 一局挑战的控制器（人工决策见 challenge_rules.dart）：拿着服务器给的局面，交答案、开门、输终章、刷新、提前结束，局面变了通知页面。
// 倒计时按服务器时刻算：每次收到局面记下服务器与本机的偏差，到点时刻换成本机钟；服务器计时不暂停，本机只负责显示。
// 交答案的号码就是这一关交过几次（服务器给的）：没收到回复时用同一个号重交，服务器只算一次。
class ChallengeRunController extends ChangeNotifier {
  ChallengeRunController({required this.hub, required ChallengeRun run, DateTime Function()? now}) : _now = now ?? DateTime.now {
    _apply(run);
  }
  final ChallengeHub hub;
  final DateTime Function() _now;
  late ChallengeRun _run;
  // 服务器时刻减本机时刻。
  Duration _offset = Duration.zero;
  bool busy = false;

  ChallengeRun get run => _run;

  // 到点时刻（本机钟）。
  DateTime get deadline => _run.deadline.toLocal().subtract(_offset);
  Duration get remaining => _run.running ? deadline.difference(_now()) : Duration.zero;

  void _apply(ChallengeRun run) {
    _run = run;
    _offset = run.serverTime.difference(_now().toUtc());
    notifyListeners();
  }

  PlayChallenge challengeFor(String levelId) {
    final level = _run.level(levelId);
    return PlayChallenge(level: level, name: challengeLevelName(level), deadline: deadline, submit: (answer) => submit(levelId, answer));
  }

  Future<PlayVerdict> submit(String levelId, Object? answer) async {
    final attempt = _run.level(levelId).submissions;
    try {
      final verdict = await hub.answer(_run.runId, levelId, attempt, answer);
      _apply(verdict.run);
      return PlayVerdict(correct: verdict.correct, fragment: verdict.fragment, extra: verdict.extra);
    } on ChallengeException catch (error) {
      if (error.run case final run?) _apply(run);
      switch (error.failure) {
        case ChallengeFailure.runOver:
          return const PlayVerdict(correct: false, over: true);
        case ChallengeFailure.levelLocked:
          return PlayVerdict(correct: false, over: !_run.running);
        default:
          rethrow;
      }
    }
  }

  // 开门（levelId 是门后面那一关）或输终章的最终密码：对不对；错了服务器已扣时间，局面跟着更新。连不上抛 ChallengeException。
  Future<bool> gate(String levelId, int value) => _enter(() => hub.gate(_run.runId, levelId, value));

  Future<bool> finale(int value) => _enter(() => hub.finale(_run.runId, value));

  Future<bool> _enter(Future<ChallengeEntry> Function() send) async {
    try {
      final entry = await send();
      _apply(entry.run);
      return entry.correct;
    } on ChallengeException catch (error) {
      if (error.run case final run?) _apply(run);
      if (error.failure == ChallengeFailure.levelLocked || error.failure == ChallengeFailure.runOver) return false;
      rethrow;
    }
  }

  // 拉一次局面（回到前台、到点时）：到点的服务器顺手结算。失败只记日志，照旧显示上一次的。
  Future<ChallengeException?> refresh() => _guard('refresh', () async => _apply(await hub.run(_run.runId)));

  Future<ChallengeException?> end() => _guard('end', () async => _apply(await hub.end(_run.runId)));

  Future<ChallengeException?> _guard(String action, Future<void> Function() work) async {
    if (busy) return null;
    busy = true;
    notifyListeners();
    try {
      await work();
      return null;
    } on ChallengeException catch (error) {
      campusLog('[Challenge] action=$action failure=${error.failure.name}');
      if (error.run case final run?) _apply(run);
      return error;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
