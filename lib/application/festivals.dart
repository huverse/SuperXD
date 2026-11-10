import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/festival.dart';

// 节日的编排（设备级，切换账号不重建；人工决策见 domain/festival.dart）：今天该播哪一次、记活跃天数、按需登记抽奖身份、抽签与奖品。
// 动画什么时候播由 app_moments.dart 决定，播什么由组合根按 page/festival/festival_catalog.dart 接上。
class Festivals extends ChangeNotifier {
  Festivals({required this.occasions, required this._memory, this._pass, this._client, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final List<FestivalOccasion> occasions;
  final FestivalMemory _memory;
  // 都为空（没配中转）时不登记、不抽签，只播动画。
  final FestivalPass? _pass;
  final FestivalRewardClient? _client;
  final DateTime Function() _clock;
  final _drawing = <String, Future<FestivalDraw?>>{};
  Future<void>? _preparing;

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

  // 同意协议与政策后、每次回到前台（组合根调）：先按需登记或撤下抽奖身份，再补抽上次没连上的签。
  Future<void> refresh() async {
    await prepare();
    await drawPending();
  }

  // 按需登记抽奖身份：有抽奖的节日临近（festivalPassNeeded）而还没登记成功，就生成密钥并登记一次，连不上或被限流只记日志、下次打开再试；
  // 节日都过了而本机还有抽奖身份，就请中转删掉这台抽奖设备、删本机密钥（没删成下次再试）。两种情形都不是时不碰安全存储、不联网。
  // 同一时刻只做一次；只在同意协议与政策之后调。whenComplete 写块体（理由同 draw）。
  Future<void> prepare() => _preparing ??= _prepare().whenComplete(() {
    _preparing = null;
  });

  Future<void> _prepare() async {
    final pass = _pass, state = _memory.record.pass;
    if (pass == null) return;
    try {
      if (festivalPassNeeded(occasions, _today)) {
        if (state == FestivalPassState.enrolled) return;
        // 先记下「开始生成过」：登记没成、节日又过了，也知道要回来删掉本机这把密钥。
        if (state == FestivalPassState.none) await _save(pass: FestivalPassState.created);
        await pass.enroll();
        await _save(pass: FestivalPassState.enrolled);
        campusLog('[Festival] action=enroll');
      } else if (state != FestivalPassState.none) {
        await pass.retire();
        await _save(pass: FestivalPassState.none);
        campusLog('[Festival] action=retire');
      }
    } on FestivalException catch (error) {
      campusLog('[Festival] action=prepare state=${state.name} errorType=FestivalException message=$error');
    } catch (error, stack) {
      // 安全存储读写出错（系统接口异常）也只记日志，不挡后面的补抽。
      campusLog('[Festival] action=prepare state=${state.name} errorType=${error.runtimeType}\n$stack');
    }
  }

  // 动画开始播：记下，之后不再播（中途被杀掉也不重播）。
  Future<void> markPlayed(FestivalOccasion occasion) => _save(played: [..._memory.record.played.where((id) => id != occasion.id), occasion.id]);

  Future<void> markRevealed(FestivalPrize prize) =>
      _save(prizes: [for (final item in _memory.record.prizes) item.occasion == prize.occasion && item.content == prize.content ? item.reveal() : item]);

  // 抽签：这次节日有抽奖、配了中转、抽奖身份已登记、还没抽出结果时才去抽；结果（抽中、没抽中、活动不在进行）记下就不再抽。
  // 连不上或还没登记成功返回 null、不记，下次回到前台由 refresh 登记后再补抽。同一次节日同一时刻只发一次。
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
    // 登记还在路上就等它：节日当天第一次打开时，登记与节日动画几乎同时开始。
    if (_preparing case final preparing?) await preparing;
    if (_memory.record.pass != FestivalPassState.enrolled) {
      campusLog('[Festival] action=draw occasion=${occasion.id} errorType=NotEnrolled');
      return null;
    }
    final activeDays = festivalActiveDays(_memory.record.activeDays, _today).length;
    final FestivalDraw result;
    try {
      result = await client.draw(campaign, occasion: occasion.id, activeDays: activeDays);
    } on FestivalNotEnrolled catch (error) {
      // 中转不认这台抽奖设备了（本机密钥没了，或服务端删了它）：记成没登记成功，下次打开时重新登记再补抽。
      campusLog('[Festival] action=draw occasion=${occasion.id} errorType=FestivalNotEnrolled message=$error');
      await _save(pass: FestivalPassState.created);
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

  // 写本机记录失败只记日志：最坏是重播一次动画、再抽一次（服务器按抽奖设备幂等，结果不变）或再登记一次（幂等）。
  Future<void> _save({FestivalPassState? pass, Set<String>? activeDays, List<String>? played, List<String>? drawn, List<FestivalPrize>? prizes}) async {
    final record = _memory.record;
    final saving = _memory.save(FestivalRecord(
      pass: pass ?? record.pass,
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
