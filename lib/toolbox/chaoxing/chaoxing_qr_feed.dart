import 'dart:async';

import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_qrcode.dart';

// 连续扫码时的最新二维码：签到要新码时，有比过期那个新的就直接给，没有就等下一次扫到。
class ChaoxingQrFeed {
  ChaoxingQrCode? _latest;
  final _waiters = <Completer<ChaoxingQrCode>>[];
  bool _closed = false;

  // 最近扫到的码（不等待）：每个签到对象开始时都从这里取，老师换了码后面的人立刻用上新的。
  ChaoxingQrCode? get latest => _latest;

  void push(ChaoxingQrCode code) {
    if (_closed) return;
    _latest = code;
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.complete(code);
    }
    _waiters.clear();
  }

  // 返回一个与 expired 不同的码；取景页被关掉时以「已取消」结束。
  Future<ChaoxingQrCode> next(ChaoxingQrCode? expired) async {
    while (true) {
      final latest = _latest;
      if (latest != null && latest.enc != expired?.enc) return latest;
      if (_closed) throw const ChaoxingFailure(ChaoxingFailureCode.cancelled, chaoxingScanCancelledMessage);
      final waiter = Completer<ChaoxingQrCode>();
      _waiters.add(waiter);
      await waiter.future;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.completeError(const ChaoxingFailure(ChaoxingFailureCode.cancelled, chaoxingScanCancelledMessage));
    }
    _waiters.clear();
  }
}
