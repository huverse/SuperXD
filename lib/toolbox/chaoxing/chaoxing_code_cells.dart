import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/theme/campus_palette.dart';

// 签到码的格子输入，同学习通客户端：按位数显示空格、输满自动回调（校验与提交由调用方接手）。
// 输入本体是一个藏起来的数字键盘输入框，点格子即聚焦；调用方清空 controller 时格子跟着清空。
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

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _focus.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (widget.controller.text.length == widget.length) widget.onFilled();
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
          // 输入框本体藏在格子底下（高度 0、不可见），只负责收键盘输入。
          SizedBox(
            height: 0,
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(widget.length)],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var index = 0; index < widget.length; index++) ...[
                if (index > 0) const SizedBox(width: 10),
                Container(
                  width: 44,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: widget.error != null
                          ? palette.danger
                          : index == text.length
                          ? palette.accent
                          : palette.outline,
                      width: index == text.length ? 2 : 1,
                    ),
                  ),
                  child: Text(
                    index < text.length ? text[index] : '',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: palette.onSurface),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
