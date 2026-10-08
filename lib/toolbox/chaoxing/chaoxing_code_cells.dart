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

  // 上一次通知时的文本：controller 改光标位置也会通知，只有文本从不满变满才算输完，免得重复提交。
  late String _lastText = widget.controller.text;

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
    final text = widget.controller.text;
    final filled = text.length == widget.length && _lastText.length != widget.length;
    final changed = text != _lastText;
    _lastText = text;
    // 输入框藏在格子底下，格子里的数字要跟着文本重画。
    if (changed) setState(() {});
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
