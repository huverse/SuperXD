import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:workmanager/workmanager.dart';

import 'package:superxd/app_lifecycle.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/application/auto_sync.dart';
import 'package:superxd/device/diagnostic_device.dart';
import 'package:superxd/device/sync_notifications.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/network_policy.dart';
import 'package:superxd/gateway/account_gateway.dart';
import 'package:superxd/local/account_store.dart';
import 'package:superxd/local/credential_store.dart';
import 'package:superxd/local/diagnostic_log.dart';
import 'package:superxd/local/legal_notice_memory.dart';

// 自动同步的组合根接线（人工决策见 domain/auto_sync.dart）。系统后台任务每次都另起一份 Flutter 引擎跑 autoSyncDispatcher：
// 应用开着时（同一进程里有前台登记的端口）交给前台那份同步——用它已经开着的账号门面与教务会话，不让两份引擎同时动一个账号库、
// 抢同一个教务会话；应用不在时自己开账号库跑一轮，只用本机会话恢复，恢复不了就算了（不自动登录、不清活动账号、不打扰）。
// 任务的结果一律报成功：没同步成的由自动同步按间隔与网络规则下次再来，不交给系统的失败重试（除会话恢复的一次重放外不自动重试）。
//
// [人工决策-2026-11-19 12:48:20] 同一进程里同一时刻只让一份引擎用账号库（用户选「保留后台，修并发」）：11-19 早上用户打开应用课表、成绩一直在读取，
// 模拟器上复现为永久卡死——后台任务那份与前台各开一条连接连同一个库，sqflite 整个进程只有一条原生工作线程，一边拿着写锁等下一句、另一边在同一条线程上等锁，
// 谁也走不了。做法：前台启动一开始、开账号库之前就登记（claimAccountStore），后台任务来了一律交给前台（前台还没准备好就这次不跑），前台在时后台那份不开库；
// 后台那份自己跑着时用户打开了应用，前台先让它停下、关好账号库（在途的教务请求当场中断，HeadlessClaim）再开库。

const _portName = 'superxd_auto_sync';
// 后台那份自己跑一轮期间登记的端口：前台起来时经它要回账号库。
const _headlessName = 'superxd_auto_sync_headless';
// 前台收到后先回一声；这么久没回声说明登记的前台已经不在了。
const _ackWait = Duration(seconds: 5);
// 前台等后台那份停下、关好账号库的时间：中断在途请求、回滚没提交的事务都是毫秒级；等不到（那份引擎已经没了、登记还在）就照常开库。
const _releaseWait = Duration(seconds: 5);

// 系统给一次后台任务的时间：iOS 的后台刷新大约 30 秒（超时系统会终止应用、以后少给机会），安卓 WorkManager 单次 10 分钟；都留出收尾的余量。
// 到点了这一轮在下一检查点停下（同步按检查点逐项来，停下的部分下次再同步），交给前台跑时同样按它等、也按它停。
Duration get _budget => Platform.isIOS ? const Duration(seconds: 25) : const Duration(minutes: 8);

// 安卓系统把正在跑的任务叫停（取消、超时、被抢占）：这一轮在下一检查点停下。
var _stopped = false;
Future<void>? _headless;
// 这份引擎自己开的账号库连接：叫停后等不到检查点就直接收回（人工决策见 local/account_store.dart 的 release）。
Future<void> Function()? _release;
// 叫停后等这一轮自己停在检查点、关好账号库的时间；等不到（教务请求还在路上，最长 25 秒）就收回连接再交还引擎。
const _stopGrace = Duration(seconds: 3);

@pragma('vm:entry-point')
void autoSyncDispatcher() {
  Workmanager().executeTask(
    (task, input) async {
      campusLog = debugPrint;
      _stopped = false;
      final deadline = DateTime.now().add(_budget);
      try {
        if (!await forwardAutoSync(deadline)) await (_headless = _runHeadless(deadline));
      } catch (error, stack) {
        // 叫停后收回了连接，这一轮再碰库报的「已关闭」是正常停下，不进错误记录。
        if (_stopped) {
          campusLog('[AutoSync] action=background result=stopped after=${error.runtimeType}');
        } else {
          campusLog('[AutoSync] action=background errorType=${error.runtimeType}\n$stack');
        }
      } finally {
        _headless = null;
      }
      return true;
    },
    // 回调一完成插件就销毁这份引擎（插件等这个回调做完）：先等这一轮停在检查点、关好账号库；等不到就收回连接（进行中的事务回滚）再返回，
    // 引擎销毁时这份引擎开的连接一条不留。
    onTaskStopped: (task, reason) async {
      _stopped = true;
      campusLog('[AutoSync] action=background stopped=${reason.name}');
      final headless = _headless;
      if (headless == null) return;
      await stopHeadless(headless, _release ?? () async {});
    },
  );
}

// 叫停后的收尾（拆出来给测试）：这一轮 grace 内停下就算了，否则收回连接。返回是不是收回的。
@visibleForTesting
Future<bool> stopHeadless(Future<void> headless, Future<void> Function() release, {Duration grace = _stopGrace}) async {
  final settled = await headless.then((_) => true, onError: (Object _) => true).timeout(grace, onTimeout: () => false);
  if (settled) return false;
  try {
    await release();
    campusLog('[AutoSync] action=background released=true');
  } catch (error, stack) {
    campusLog('[AutoSync] action=release errorType=${error.runtimeType}\n$stack');
  }
  return true;
}

// 交给前台那份跑，等它跑完；返回交没交出去。ackWait 只有测试改短。
@visibleForTesting
Future<bool> forwardAutoSync(DateTime deadline, {Duration ackWait = _ackWait}) async {
  final app = IsolateNameServer.lookupPortByName(_portName);
  if (app == null) return false;
  final reply = ReceivePort();
  final replies = StreamIterator<Object?>(reply);
  try {
    app.send([reply.sendPort, deadline.millisecondsSinceEpoch]);
    if (!await replies.moveNext().timeout(ackWait, onTimeout: () => false)) {
      // 登记还在、前台已经没了：撤掉过期的登记（只撤这一个，期间前台重新登记的不动），自己跑。
      if (IsolateNameServer.lookupPortByName(_portName) == app) IsolateNameServer.removePortNameMapping(_portName);
      return false;
    }
    // 前台在、还没准备好（没同意协议与政策、自动同步还没接上）：这一轮不跑，也不自己开账号库，前台准备好后按到期补跑。
    if (replies.current != true) {
      campusLog('[AutoSync] action=background skipped=foreground_not_ready');
      return true;
    }
    await replies.moveNext().timeout(deadline.difference(DateTime.now()), onTimeout: () => false);
    campusLog('[AutoSync] action=background forwarded=true');
    return true;
  } finally {
    await replies.cancel();
    reply.close();
  }
}

// 应用不在时自己跑一轮：路径与前台一致（iOS 的库在应用支持目录），没同意协议与政策时不联网；错误照样进本机错误记录。
// 跑着跑着用户打开了应用（前台登记了端口）就在下一检查点让给前台，不让两份引擎同时动一个账号库、抢同一个教务会话。
Future<void> _runHeadless(DateTime deadline) async {
  final support = await getApplicationSupportDirectory();
  if (Platform.isIOS) await databaseFactory.setDatabasesPath(path.join(support.path, 'databases'));
  final external = Platform.isAndroid ? await getExternalStorageDirectory() : null;
  final logs = await DiagnosticLog.open(
    directory: Directory(path.join((external ?? (Platform.isIOS ? Directory(path.join(support.path, 'device_only')) : support)).path, 'logs')),
    exports: Directory(path.join((await getTemporaryDirectory()).path, 'diagnostics_export')),
    publish: publishDiagnosticArchive,
  );
  campusLog = logs.tee(debugPrint);
  final claim = HeadlessClaim();
  try {
    // 记住了账号的，会话过期时照常用存着的密码重新登录一次再重放（用户 11-09 允许后台自动重登，隐私政策第二节写明）。
    await headlessAutoSync(deadline, support: support, claim: claim, openGateway: () async {
      final store = await AccountStore.open();
      _release = store.release;
      return AccountGateway(store: store, credentials: SecureCredentialStore());
    });
  } finally {
    claim.close();
    _release = null;
    await logs.flush(settle: true);
  }
}

// 应用不在时那一轮里不碰平台的部分（拆出来让测试注入应用支持目录与账号门面）：没同意协议与政策不联网，只用本机会话恢复，
// 恢复不了就算了；前台此刻已经在了就不开库（交给前台时它还没登记）；到时限、系统叫停、前台登记了端口或要回了账号库就在下一检查点停下；账号门面用完关掉。
@visibleForTesting
Future<void> headlessAutoSync(DateTime deadline, {required Directory support, required Future<AccountGateway> Function() openGateway, HeadlessClaim? claim}) async {
  final legal = await LegalNoticeMemory.open(File(path.join(support.path, 'legal_notice.json')));
  if (legal.agreedRevision == null) return;
  ensureCampusClock();
  if (IsolateNameServer.lookupPortByName(_portName) != null) {
    campusLog('[AutoSync] action=background skipped=foreground');
    return;
  }
  final gateway = claim == null ? await openGateway() : await claim.open(openGateway);
  if (gateway == null) {
    campusLog('[AutoSync] action=background skipped=handed_over');
    return;
  }
  try {
    if (!(await gateway.restoreLocalSession()).ok) {
      campusLog('[AutoSync] action=background skipped=no_session');
      return;
    }
    // 后台这份引擎里也发同步结果通知（插件在后台引擎里同样注册），点开进同步记录。
    await AutoSync(gateway: gateway, generation: () => gateway.generation, notices: SyncNotifications()).runIfDue(
      keepGoing: () => !_stopped && !(claim?.released ?? false) && DateTime.now().isBefore(deadline) && IsolateNameServer.lookupPortByName(_portName) == null,
    );
  } finally {
    await gateway.close();
  }
}

// 后台那份自己跑一轮期间登记的端口（人工决策见文件头 11-19 那条）：前台起来时发来回话端口，这里马上关掉账号门面
// （在途的教务请求当场中断、没提交的事务回滚）再回话；要回去以后不再开库，开到一半的开完马上关。同一时刻只有一份后台任务（WorkManager 的唯一任务）。
@visibleForTesting
class HeadlessClaim {
  HeadlessClaim() {
    IsolateNameServer.removePortNameMapping(_headlessName);
    IsolateNameServer.registerPortWithName(_port.sendPort, _headlessName);
    _port.listen((message) {
      if (message is SendPort) unawaited(_handOver(message));
    });
  }

  final _port = ReceivePort();
  bool _released = false;
  Future<AccountGateway?>? _opening;

  // 前台要回了账号库：这一轮在下一检查点停下。
  bool get released => _released;

  Future<AccountGateway?> open(Future<AccountGateway> Function() opener) {
    if (_released) return Future.value(null);
    return _opening = opener().then((gateway) async {
      if (!_released) return gateway;
      await gateway.close();
      return null;
    });
  }

  Future<void> _handOver(SendPort reply) async {
    _released = true;
    try {
      await (await _opening)?.close();
    } catch (error, stack) {
      campusLog('[AutoSync] action=hand_over errorType=${error.runtimeType}\n$stack');
    } finally {
      campusLog('[AutoSync] action=background handed_over=true');
      reply.send(true);
    }
  }

  void close() {
    if (IsolateNameServer.lookupPortByName(_headlessName) == _port.sendPort) IsolateNameServer.removePortNameMapping(_headlessName);
    _port.close();
  }
}

// 前台启动一开始、开账号库之前调（人工决策见文件头 11-19 那条）：登记前台的端口，再让正在后台自己跑的那一轮停下、关好账号库，
// 回话了（或等不到：那份引擎已经没了、登记还在，撤掉这条登记）才返回。
Future<ForegroundSync> claimAccountStore({Duration releaseWait = _releaseWait}) async {
  final foreground = ForegroundSync._();
  final headless = IsolateNameServer.lookupPortByName(_headlessName);
  if (headless == null) return foreground;
  final reply = ReceivePort();
  try {
    headless.send(reply.sendPort);
    final handed = await reply.first.timeout(releaseWait, onTimeout: () => false);
    campusLog('[AutoSync] action=claim handed_over=$handed');
    if (handed != true && IsolateNameServer.lookupPortByName(_headlessName) == headless) IsolateNameServer.removePortNameMapping(_headlessName);
  } finally {
    reply.close();
  }
  return foreground;
}

// 前台的登记：后台任务来了交给前台跑（到后台任务的时限为止），先回一声收到、跑完再回一声；同意协议与政策、自动同步接上之前回「这次不跑」。
class ForegroundSync {
  ForegroundSync._() {
    register();
    _port.listen(_receive);
  }

  final _port = ReceivePort();
  AutoSync? _autoSync;

  void attach(AutoSync autoSync) => _autoSync = autoSync;

  // 前台卡过一阵、被后台任务当成不在而撤掉了登记时，回到前台再登一次。热重启后旧登记可能还在，先撤再登。
  void register() {
    if (IsolateNameServer.lookupPortByName(_portName) == _port.sendPort) return;
    IsolateNameServer.removePortNameMapping(_portName);
    IsolateNameServer.registerPortWithName(_port.sendPort, _portName);
  }

  void _receive(Object? message) {
    if (message case [final SendPort reply, final int deadline]) {
      final autoSync = _autoSync;
      if (autoSync == null) {
        reply.send(false);
        return;
      }
      reply.send(true);
      final until = DateTime.fromMillisecondsSinceEpoch(deadline);
      unawaited(autoSync.runIfDue(keepGoing: () => DateTime.now().isBefore(until)).catchError((Object error, StackTrace stack) {
        campusLog('[AutoSync] action=forwarded errorType=${error.runtimeType}\n$stack');
      }).whenComplete(() => reply.send(true)));
    }
  }
}

// 自动同步的时机：同意协议与政策之后才开始（同意之前不联网）。启动、切换账号或退出时重读设置、排好或撤掉后台任务，
// 登录着的到期就补跑一轮；回到前台时也看一眼到没到期（iOS 的后台刷新由系统定时机，常常靠这里补上）。这些都是用户打开着应用（foreground）；
// 启动时只是读回本机会话，之后代次变了才是真的重新登录（relogin，清掉登录过期的暂停）。
void watchAutoSync(AppSession session, AutoSync autoSync, AppHooks hooks, ForegroundSync foreground) {
  Future<void> changed({required bool relogin}) async {
    await autoSync.accountChanged(signedIn: session.loggedIn, relogin: relogin);
    if (session.loggedIn) await autoSync.runIfDue(foreground: true);
  }

  hooks.afterAgreed('AutoSync', () {
    foreground.attach(autoSync);
    var generation = session.generation, loggedIn = session.loggedIn;
    session.addListener(() {
      if (session.generation == generation && session.loggedIn == loggedIn) return;
      generation = session.generation;
      loggedIn = session.loggedIn;
      unawaited(changed(relogin: true).catchError((Object error, StackTrace stack) => campusLog('[AutoSync] action=watch errorType=${error.runtimeType}\n$stack')));
    });
    hooks.onResume('AutoSync', () {
      foreground.register();
      if (session.loggedIn) return autoSync.runIfDue(foreground: true);
    }, service: NetworkService.eduAuto);
    return changed(relogin: false);
  }, service: NetworkService.eduAuto);
}
