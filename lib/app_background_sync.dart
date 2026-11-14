import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:workmanager/workmanager.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/application/auto_sync.dart';
import 'package:superxd/device/diagnostic_device.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/gateway/account_gateway.dart';
import 'package:superxd/local/account_store.dart';
import 'package:superxd/local/credential_store.dart';
import 'package:superxd/local/diagnostic_log.dart';
import 'package:superxd/local/legal_notice_memory.dart';

// 自动同步的组合根接线（人工决策见 domain/auto_sync.dart）。系统后台任务每次都另起一份 Flutter 引擎跑 autoSyncDispatcher：
// 应用开着时（同一进程里有前台登记的端口）交给前台那份同步——用它已经开着的账号门面与教务会话，不让两份引擎同时动一个账号库、
// 抢同一个教务会话；应用不在时自己开账号库跑一轮，只用本机会话恢复，恢复不了就算了（不自动登录、不清活动账号、不打扰）。
// 任务的结果一律报成功：没同步成的由自动同步按间隔与网络规则下次再来，不交给系统的失败重试（除会话恢复的一次重放外不自动重试）。

const _portName = 'superxd_auto_sync';
// 前台收到后先回一声；这么久没回声说明登记的前台已经不在了。
const _ackWait = Duration(seconds: 5);

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
  try {
    // 记住了账号的，会话过期时照常用存着的密码重新登录一次再重放（用户 11-09 允许后台自动重登，隐私政策第一节写明）。
    await headlessAutoSync(deadline, support: support, openGateway: () async {
      final store = await AccountStore.open();
      _release = store.release;
      return AccountGateway(store: store, credentials: SecureCredentialStore());
    });
  } finally {
    _release = null;
    await logs.flush(settle: true);
  }
}

// 应用不在时那一轮里不碰平台的部分（拆出来让测试注入应用支持目录与账号门面）：没同意协议与政策不联网，只用本机会话恢复，
// 恢复不了就算了；到时限、系统叫停或前台登记了端口就在下一检查点停下；账号门面用完关掉。
@visibleForTesting
Future<void> headlessAutoSync(DateTime deadline, {required Directory support, required Future<AccountGateway> Function() openGateway}) async {
  final legal = await LegalNoticeMemory.open(File(path.join(support.path, 'legal_notice.json')));
  if (legal.agreedRevision == null) return;
  ensureCampusClock();
  final gateway = await openGateway();
  try {
    if (!(await gateway.restoreLocalSession()).ok) {
      campusLog('[AutoSync] action=background skipped=no_session');
      return;
    }
    await AutoSync(gateway: gateway, generation: () => gateway.generation).runIfDue(
      keepGoing: () => !_stopped && DateTime.now().isBefore(deadline) && IsolateNameServer.lookupPortByName(_portName) == null,
    );
  } finally {
    await gateway.close();
  }
}

// 前台登记：后台任务来了就在这里跑（到后台任务的时限为止），先回一声收到、跑完再回一声。热重启后旧登记可能还在，先撤再登。
// 返回重新登记的函数：前台卡过一阵、被后台任务当成不在而撤掉了登记时，回到前台再登一次。
@visibleForTesting
void Function() listenForBackgroundSync(AutoSync autoSync) {
  final port = ReceivePort();
  void register() {
    if (IsolateNameServer.lookupPortByName(_portName) == port.sendPort) return;
    IsolateNameServer.removePortNameMapping(_portName);
    IsolateNameServer.registerPortWithName(port.sendPort, _portName);
  }

  register();
  port.listen((message) {
    if (message case [final SendPort reply, final int deadline]) {
      reply.send(true);
      final until = DateTime.fromMillisecondsSinceEpoch(deadline);
      unawaited(autoSync.runIfDue(keepGoing: () => DateTime.now().isBefore(until)).catchError((Object error, StackTrace stack) {
        campusLog('[AutoSync] action=forwarded errorType=${error.runtimeType}\n$stack');
      }).whenComplete(() => reply.send(true)));
    }
  });
  return register;
}

// 自动同步的时机：同意协议与政策之后才开始（同意之前不联网）。启动、切换账号或退出时重读设置、排好或撤掉后台任务，
// 登录着的到期就补跑一轮；回到前台时也看一眼到没到期（iOS 的后台刷新由系统定时机，常常靠这里补上）。这些都是用户打开着应用（foreground）；
// 启动时只是读回本机会话，之后代次变了才是真的重新登录（relogin，清掉登录过期的暂停）。
void watchAutoSync(AppSession session, AutoSync autoSync, {required Future<void> agreed}) {
  void report(Object error, StackTrace stack) => campusLog('[AutoSync] action=watch errorType=${error.runtimeType}\n$stack');
  Future<void> changed({required bool relogin}) async {
    await autoSync.accountChanged(signedIn: session.loggedIn, relogin: relogin);
    if (session.loggedIn) await autoSync.runIfDue(foreground: true);
  }

  unawaited(agreed.then((_) {
    final register = listenForBackgroundSync(autoSync);
    var generation = session.generation, loggedIn = session.loggedIn;
    session.addListener(() {
      if (session.generation == generation && session.loggedIn == loggedIn) return;
      generation = session.generation;
      loggedIn = session.loggedIn;
      unawaited(changed(relogin: true).catchError(report));
    });
    AppLifecycleListener(onResume: () {
      register();
      if (session.loggedIn) unawaited(autoSync.runIfDue(foreground: true).catchError(report));
    });
    return changed(relogin: false);
  }).catchError(report));
}
