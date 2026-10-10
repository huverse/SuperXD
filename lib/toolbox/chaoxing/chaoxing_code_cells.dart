import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/theme/campus_palette.dart';

// 签到码的格子输入，同学习通客户端：按位数显示空格、输满自动回调（校验与提交由调用方接手）。
// 输入本体是一个藏起来的数字键盘输入框，点格子即聚焦；调用方清空 controller 时格子跟着清空。
// [人工决策-2026-10-09 20:32:45] 输错时格子标红并轻震一下，红色保留到重新输入第一位（同 Android 锁屏）；不加位移动画。用户选定。
class ChaoxingCodeCells extends StatefulWidget {
  const ChaoxingCodeCells({super.key, required this.controller, required this.length, required this.onFilled, this.error});
  final TextEditingController controller;
  final int length;
  final VoidCallback onFilled;
  final String? error;

  @override
  State<ChaoxingCodeCells> createState() => _ChaoxingCodeCellsState();
}

class _ChaoxingCodeCellsState extends State<ChaoxingCodeCells> {
  final _focus = FocusNode();

  // 上一次通知时的文本：controller 改光标位置也会通知，只有文本从不满变满才算输完，免得重复提交。
  // 必须在 initState 里取：懒初始化会拖到第一次通知时才取值，取到的已是新文本，第一位数字就不重画。
  late String _lastText;

  // 输错的红色是否还亮着：调用方给出错误时亮起，重新输入第一位时熄灭（不等调用方下一次校验）。
  late bool _showError = widget.error != null;

  // 每格最宽 44、格间 10；位数由学习通下发，没有上限，窄屏放不下时按可用宽度等比收窄。
  static const _cellWidth = 44.0;
  static const _cellGap = 10.0;

  @override
  void initState() {
    super.initState();
    _lastText = widget.controller.text;
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(ChaoxingCodeCells oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.error != null && oldWidget.error == null) {
      _showError = true;
      HapticFeedback.heavyImpact();
    }
    if (widget.error == null) _showError = false;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _focus.dispose();
    super.dispose();
  }

  void _onChanged() {
    final text = widget.controller.text;
    final filled = text.length == widget.length && _lastText.length != widget.length;
    final changed = text != _lastText;
    _lastText = text;
    // 输入框藏在格子底下，格子里的数字要跟着文本重画；重新输入第一位时熄掉输错的红色。
    if (changed) setState(() => _showError = _showError && text.isEmpty);
    if (filled) widget.onFilled();
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final text = widget.controller.text;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        _focus.requestFocus();
        // 点格子时把光标放到末尾，避免插入到中间。
        widget.controller.selection = TextSelection.collapsed(offset: widget.controller.text.length);
      },
      child: Stack(
        children: [
          // 输入框本体藏在格子底下（透明、无边框无光标），只负责收键盘输入；数字由格子画。
          // 只设高度 0 藏不住：TextField 会溢出画出文字、下划线与光标，叠在格子上方。
          Positioned.fill(
            child: Opacity(
              opacity: 0,
              child: TextField(
                controller: widget.controller,
                focusNode: _focus,
                keyboardType: TextInputType.number,
                showCursor: false,
                enableInteractiveSelection: false,
                decoration: const InputDecoration.collapsed(hintText: ''),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(widget.length)],
              ),
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final scale = (constraints.maxWidth / (widget.length * _cellWidth + (widget.length - 1) * _cellGap)).clamp(0.0, 1.0);
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var index = 0; index < widget.length; index++) ...[
                    if (index > 0) SizedBox(width: _cellGap * scale),
                    Container(
                      width: _cellWidth * scale,
                      height: 52,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _showError
                              ? palette.danger
                              : index == text.length
                              ? palette.accent
                              : palette.outline,
                          width: !_showError && index == text.length ? 2 : 1,
                        ),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          index < text.length ? text[index] : '',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: palette.onSurface),
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
