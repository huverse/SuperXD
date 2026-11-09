import 'package:superxd/domain/schedule_store.dart';

// [人工决策-2026-11-05 17:18:44] 自动同步（用户四项选定）：可开关、可设间隔，范围同手动同步（学年加内容）；
// 系统后台定时同步（安卓 WorkManager 周期任务、只在联网时跑；iOS 后台刷新，时机由系统定），应用开着时交给前台那份去做；
// 和本地改过的课表冲突时不覆盖，留到打扰时机问（见 application/app_moments.dart）；登录过期时不打断、只暂停：不转登录页、本机会话留着（CampusGateway.keepSessionDuring），
// 下次打开照常看本机数据，手动操作时才按原规则重新登录。
// 冲突的选择性覆盖按三方合并，基准是上次教务同步的版本（见 domain/schedule_merge.dart 的 scheduleMergeOrigins）。
// 合并页（page/sync_merge_page.dart）：默认只勾只有教务改了的，你改过的与两边都改了的先保留你的；没勾任何一项时按钮是「保留我的课表」；整份替换要确认；
// 手动同步时退出合并页同「保留本地」，这份教务课表不再提醒（本机课表没读到时不算选过，留到打扰时机再问）。
// [人工决策-2026-11-09 12:56:15] 允许后台自动重登（审查发现同步端口本就带「会话失效自动重登一次再重放」，后台引擎也带着记住的凭据，用户选「允许」）：
// 记住了账号时，自动同步在后台遇到登录过期也用存着的密码重新登录一次，同手动同步；隐私政策第一节与自动同步设置里写明（明文、用当时连着的网络），
// 修订号加一提示老用户。没记住账号的照旧只暂停。其余审查发现按用户「按最佳实践全部优化」修：一轮同步中途换账号就停下、不记结果；
// 给手动同步让路不记成成功；手动同步等让路的那轮收尾再发请求；后台任务有时限（iOS 后台刷新约 30 秒）与叫停；打扰时机用之前重读暂存的那份。

// 同步的数据项，手动同步与自动同步共用。
enum SyncContent { schedule, bells, grades }

// 可选的间隔（能点就不手输）；默认每天。安卓周期任务最短 15 分钟，最短一档远在它之上。
const autoSyncIntervals = [Duration(hours: 6), Duration(days: 1), Duration(days: 3), Duration(days: 7)];
const autoSyncDefaultInterval = Duration(days: 1);

// 系统叫醒的时刻会比约定的早一点（周期任务有浮动），早这么多以内也算到期，不白白拖到下一个周期。
const autoSyncSlack = Duration(minutes: 15);

// 上次因为网络没连上没同步成：过这么久再试（后台任务本来就等联网才跑，这条管的是回到前台时的补跑）。
const autoSyncNetworkRetry = Duration(minutes: 15);

class AutoSyncSetting {
  const AutoSyncSetting({
    this.enabled = false,
    this.interval = autoSyncDefaultInterval,
    this.years,
    this.contents = const {SyncContent.schedule, SyncContent.grades},
  });
  final bool enabled;
  final Duration interval;
  // 为空表示「当前学年」：每次按本机记的当前学期取，跨学年时自动跟上。
  final Set<String>? years;
  final Set<SyncContent> contents;

  AutoSyncSetting copyWith({bool? enabled, Duration? interval, Set<String>? Function()? years, Set<SyncContent>? contents}) => AutoSyncSetting(
    enabled: enabled ?? this.enabled,
    interval: interval ?? this.interval,
    years: years == null ? this.years : years(),
    contents: contents ?? this.contents,
  );
}

// 上次自动同步的结果。paused 是登录过期（不打断、只暂停）：后台不再试，重新登录后恢复，用户打开应用时到了间隔也试一次（会话可能其实还有效）；
// network 是没连上网，autoSyncNetworkRetry 后再试。
enum AutoSyncState { ok, failed, network, limited, paused }

class AutoSyncStatus {
  const AutoSyncStatus({this.lastAttemptAt, this.lastSuccessAt, this.state, this.message = ''});
  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessAt;
  final AutoSyncState? state;
  final String message;
}

class AutoSyncView {
  const AutoSyncView({required this.setting, required this.status});
  final AutoSyncSetting setting;
  final AutoSyncStatus status;
}

// 到没到该自动同步的时候：开着，离上次尝试过了间隔（网络没连上的那次只隔 autoSyncNetworkRetry）；登录过期暂停时后台不到期，foreground（用户打开着应用）才照间隔试。
// 上次尝试的时刻比现在还晚（系统时间曾被调到以后又改回来）就当到期，不然要一直等到那个时刻。
bool autoSyncDue(AutoSyncView view, DateTime now, {bool foreground = false}) {
  final status = view.status, last = status.lastAttemptAt;
  if (!view.setting.enabled || (status.state == AutoSyncState.paused && !foreground)) return false;
  if (last == null || last.isAfter(now.add(autoSyncSlack))) return true;
  final gap = status.state == AutoSyncState.network ? autoSyncNetworkRetry : view.setting.interval - autoSyncSlack;
  return !now.isBefore(last.add(gap));
}

// 自动同步拿到、但和本地改过的课表冲突、等用户来选的那份教务课表（每学期最多一份）。
class HeldScheduleSync {
  const HeldScheduleSync({required this.term, required this.courses, required this.fetchedAt});
  final TermRef term;
  final List<CourseRecord> courses;
  final String fetchedAt;
}

// 系统后台定时任务的端口（device 实现）：按间隔排一个只在联网时跑的周期任务（delay 后第一次，之后每隔 interval），或撤掉。
abstract interface class BackgroundSyncScheduler {
  Future<void> schedule(Duration interval, {required Duration delay});
  Future<void> cancel();
}

// 离下一次到期还有多久（排后台任务的第一次用）：没尝试过或已经到期时为零，最长一个间隔（上次尝试的时刻比现在晚时同 autoSyncDue 按到期算）。
Duration autoSyncDelay(AutoSyncView view, DateTime now) {
  final last = view.status.lastAttemptAt;
  if (last == null || last.isAfter(now.add(autoSyncSlack))) return Duration.zero;
  final left = last.add(view.setting.interval).difference(now);
  return left.isNegative ? Duration.zero : left;
}
