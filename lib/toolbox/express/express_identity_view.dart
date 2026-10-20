import 'dart:async';

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/toolbox/express/express_models.dart';

enum _IdentityStyle { barcode, qr }

// 身份码展示：Code128 条码与二维码两种样式（值都是同一串服务端下发的 identification_code），
// 按剩余有效期倒计时，到期回调 onRefresh；不缓存、不打印身份码。
// [人工决策-2026-10-19 23:35:59] 本轮不给身份码页加截屏/录屏保护（FLAG_SECURE）：只做不落盘、不打印与「请勿分享」提示；
// 用户选定本轮不加（FLAG_SECURE 需改原生 MainActivity 做按页开关，属额外工程）。
class ExpressIdentityView extends StatefulWidget {
  const ExpressIdentityView({super.key, required this.result, required this.onRefresh, this.refreshing = false});
  final IdentityCodeResult result;

  // 到期或点「立即刷新」时回调（由上层重新请求身份码）。
  final Future<void> Function() onRefresh;
  final bool refreshing;

  @override
  State<ExpressIdentityView> createState() => _ExpressIdentityViewState();
}

class _ExpressIdentityViewState extends State<ExpressIdentityView> {
  _IdentityStyle _style = _IdentityStyle.barcode;
  late int _remainingSeconds;
  Timer? _ticker;
  bool _expiredNotified = false;

  @override
  void initState() {
    super.initState();
    _resetCountdown();
  }

  @override
  void didUpdateWidget(covariant ExpressIdentityView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result.identificationCode != widget.result.identificationCode ||
        oldWidget.result.expireMills != widget.result.expireMills) {
      _resetCountdown();
    }
  }

  void _resetCountdown() {
    _ticker?.cancel();
    _expiredNotified = false;
    final seconds = (widget.result.expireMills / 1000).floor();
    _remainingSeconds = seconds < 0 ? 0 : seconds;
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        if (_remainingSeconds > 0) _remainingSeconds--;
      });
      if (_remainingSeconds <= 0 && !_expiredNotified) {
        _expiredNotified = true;
        timer.cancel();
        widget.onRefresh();
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final code = widget.result.identificationCode;
    final mobileDesc = widget.result.mobileInfo?.desc ?? '';
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CampusSegmented<_IdentityStyle>(
          values: const [_IdentityStyle.barcode, _IdentityStyle.qr],
          selected: _style,
          label: (value) => value == _IdentityStyle.barcode ? '条码' : '二维码',
          onSelected: (value) => setState(() => _style = value),
        ),
        const SizedBox(height: 16),
        // 条码与二维码固定黑白：取件高拍仪要扫，底色与前景必须高对比，不随主题配色变。
        Center(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: _buildCode(code),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: SelectableText(
            code,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        if (mobileDesc.isNotEmpty) ...[
          const SizedBox(height: 8),
          Center(child: Text(mobileDesc, style: textTheme.bodyMedium?.copyWith(color: palette.onSurfaceVariant))),
        ],
        const SizedBox(height: 8),
        Center(
          child: Text(
            widget.refreshing ? '正在刷新身份码' : '有效期剩余 $_remainingSeconds 秒',
            style: textTheme.bodyMedium?.copyWith(color: palette.attention),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            '为避免快递丢失，请勿随意分享身份码',
            style: textTheme.bodyMedium?.copyWith(color: palette.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _buildCode(String code) {
    if (_style == _IdentityStyle.qr) {
      return SizedBox(
        width: 220,
        height: 220,
        child: PrettyQrView.data(
          data: code,
          decoration: const PrettyQrDecoration(
            shape: PrettyQrSmoothSymbol(color: Colors.black, roundFactor: 0),
            background: Colors.white,
          ),
        ),
      );
    }
    return BarcodeWidget(
      barcode: Barcode.code128(),
      data: code,
      width: 260,
      height: 120,
      drawText: false,
      color: Colors.black,
      backgroundColor: Colors.white,
    );
  }
}
