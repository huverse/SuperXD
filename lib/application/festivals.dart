import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/festival.dart';

// 节日的编排（设备级，切换账号不重建；人工决策见 domain/festival.dart）：今天该播哪一次、记活跃天数、抽签与奖品。
// 动画什么时候播由 app_moments.dart 决定，播什么由组合根按 page/festival/festival_catalog.dart 接上。
// 抽签用当前的应用账号（组合根注入 account，只认 AppAccountRef）；中转说账号已不在时调 accountGone（组合根让应用账号马上核一次）。
class Festivals extends ChangeNotifier {
  Festivals({required this.occasions, required this._memory, this._client, AppAccountRef? Function()? account, this._accountGone, DateTime Function()? clock})
    : _account = account ?? (() => null),
      _clock = clock ?? DateTime.now;
  final List<FestivalOccasion> occasions;
  final FestivalMemory _memory;
  // 为空（没配中转）时不抽签，只播动画。
  final FestivalRewardClient? _client;
  final AppAccountRef? Function() _account;
  final void Function()? _accountGone;
  final DateTime Function() _clock;
  final _drawing = <String, Future<FestivalDraw?>>{};

  String get _today => formatCampusDate(campusInstant(_clock().toUtc()));

  // 今天在过、还没播过的那一次；同一天有几次时取登记在前的。
  FestivalOccasion? get due {
    final today = _today, played = _memory.record.played;
    return occasions.where((occasion) => occasion.on(today) && !played.contains(occasion.id)).firstOrNull;
  }

  // 抽中了还没揭晓的奖品（动画放完时结果还没回来，或揭晓前被打断）。
  FestivalPrize? get unrevealed => _kept.where((prize) => !prize.revealed).firstOrNull;

  // 还留着的奖品：节日结束后再留 festivalPrizeKeepDays 天，「我的」里能再打开。
  List<FestivalPrize> get prizes => _kept.toList();

  Iterable<FestivalPrize> get _kept => _memory.record.prizes.where((prize) => festivalPrizeKept(prize, occasions, _today));

  // 奖品卡与开启动效上写的节日名。
  String occasionName(String id) => occasions.where((occasion) => occasion.id == id).firstOrNull?.name ?? '节日红包';

  // 记今天打开过应用（启动、回到前台时调）；只留近 30 天，同一天只写一次。
  Future<void> recordActive() async {
    final record = _memory.record, today = _today;
    if (record.activeDays.contains(today)) return;
    await _save(activeDays: festivalActiveDays({...record.activeDays, today}, today));
  }

  // 同意协议与政策后、每次回到前台、登录应用账号后（组合根调）：补抽播过动画、上次没抽成的签。
  Future<void> refresh() => drawPending();

  // 这次节日有抽奖、还没抽出结果，但没登录应用账号抽不了：动画放完时提示可以去登录（组合根）。
  bool needsSignIn(FestivalOccasion occasion) => occasion.campaign != null && _client != null && _account() == null && !_memory.record.drawn.contains(occasion.id);

  // 动画开始播：记下，之后不再播（中途被杀掉也不重播）。
  Future<void> markPlayed(FestivalOccasion occasion) => _save(played: [..._memory.record.played.where((id) => id != occasion.id), occasion.id]);

  Future<void> markRevealed(FestivalPrize prize) =>
      _save(prizes: [for (final item in _memory.record.prizes) item.occasion == prize.occasion && item.content == prize.content ? item.reveal() : item]);

  // 抽签：这次节日有抽奖、配了中转、登录着应用账号、还没抽出结果时才去抽；结果（抽中、没抽中、活动不在进行）记下就不再抽。
  // 连不上或没登录返回 null、不记，下次回到前台（或登录后）由 refresh 补抽。同一次节日同一时刻只发一次。
  // whenComplete 的回调写成块体：remove 返回的正是这个 Future，箭头体会让它等自己、永远完成不了。
  Future<FestivalDraw?> draw(FestivalOccasion occasion) => _drawing[occasion.id] ??= _draw(occasion).whenComplete(() {
    _drawing.remove(occasion.id);
  });

  // 播过动画、抽签上次没连上、节日还在过的，补抽一次（回到前台时经 refresh 调）；抽中的等打扰时机揭晓。
  Future<void> drawPending() async {
    final record = _memory.record, today = _today;
    for (final occasion in occasions.where((item) => item.campaign != null && item.on(today) && record.played.contains(item.id) && !record.drawn.contains(item.id))) {
      await draw(occasion);
    }
  }

  Future<FestivalDraw?> _draw(FestivalOccasion occasion) async {
    final campaign = occasion.campaign, client = _client;
    if (campaign == null || client == null || _memory.record.drawn.contains(occasion.id)) return null;
    final account = _account();
    if (account == null) {
      campusLog('[Festival] action=draw occasion=${occasion.id} state=signed_out');
      return null;
    }
    final activeDays = festivalActiveDays(_memory.record.activeDays, _today).length;
    final FestivalDraw result;
    try {
      result = await client.draw(account, campaign, occasion: occasion.id, activeDays: activeDays);
    } on FestivalNotSignedIn catch (error) {
      // 中转说这个应用账号已不在（别处注销、被清理）：不记结果，让应用账号马上核一次，本机随之退回未登录。
      campusLog('[Festival] action=draw occasion=${occasion.id} errorType=FestivalNotSignedIn message=$error');
      _accountGone?.call();
      return null;
    } on FestivalException catch (error) {
      campusLog('[Festival] action=draw occasion=${occasion.id} errorType=FestivalException message=$error');
      return null;
    }
    final record = _memory.record;
    await _save(
      drawn: [...record.drawn, occasion.id],
      prizes: [...record.prizes.where((prize) => festivalPrizeKept(prize, occasions, _today)), if (result case FestivalWon(:final prize)) prize],
    );
    campusLog('[Festival] action=drawn occasion=${occasion.id} activeDays=$activeDays result=${result.runtimeType}');
    return result;
  }

  // 写本机记录失败只记日志：最坏是重播一次动画、再抽一次（服务器按人幂等，结果不变）。
  Future<void> _save({Set<String>? activeDays, List<String>? played, List<String>? drawn, List<FestivalPrize>? prizes}) async {
    final record = _memory.record;
    final saving = _memory.save(FestivalRecord(
      activeDays: activeDays ?? record.activeDays,
      played: played ?? record.played,
      drawn: drawn ?? record.drawn,
      prizes: prizes ?? record.prizes,
    ));
    notifyListeners();
    try {
      await saving;
    } catch (error, stack) {
      campusLog('[Festival] action=save errorType=${error.runtimeType}\n$stack');
    }
  }
}
