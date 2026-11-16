import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/application/account_diagnostics.dart';
import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/application/app_moments.dart';
import 'package:superxd/application/app_updates.dart';
import 'package:superxd/application/auto_sync.dart';
import 'package:superxd/application/campus_reminders.dart';
import 'package:superxd/application/challenges.dart';
import 'package:superxd/application/developer_notes.dart';
import 'package:superxd/application/festivals.dart';
import 'package:superxd/application/leisure.dart';
import 'package:superxd/application/rollouts.dart';
import 'package:superxd/application/unlocks.dart';
import 'package:superxd/device/app_installer_channel.dart';
import 'package:superxd/device/app_package_files.dart';
import 'package:superxd/device/diagnostic_device.dart';
import 'package:superxd/device/relay_diagnostic_upload.dart';
import 'package:superxd/device/relay_note_feed.dart';
import 'package:superxd/device/relay_release_feed.dart';
import 'package:superxd/device/relay_rollout_feed.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/app_shortcut.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/painting.dart';
import 'package:superxd/domain/unlock.dart';
import 'package:superxd/local/app_update_memory.dart';
import 'package:superxd/local/developer_note_memory.dart';
import 'package:superxd/local/developer_settings.dart';
import 'package:superxd/local/diagnostic_log.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/local/festival_memory.dart';
import 'package:superxd/local/legal_notice_memory.dart';
import 'package:superxd/local/rollout_memory.dart';
import 'package:superxd/page/festival/festival_catalog.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/social/relay_app_account.dart';
import 'package:superxd/social/relay_challenge_client.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/relay_diagnostic_account.dart';
import 'package:superxd/social/relay_reward_client.dart';
import 'package:superxd/social/relay_unlock_client.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 组合根造好的设备级服务（[人工决策-2026-11-16 17:26:21] 组合根改应用模块，用户选定架构推荐方案）：打包成一份交给应用外壳、账号应用与路由，
// 新功能只在这里加一个字段，不再在 SuperXdApp、账号应用与 buildRouter 三处各加一个参数。为空的表示这项没有（没配中转、测试没给），页面照各自的规则藏起入口。
class AppServices {
  const AppServices({this.display, this.toolbox, this.playground, this.reminders, this.social, this.updates, this.legal, this.developer, this.logs, this.paintings, this.shortcuts, this.notes, this.festivals, this.appAccounts, this.diagnostics, this.challenges, this.unlocks, this.leisure, this.moments, this.autoSync});
  // 显示设置；为空时用一份只在内存里的。
  final DisplaySettings? display;
  // 百宝箱运行时；为空时外壳按注册表自己建。
  final ToolboxRuntime? toolbox;
  // 游乐场的本机记录（切换账号保留）；为空时用应用支持目录里的那份。
  final PlaygroundStore? playground;
  final CampusReminders? reminders;
  // 私信服务，切换账号不重建；为空时私信入口显示未配置。
  final SocialService? social;
  // 应用内更新；为空时关于页不显示检查更新、也不弹更新。
  final AppUpdates? updates;
  // 协议与政策看过哪一版；为空时不做更新提示。
  final LegalNoticeMemory? legal;
  // 开发者模式与本机日志；为空时关于页不能开启开发者模式。
  final DeveloperSettings? developer;
  final DiagnosticLog? logs;
  // 开屏画作；为空时关于页不显示「开屏画作」。
  final PaintingGallery? paintings;
  // 常用功能的快捷入口（系统端口，接线见 app_shortcuts.dart）；为空时不发布入口、页面不显示「添加到桌面」。
  final AppShortcutPort? shortcuts;
  // 开发者的话；为空时「我的」页不显示这一行。
  final DeveloperNotes? notes;
  // 节日；为空时不播节日动画、「我的」页没有节日红包。
  final Festivals? festivals;
  final AppAccounts? appAccounts;
  final AccountDiagnostics? diagnostics;
  final Challenges? challenges;
  final UnlockAccess? unlocks;
  // 娱乐与积分的开关（人工决策见 domain/leisure.dart）；为空时游乐场照常显示、「我的」里没有这一行。
  final Leisure? leisure;
  // 打扰时机（人工决策见 application/app_moments.dart）；为空时节日动画、新信都不出现。
  final AppMoments? moments;
  // 自动同步；为空时「同步范围」里没有自动同步入口，也不会有课表冲突的打扰时机。
  final AutoSync? autoSync;
}

// 中转服务地址来自构建参数 SUPERXD_RELAY；未配置或格式不对时私信与应用更新都不可用，不猜默认地址。
String? relayBase() {
  if (relayBaseUrl.isEmpty) return null;
  final uri = Uri.tryParse(relayBaseUrl);
  if (uri == null || !uri.isScheme('http') && !uri.isScheme('https') || uri.host.isEmpty || relayBaseUrl.endsWith('/')) {
    campusLog('[Relay] action=config errorType=INVALID_RELAY_URL');
    return null;
  }
  return relayBaseUrl;
}

RelayTransport? relayTransport() => switch (relayBase()) {
  final base? => HttpRelayTransport(base),
  null => null,
};

// 应用内更新走同一个自建中转，渠道就是构建渠道（appFlavor，如 alpha）；没配中转、不是渠道构建（测试）或认不出架构时不检查更新。
// [人工决策-2026-10-26 22:08:25] iOS 不能在应用里安装（用户选定「检查新版后去下载页」）：按 arm64 取同一份清单，只看版本与更新说明、不要安装包，
// 弹窗里给「去发布页下载」，由用户下载未签名包后自己重新签名安装。
Future<AppUpdates?> appUpdates(Directory support, Rollouts rollouts) async {
  final base = relayBase(), channel = appFlavor, abi = Platform.isIOS ? 'arm64-v8a' : appAbiName(Abi.current());
  if (base == null || channel == null || abi == null) return null;
  final installed = int.tryParse((await PackageInfo.fromPlatform()).buildNumber);
  if (installed == null) return null;
  return AppUpdates(
    feed: RelayReleaseFeed(base, channel: channel, abi: abi, packages: !Platform.isIOS),
    files: CacheAppPackageFiles(),
    installer: ChannelAppInstaller(),
    memory: await FileAppUpdateMemory.open(File(path.join(support.path, 'app_update.json'))),
    installedVersionCode: installed,
    foreground: () => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    inBatch: rollouts.inUpdateBatch,
  );
}

// 灰度（人工决策见 domain/rollout.dart）：配置走同一个自建中转（没配中转时只用本机存着的，一般为空）；本机随机编号与上次的配置在 rollout.json。
// 分桶主体是当前应用账号的账号号，没登录用本机随机编号；渠道同应用更新（测试与没有渠道的构建记作 development）。
// 积分等级经挑战与积分的签名请求取（取不到时 Challenges 已记日志，这里按没取到算）。
Future<Rollouts> rolloutsOf(Directory support, AppAccounts? appAccounts, Challenges? challenges, {required bool Function() levelsOn}) async => Rollouts(
  memory: await FileRolloutMemory.open(File(path.join(support.path, 'rollout.json'))),
  channel: appFlavor ?? 'development',
  accountId: () => appAccounts?.accountId,
  levelsOn: levelsOn,
  level: switch (challenges) {
    final hub? => () async {
      try {
        return (await hub.points()).level;
      } on ChallengeException {
        return null;
      }
    },
    null => null,
  },
  feed: switch (relayBase()) {
    final base? => RelayRolloutFeed(base),
    null => null,
  },
);

// 解锁（人工决策见服务端 src/modules/unlock/unlock_rules.ts）：清单跟着灰度配置，这个账号能用哪些问同一个中转（应用账号签名）；没配中转时为空，游戏与工具都照常开着。
Unlocks? unlocksOf(Rollouts rollouts, AppAccounts? appAccounts, {required bool Function() accountOn}) {
  final transport = relayTransport();
  if (transport == null || appAccounts == null) return null;
  return Unlocks(rollouts: rollouts, appAccounts: appAccounts, client: RelayUnlockClient(vault: const SecureAppAccountVault(), transport: transport), accountOn: accountOn);
}

// 开发者的话走同一个自建中转；没配中转时为空，「我的」页不显示这一行。
Future<DeveloperNotes?> developerNotes(Directory support) async {
  final base = relayBase();
  if (base == null) return null;
  return DeveloperNotes(feed: RelayNoteFeed(base), memory: await FileDeveloperNoteMemory.open(File(path.join(support.path, 'developer_notes.json'))));
}

// 节日（人工决策见 domain/festival.dart）：登记在 page/festival/festival_catalog.dart；没配中转时只播动画、不抽签。
// 抽签用当前应用账号的设备密钥签名（social/relay_reward_client.dart）；没登录应用账号不抽，中转说账号已不在时让应用账号马上核一次。
// 登录应用账号后补抽在 app_lifecycle.dart 的 watchMoments 里接（同意协议与政策之后才联网）。
Future<Festivals> festivalsOf(Directory support, AppAccounts? appAccounts, {required bool Function() levelsOn}) async {
  final transport = relayTransport();
  return Festivals(
    occasions: [for (final scene in festivalCatalog) scene.occasion],
    memory: await FileFestivalMemory.open(File(path.join(support.path, 'festival.json'))),
    client: transport == null || appAccounts == null ? null : RelayRewardClient(vault: const SecureAppAccountVault(), transport: transport),
    account: () => appAccounts?.current,
    accountGone: () => unawaited(appAccounts?.check(force: true)),
    levelsOn: levelsOn,
  );
}

// 诊断包上传（人工决策见 domain/diagnostic_upload.dart）：没配中转时为空；配了就是包着中转上传的 AccountDiagnostics，登录着应用账号时传完认领到账号下，
// 账号页也经它看与删自己认领过的包。
AccountDiagnostics? diagnosticsOf(AppAccounts? Function() appAccounts) {
  final base = relayBase(), transport = relayTransport();
  if (base == null || transport == null) return null;
  return AccountDiagnostics(
    uploader: RelayDiagnosticUpload(base),
    client: RelayDiagnosticAccountClient(vault: const SecureAppAccountVault(), transport: transport),
    account: () => appAccounts()?.current,
    accountGone: () => unawaited(appAccounts()?.check(force: true)),
  );
}

// 应用账号（人工决策见 domain/app_account.dart）走同一个自建中转；没配中转时为空，账号页不显示那一组。
// 这台设备一把设备密钥，存在自己的安全存储命名空间（social/relay_app_account.dart），与私信身份互不关联。
AppAccounts? appAccountsOf({void Function(AppAccountRef account)? onDeleted}) {
  final transport = relayTransport();
  if (transport == null) return null;
  return AppAccounts(client: RelayAppAccountClient(vault: const SecureAppAccountVault(), transport: transport, deviceModel: readDeviceModel), onDeleted: onDeleted);
}

// 挑战与积分（人工决策见 playground/challenge/challenge_rules.dart）：同应用账号走自建中转，用那个应用账号的设备密钥签名；
// 没配中转时为空，游乐场不显示「挑战」。
Challenges? challengesOf(AppAccounts? appAccounts) {
  final transport = relayTransport();
  if (transport == null || appAccounts == null) return null;
  return Challenges(appAccounts: appAccounts, client: RelayChallengeClient(vault: const SecureAppAccountVault(), transport: transport));
}
