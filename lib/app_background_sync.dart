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
// 等前台跑完的上限，留在 WorkManager 单次 10 分钟的执行上限之内。
const _runWait = Duration(minutes: 8);

@pragma('vm:entry-point')
void autoSyncDispatcher() {
  Workmanager().executeTask((task, input) async {
    campusLog = debugPrint;
    try {
      if (!await _forward()) await _runHeadless();
    } catch (error, stack) {
      campusLog('[AutoSync] action=background errorType=${error.runtimeType}\n$stack');
    }
    return true;
  });
}

// 交给前台那份跑，等它跑完；返回交没交出去。
Future<bool> _forward() async {
  final app = IsolateNameServer.lookupPortByName(_portName);
  if (app == null) return false;
  final reply = ReceivePort();
  final replies = StreamIterator<Object?>(reply);
  try {
    app.send(reply.sendPort);
    if (!await replies.moveNext().timeout(_ackWait, onTimeout: () => false)) {
      // 登记还在、前台已经没了：撤掉过期的登记，自己跑。
      IsolateNameServer.removePortNameMapping(_portName);
      return false;
    }
    await replies.moveNext().timeout(_runWait, onTimeout: () => false);
    campusLog('[AutoSync] action=background forwarded=true');
    return true;
  } finally {
    await replies.cancel();
    reply.close();
  }
}

// 应用不在时自己跑一轮：路径与前台一致（iOS 的库在应用支持目录），没同意协议与政策时不联网；错误照样进本机错误记录。
Future<void> _runHeadless() async {
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
    final legal = await LegalNoticeMemory.open(File(path.join(support.path, 'legal_notice.json')));
    if (legal.agreedRevision == null) return;
    ensureCampusClock();
    final gateway = AccountGateway(store: await AccountStore.open(), credentials: SecureCredentialStore());
    try {
      if (!(await gateway.restoreLocalSession()).ok) {
        campusLog('[AutoSync] action=background skipped=no_session');
        return;
      }
      await AutoSync(gateway: gateway).runIfDue();
    } finally {
      await gateway.close();
    }
  } finally {
    await logs.flush(settle: true);
  }
}

// 前台登记：后台任务来了就在这里跑，先回一声收到、跑完再回一声。热重启后旧登记可能还在，先撤再登。
void _listenForBackgroundSync(AutoSync autoSync) {
  final port = ReceivePort();
  IsolateNameServer.removePortNameMapping(_portName);
  IsolateNameServer.registerPortWithName(port.sendPort, _portName);
  port.listen((message) {
    if (message is! SendPort) return;
    message.send(true);
    unawaited(autoSync.runIfDue().catchError((Object error, StackTrace stack) {
      campusLog('[AutoSync] action=forwarded errorType=${error.runtimeType}\n$stack');
    }).whenComplete(() => message.send(true)));
  });
}

// 自动同步的时机：同意协议与政策之后才开始（同意之前不联网）。恢复会话、切换账号或退出时重读设置、排好或撤掉后台任务，
// 登录着的到期就补跑一轮；回到前台时也看一眼到没到期（iOS 的后台刷新由系统定时机，常常靠这里补上）。
void watchAutoSync(AppSession session, AutoSync autoSync, {required Future<void> agreed}) {
  void report(Object error, StackTrace stack) => campusLog('[AutoSync] action=watch errorType=${error.runtimeType}\n$stack');
  Future<void> changed() async {
    await autoSync.accountChanged(signedIn: session.loggedIn);
    if (session.loggedIn) await autoSync.runIfDue();
  }

  unawaited(agreed.then((_) {
    _listenForBackgroundSync(autoSync);
    var generation = session.generation, loggedIn = session.loggedIn;
    session.addListener(() {
      if (session.generation == generation && session.loggedIn == loggedIn) return;
      generation = session.generation;
      loggedIn = session.loggedIn;
      unawaited(changed().catchError(report));
    });
    AppLifecycleListener(onResume: () {
      if (session.loggedIn) unawaited(autoSync.runIfDue().catchError(report));
    });
    return changed();
  }).catchError(report));
}
