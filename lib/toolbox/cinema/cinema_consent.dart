import 'package:flutter/widgets.dart';

import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';
import 'package:superxd/toolbox/cinema/cinema_service.dart';

// 第三方片源的同意（首页搜索前、续播、选集页与播放页换源共用一个弹窗）：同意按规则 id 与接口主机记（CinemaService.grantRules），
// 新源、换了接口主机或改走境外转发的要重新同意。
// [人工决策-2026-11-22 14:03:26] 续播、选集页、播放页换源时遇到没同意的源当场问（11-22 Codex 复核 P1，用户选「当场弹同意框」，
// 没选「提示回首页重新同意」）：弹同一个框、只列这个源，同意了接着取选集，不同意就停在这里、可以换别的源；同常见应用「用到时再申请」。

// 同意弹窗里的一个源：经开发者的服务器（片名目录型）或境外转发（人工决策见 cinema_rule.dart 的 CinemaRule.forward）的在名字后面写明。
String cinemaConsentName(CinemaRule rule) {
  final via = [if (rule.catalog != null) '片名经开发者服务器查找', if (rule.forward != null) '经开发者的境外转发'];
  return via.isEmpty ? rule.name : '${rule.name}（${via.join('，')}，不保存）';
}

// 问一次这几个源；同意了记下并返回真。
Future<bool> askCinemaConsent(BuildContext context, CinemaService service, List<CinemaRule> rules, {required String action}) async {
  final agreed = await showCampusConfirm(
    context,
    title: '使用第三方片源',
    // 长文案：首次同意要说清片名发给谁、内容归谁；片名目录型的源（人工决策见 cinema_catalog.dart）片名先发到开发者服务器查编号，
    // 国内连不上的源（人工决策见 cinema_rule.dart 的 CinemaRule.forward）经开发者的境外转发。
    message: '片名会发给以下站点，片源与画面来自第三方，版权归原权利人：\n${[for (final rule in rules) cinemaConsentName(rule)].join('、')}',
    action: action,
  );
  if (!agreed) return false;
  await service.grantRules(rules);
  return true;
}

// 没同意使用这个源（页面照常显示成错误；不算这个源没播成）。
class CinemaConsentDeclined extends CinemaRuleException {
  const CinemaConsentDeclined() : super('没同意使用这个源，可以换一个源');
}

// 取选集（CinemaService.chapters）；这个源还没同意时当场问（见文件头），同意了再取，不同意抛 CinemaConsentDeclined。
// onAgreed 在同意之后、再取之前调：播放页据此重新起算打开用时与慢提示（停在弹窗上的时间不算这个源慢）。
Future<List<CinemaRoad>> cinemaChapters(BuildContext context, CinemaService service, CinemaRule rule, String source, {bool fresh = false, Future<void>? cancel, (DateTime, List<CinemaRoad>)? carried, VoidCallback? onAgreed}) async {
  try {
    return await service.chapters(rule, source, fresh: fresh, cancel: cancel, carried: carried);
  } on CinemaConsentNeeded {
    if (!context.mounted || !await askCinemaConsent(context, service, [rule], action: '同意并继续')) throw const CinemaConsentDeclined();
    onAgreed?.call();
    return service.chapters(rule, source, fresh: fresh, cancel: cancel, carried: carried);
  }
}
