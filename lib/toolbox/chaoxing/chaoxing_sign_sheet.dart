import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_batch.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_captcha_dialog.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_face_sheet.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_map_page.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_qrcode.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_settings_sheet.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 发布超过这么久还没截止的签到，提醒确认没选错（与学习通客户端同一口径）。
const chaoxingStaleActivityAge = Duration(hours: 6);

// 签到结果：成功了几个人、有没有迟到的；关弹层时页面按这个给提示。
class ChaoxingSignSummary {
  const ChaoxingSignSummary({required this.succeeded, required this.late});
  final int succeeded;
  final bool late;
}

// 签到弹层：先取活动详情，再按类型要输入；下面是签到对象（本人与导入的代签账号，可多选），
// 每个人的状态在原位显示，失败的可以单独重试、强制签到或重新登录。全部成功后随结果一起关掉。
// 需要滑块验证码时就地弹验证，过了自动把这个人的签到重发一遍。
Future<ChaoxingSignSummary?> showChaoxingSignSheet(
  BuildContext context, {
  required ChaoxingController controller,
  required ChaoxingActivity activity,
  ToolboxQrScan? scanQrCode,
  ToolboxQrWatch? watchQrCode,
}) => showCampusSheet<ChaoxingSignSummary>(
  context: context,
  builder: (context) => _ChaoxingSignSheet(
    controller: controller,
    activity: activity,
    scanQrCode: scanQrCode,
    watchQrCode: watchQrCode,
  ),
);

class _ChaoxingSignSheet extends StatefulWidget {
  const _ChaoxingSignSheet({required this.controller, required this.activity, this.scanQrCode, this.watchQrCode});
  final ChaoxingController controller;
  final ChaoxingActivity activity;
  final ToolboxQrScan? scanQrCode;
  final ToolboxQrWatch? watchQrCode;
  @override
  State<_ChaoxingSignSheet> createState() => _ChaoxingSignSheetState();
}

class _ChaoxingSignSheetState extends State<_ChaoxingSignSheet> {
  final _code = TextEditingController();
  final _latitude = TextEditingController();
  final _longitude = TextEditingController();
  final _address = TextEditingController();
  late ChaoxingActivity _activity = widget.activity;
  late final _batch = ChaoxingBatchSigning(widget.controller.signTargets());
  ChaoxingActiveInfo? _info;
  String? _loadError;
  String? _error;
  bool _preparing = false;
  bool _loadingRelated = false;
  bool _manualLocation = false;
  ChaoxingLocation? _savedLocation;
  _QrFeed? _feed;

  ChaoxingSignType get _type => _activity.signType;
  bool get _needsLocation => _type == ChaoxingSignType.location || (_info?.needLocation ?? false);
  bool get _needsPhoto => _type == ChaoxingSignType.photo && (_info?.needPhoto ?? false);
  bool get _needsFace => _info != null && chaoxingFaceApplies(_type, _info!);
  bool get _needsCode => _type == ChaoxingSignType.password || _type == ChaoxingSignType.gesture;
  bool get _multi => _batch.targets.length > 1;
  bool get _busy => _preparing || _loadingRelated || _batch.running;

  @override
  void initState() {
    super.initState();
    _batch.addListener(_onBatch);
    _load();
  }

  @override
  void dispose() {
    _batch
      ..removeListener(_onBatch)
      ..dispose();
    _feed?.close();
    _code.dispose();
    _latitude.dispose();
    _longitude.dispose();
    _address.dispose();
    super.dispose();
  }

  void _onBatch() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final info = await widget.controller.activeInfo(_activity);
      if (!mounted) return;
      setState(() {
        _info = info;
        _loadError = null;
        // 地图用不了时直接摊开经纬度，别让人先去点一下「手动输入」。
        _manualLocation = !chaoxingMapAvailable || widget.controller.locations.isEmpty;
        final saved = widget.controller.locations;
        if (saved.isNotEmpty) _savedLocation = saved.first.location;
        if (info.locationLatitude != null && info.locationLongitude != null && _manualLocation) {
          _latitude.text = info.locationLatitude!.toStringAsFixed(6);
          _longitude.text = info.locationLongitude!.toStringAsFixed(6);
        }
      });
    } on ChaoxingFailure catch (failure) {
      if (mounted) setState(() => _loadError = failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=active_info errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _loadError = '活动详情没读到，请稍后重试');
    }
  }

  ChaoxingLocation? _currentLocation() {
    if (!_needsLocation) return null;
    if (!_manualLocation && _savedLocation != null) return _savedLocation;
    final latitude = double.tryParse(_latitude.text.trim());
    final longitude = double.tryParse(_longitude.text.trim());
    if (latitude == null || longitude == null) return null;
    return ChaoxingLocation(
      latitude: latitude,
      longitude: longitude,
      address: _address.text.trim().isEmpty ? '自定义位置' : _address.text.trim(),
      // 手输的按高德坐标系算，和地图选点一致；提交前会统一换算成学习通要的口径。
      system: ChaoxingCoordinateSystem.gcj02,
    );
  }

  Future<void> _pickOnMap() async {
    final picked = await openChaoxingMapPicker(
      context,
      initial: _currentLocation() ?? (_manualLocation ? null : _savedLocation),
      label: _savedLocation?.address,
    );
    if (!mounted || picked == null) return;
    await widget.controller.saveLocation(picked.address, picked);
    if (!mounted) return;
    setState(() {
      _savedLocation = picked;
      _manualLocation = false;
      _error = null;
    });
  }

  // 拍照签到每人一张照片（上传前各自随机裁剪旋转）。
  Future<void> _pickPhoto(ChaoxingSignTarget target) async {
    try {
      final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1920, maxHeight: 1920, imageQuality: 95);
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        target
          ..photoBytes = bytes
          ..photoName = file.name
          ..photoObjectId = null;
        _error = null;
      });
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=photo errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '照片读取失败，请重新选择');
    }
  }

  // 人脸照片：默认用这个人存着的那张，也可以这次另选一张。
  Future<void> _pickFace(ChaoxingSignTarget target) async {
    final objectId = await showChaoxingFaceSheet(context, controller: widget.controller, record: target.record, pick: true);
    if (!mounted || objectId == null) return;
    setState(() => target.faceObjectId = objectId);
  }

  // 从主签到跳到它关联的签退活动，或从签退活动回到主签到；换活动后详情要重新取。
  Future<void> _openRelated(int activeId) async {
    if (_busy) return;
    setState(() {
      _loadingRelated = true;
      _error = null;
    });
    try {
      final related = await widget.controller.relatedActivity(_activity, activeId);
      if (!mounted) return;
      setState(() {
        _activity = related;
        _info = null;
        _loadError = null;
        for (final target in _batch.targets) {
          target
            ..state = ChaoxingTargetState.idle
            ..message = null
            ..photoBytes = null
            ..photoName = null
            ..photoObjectId = null
            ..faceObjectId = null;
        }
        _code.clear();
      });
      await _load();
    } on ChaoxingFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=related errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '这个活动没打开，请稍后重试');
    } finally {
      if (mounted) setState(() => _loadingRelated = false);
    }
  }

  Future<void> _saveLocation() async {
    final location = _currentLocation();
    if (location == null) {
      setState(() => _error = '请先填写纬度与经度');
      return;
    }
    await widget.controller.saveLocation(location.address, location);
    if (mounted) setState(() => _error = null);
  }

  Future<String?> _solveCaptcha(ChaoxingClient client, ChaoxingActivity activity) async {
    final answer = await showChaoxingCaptchaDialog(
      context,
      load: () => widget.controller.captchaPuzzle(client, activity),
      loadImage: (url) => widget.controller.captchaImage(client, url),
      verify: (puzzle, position) => widget.controller.solveCaptcha(client, activity, puzzle, position),
    );
    _batch.lastNeededCaptcha = true;
    return answer;
  }

  ChaoxingTargetSigner _signer(ChaoxingSignInputs inputs, {ChaoxingFreshQrCode? freshQrCode}) =>
      (target, {required force}) => widget.controller.signTarget(
        target,
        _activity,
        info: _info!,
        inputs: inputs,
        solveCaptcha: _solveCaptcha,
        freshQrCode: freshQrCode,
        force: force,
      );

  // 开签前把所有人共用的输入与每个人的照片都核对一遍，缺什么原地提示。
  ChaoxingSignInputs? _inputs() {
    final location = _currentLocation();
    if (_needsLocation && location == null) {
      setState(() => _error = '这场签到要位置，请选一个位置或填写坐标');
      return null;
    }
    final signCode = _needsCode ? _code.text.trim() : null;
    if (_needsCode && signCode!.isEmpty) {
      setState(() => _error = _type == ChaoxingSignType.password ? '请填写签到码' : '请填写手势码');
      return null;
    }
    if (_batch.pending.isEmpty) {
      setState(() => _error = _batch.targets.any((target) => target.selected) ? '选中的人都已签到' : '请先选要签到的人');
      return null;
    }
    final missingPhoto = _needsPhoto ? _batch.pending.where((target) => target.photoBytes == null && target.photoObjectId == null).firstOrNull : null;
    if (missingPhoto != null) {
      setState(() => _error = _multi ? '请给 ${missingPhoto.record.name} 选签到照片' : '这场签到要照片，请先选一张');
      return null;
    }
    return ChaoxingSignInputs(signCode: signCode, location: location);
  }

  Future<void> _start() async {
    final inputs = _inputs();
    if (inputs == null) return;
    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      final signCode = inputs.signCode;
      if (signCode != null && !await widget.controller.checkSignCode(_activity, signCode)) {
        if (mounted) setState(() => _error = _type == ChaoxingSignType.password ? '签到码不对，核对后再试' : '手势码不对，核对后再试');
        return;
      }
    } on ChaoxingFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
      return;
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=check_code errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '签到没完成，请稍后重试');
      return;
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
    if (!mounted) return;
    await _batch.run(_signer(inputs));
    _finishIfDone();
  }

  // 二维码签到：取景页一直开着，扫到的新码交给连签，所有人签完自动关；码过期就等下一个新码接着签。
  // 没有连续扫码能力时（测试环境）退回单次扫码，过期了再打开一次扫码页。
  Future<void> _startQr({ChaoxingSignTarget? only, bool force = false}) async {
    final base = _inputs();
    if (base == null) return;
    final watch = widget.watchQrCode;
    final scan = widget.scanQrCode;
    if (watch == null && scan == null) {
      setState(() => _error = '当前版本不能扫码，请让老师贴出签到码');
      return;
    }
    final feed = _feed = _QrFeed();
    final done = Completer<void>();
    final status = ValueNotifier<String?>(null);
    void onBatch() {
      final phone = _batch.currentPhone;
      final pending = _batch.pending;
      final current = pending.where((target) => target.phoneNumber == phone).firstOrNull;
      status.value = current == null ? null : '正在为 ${current.record.name} 签到，还剩 ${pending.length} 人';
    }

    _batch.addListener(onBatch);
    if (watch != null) {
      unawaited(
        watch(
          context,
          hint: _multi ? '对准老师的签到二维码，签完所有人自动关闭' : '把课堂签到二维码放入框内',
          accept: (raw) => chaoxingParseQrCode(raw) == null ? '这不是课堂签到二维码' : null,
          onCode: (raw) => feed.push(chaoxingParseQrCode(raw)!),
          until: done.future,
          status: status,
        ).whenComplete(feed.close),
      );
    }
    Future<ChaoxingQrCode> next(ChaoxingQrCode? expired) async {
      if (watch != null) return feed.next(expired);
      final raw = await scan!(context, '把课堂签到二维码放入框内', (value) => chaoxingParseQrCode(value) == null ? '这不是课堂签到二维码' : null);
      if (raw == null) throw const ChaoxingFailure(ChaoxingFailureCode.cancelled, '扫码已取消');
      return chaoxingParseQrCode(raw)!;
    }

    try {
      // 扫到的第一个码先问一次是否过期，过期就提示对准新的码。
      var code = await next(null);
      while (await widget.controller.qrCodeExpired(code, _activity)) {
        status.value = '这个二维码已过期，请对准老师屏幕上的新码';
        code = await next(code);
      }
      if (!mounted) return;
      final signer = _signer(
        ChaoxingSignInputs(location: base.location, qrCode: code),
        freshQrCode: (expired) {
          status.value = '二维码过期了，正在等新的码';
          return next(expired);
        },
      );
      if (only == null) {
        await _batch.run(signer);
      } else {
        await _batch.retry(only, signer, force: force);
      }
    } on ChaoxingFailure catch (failure) {
      if (mounted && failure.code != ChaoxingFailureCode.cancelled) setState(() => _error = failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=qr_sign errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '扫码签到没完成，请重试');
    } finally {
      _batch.removeListener(onBatch);
      if (!done.isCompleted) done.complete();
      feed.close();
      status.dispose();
      if (identical(_feed, feed)) _feed = null;
    }
    _finishIfDone();
  }

  void _finishIfDone() {
    if (!mounted || !_batch.allSucceeded) return;
    final succeeded = _batch.targets.where((target) => target.selected && target.done).toList();
    if (succeeded.isEmpty) return;
    Navigator.pop(context, ChaoxingSignSummary(succeeded: succeeded.length, late: succeeded.any((target) => target.late)));
  }

  // 单独重试一个人；强制签到先说明后果再确认。
  Future<void> _retry(ChaoxingSignTarget target, {required bool force}) async {
    if (force) {
      final agreed = await showCampusConfirm(
        context,
        title: '强制签到',
        message: '会跳过签到前的检查（已签到、已截止、是否在班级）直接提交。检查判断没错时，老师那边可能出现不在班级的名单或重复记录。',
        action: '强制签到',
      );
      if (!agreed || !mounted) return;
    }
    final inputs = _inputs();
    if (inputs == null) return;
    if (_type == ChaoxingSignType.qrCode) {
      await _startQr(only: target, force: force);
      return;
    }
    await _batch.retry(target, _signer(inputs), force: force);
    _finishIfDone();
  }

  Future<void> _repair(ChaoxingSignTarget target) async {
    final password = await showChaoxingPasswordPrompt(context, name: target.record.name);
    if (password == null || !mounted) return;
    setState(() {
      target.message = '正在重新登录…';
      _error = null;
    });
    try {
      await widget.controller.repairAccount(target.record, password);
      if (!mounted) return;
      setState(() {
        target
          ..needsRepair = false
          ..message = '已重新登录，可以重试';
      });
    } on ChaoxingFailure catch (failure) {
      if (mounted) setState(() => target.message = failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=repair errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => target.message = '重新登录没完成，请稍后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return CampusSheetPanel(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 12, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('签到', style: Theme.of(context).textTheme.titleLarge)),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const CampusIcon(CampusIcons.close),
                ),
              ],
            ),
            Padding(padding: const EdgeInsets.only(right: 12), child: _body(palette)),
          ],
        ),
      ),
    );
  }

  Widget _body(CampusPalette palette) {
    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(_loadError!, style: TextStyle(fontSize: 14, color: palette.danger)),
      );
    }
    final info = _info;
    if (info == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: CampusLoading(label: '正在读取活动…', inline: true),
      );
    }
    final single = _batch.targets.first;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        // 第一行课程名，第二行活动名与类型（同名时只显示一个，见 displayTitle），第三行时间。
        Text(
          _activity.subtitle,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface),
        ),
        const SizedBox(height: 4),
        DotSeparatedText(_activity.displayTitle, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
        // 时间单独一行：完整的日期时间跟在活动名后面会被折断。
        Text(_windowText(), style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
        _timeNotice(palette),
        _signOutNotice(palette, info),
        if (_needsLocation) ...[
          const SizedBox(height: 16),
          Text('位置', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
          const SizedBox(height: 8),
          _locationPicker(palette),
        ],
        if (_needsCode) ...[
          SizedBox(height: campusFieldGap(context)),
          TextField(
            controller: _code,
            keyboardType: _type == ChaoxingSignType.password ? TextInputType.number : TextInputType.text,
            inputFormatters: _type == ChaoxingSignType.password ? [FilteringTextInputFormatter.digitsOnly] : null,
            decoration: InputDecoration(
              labelText: _type == ChaoxingSignType.password ? '签到码' : '手势码',
              helperText: info.signCodeLength > 0 ? '${info.signCodeLength} 位' : null,
            ),
          ),
        ],
        if (_multi) ...[
          const SizedBox(height: 16),
          Text('签到对象', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
          const SizedBox(height: 8),
          for (final target in _batch.targets) _targetRow(palette, target),
        ] else ...[
          if (_needsPhoto) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _pickPhoto(single),
              icon: const CampusIcon(CampusIcons.image),
              label: Text(single.photoName ?? '选择签到照片'),
            ),
          ],
          if (_needsFace) ...[
            const SizedBox(height: 16),
            Text(
              single.faceObjectId == null ? '这场签到要人脸识别，会用存着的人脸照片' : '已选这次用的人脸照片',
              style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _pickFace(single),
              icon: const CampusIcon(CampusIcons.scanFace),
              label: Text(single.faceObjectId == null ? '换一张人脸照片' : '重新选择'),
            ),
          ],
          if (single.state == ChaoxingTargetState.failed) _failureActions(palette, single, inline: false),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(fontSize: 14, color: palette.danger)),
        ],
        const SizedBox(height: 20),
        FilledButton(
          style: campusProminent,
          onPressed: _busy ? null : (_type == ChaoxingSignType.qrCode ? () => _startQr() : _start),
          child: CampusBusyContent(
            busy: _busy,
            label: _primaryLabel(),
            busyLabel: _batch.running && _needsPhoto ? '上传与签到中' : '签到中',
            icon: CampusIcon(_type == ChaoxingSignType.qrCode ? CampusIcons.scan : CampusIcons.check),
          ),
        ),
      ],
    );
  }

  String _primaryLabel() {
    final count = _batch.pending.length;
    final base = _type == ChaoxingSignType.qrCode ? '扫码签到' : '签到';
    return _multi && count > 1 ? '$base（$count 人）' : base;
  }

  // 每个签到对象一行：勾选、名字与状态，拍照/人脸要的输入，失败时的操作。
  Widget _targetRow(CampusPalette palette, ChaoxingSignTarget target) {
    final record = target.record;
    final statusText = switch (target.state) {
      ChaoxingTargetState.idle => record.isOtherUser ? '代签账号' : '本人',
      ChaoxingTargetState.waiting => '等待中',
      ChaoxingTargetState.signing => '签到中',
      ChaoxingTargetState.succeeded || ChaoxingTargetState.failed => target.message ?? '',
    };
    return CampusSurface(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
      radius: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: target.selected,
                onChanged: _busy || target.done ? null : (value) => setState(() => target.selected = value ?? false),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(record.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface)),
                    Text(
                      statusText,
                      style: TextStyle(
                        fontSize: 14,
                        color: target.state == ChaoxingTargetState.failed ? palette.danger : palette.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              switch (target.state) {
                ChaoxingTargetState.signing => const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                ChaoxingTargetState.succeeded => const CampusIcon(CampusIcons.success),
                _ => const SizedBox.shrink(),
              },
            ],
          ),
          if (target.selected && !target.done && (_needsPhoto || _needsFace))
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (_needsPhoto)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _pickPhoto(target),
                      icon: const CampusIcon(CampusIcons.image),
                      label: Text(target.photoName ?? '选签到照片'),
                    ),
                  if (_needsFace)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _pickFace(target),
                      icon: const CampusIcon(CampusIcons.scanFace),
                      label: Text(target.faceObjectId == null ? '人脸照片：用存着的' : '人脸照片：已另选'),
                    ),
                ],
              ),
            ),
          if (target.state == ChaoxingTargetState.failed) _failureActions(palette, target, inline: true),
        ],
      ),
    );
  }

  // 失败后的操作：会话失效先修复；签到前检查拦下的可以强制签到；其余可以重试。
  Widget _failureActions(CampusPalette palette, ChaoxingSignTarget target, {required bool inline}) => Padding(
    padding: EdgeInsets.only(left: inline ? 12 : 0, top: inline ? 4 : 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!inline) Text(target.message ?? '', style: TextStyle(fontSize: 14, color: palette.danger)),
        if (!inline) const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (target.needsRepair)
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _repair(target),
                icon: const CampusIcon(CampusIcons.login),
                label: const Text('重新登录'),
              )
            else ...[
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _retry(target, force: false),
                icon: const CampusIcon(CampusIcons.restore),
                label: const Text('重试'),
              ),
              if (target.forceAvailable)
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _retry(target, force: true),
                  icon: const CampusIcon(CampusIcons.warning),
                  label: const Text('强制签到'),
                ),
            ],
          ],
        ),
      ],
    ),
  );

  // 已结束的活动照样能签，但可能记为迟到；发布太久的提醒确认没选错。
  // [人工决策-2026-10-07 17:00:58] 测试阶段以参考项目为准：往期活动维持「照样能签、可能记为迟到」的提示，失败后仍给「重试」。
  // 实测老师已结束的活动强制提交会被学习通拒绝（原样返回「签到已结束」），用户选定不为此改文案或收紧按钮（方案 A）。
  Widget _timeNotice(CampusPalette palette) {
    final now = DateTime.now().toUtc();
    final end = _activity.endTime;
    final String? message;
    if (!_activity.ongoing) {
      message = end == null
          ? '这场签到已经结束或还没开始，现在签到可能会记为迟到'
          : '这场签到已在 ${formatCampusTimestamp(end.toIso8601String())} 截止，现在签到可能会记为迟到';
    } else if (now.difference(_activity.startTime) > chaoxingStaleActivityAge) {
      message = '这场签到发布于 ${formatCampusTimestamp(_activity.startTime.toIso8601String())}，'
          '已经过去 ${now.difference(_activity.startTime).inHours} 小时，确认没有选错';
    } else {
      message = null;
    }
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: CampusSurface(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        radius: 16,
        child: Row(
          children: [
            CampusIcon(CampusIcons.warning, color: palette.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(child: Text(message, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant))),
          ],
        ),
      ),
    );
  }

  // 这个活动本身是签退活动，或它发布了签退活动时，给一条跳过去的入口。
  Widget _signOutNotice(CampusPalette palette, ChaoxingActiveInfo info) {
    final state = info.signOutState;
    if (state == ChaoxingSignOutState.none) return const SizedBox.shrink();
    final relatedActiveId = info.relatedActiveId;
    final (message, action) = switch (state) {
      ChaoxingSignOutState.signOutActivity => ('这是签退活动，先确认主签到已经完成', '去主签到'),
      ChaoxingSignOutState.signOutPublished => ('这次签到还发布了签退活动', '去签退'),
      _ => ('签退活动将在 ${info.signOutPublishTime == null ? '稍后' : formatCampusTimestamp(info.signOutPublishTime!.toIso8601String())} 发布，到时候再来签退', null),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: CampusSurface(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        radius: 16,
        child: Row(
          children: [
            Expanded(child: Text(message, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant))),
            if (action != null && relatedActiveId != null) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: _busy ? null : () => _openRelated(relatedActiveId),
                child: Text(action),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _windowText() {
    final end = _activity.endTime;
    if (end == null) return _activity.ongoing ? '进行中' : '已结束';
    return '截止 ${formatCampusTimestamp(end.toIso8601String())}';
  }

  Widget _locationPicker(CampusPalette palette) {
    final saved = widget.controller.locations;
    if (_manualLocation) {
      final fallback = chaoxingMapUnavailableReason;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (fallback != null) ...[
            Text('$fallback，填经纬度或用收藏的位置', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(child: TextField(controller: _latitude, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '纬度'))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _longitude, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '经度'))),
            ],
          ),
          SizedBox(height: campusFieldGap(context)),
          TextField(
            controller: _address,
            decoration: const InputDecoration(labelText: '位置名称', helperText: '坐标按高德（GCJ-02）算，例如教学楼名会一起提交'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _saveLocation(),
                icon: const CampusIcon(CampusIcons.add),
                label: const Text('收藏这个位置'),
              ),
              if (chaoxingMapAvailable) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _pickOnMap(),
                  icon: const CampusIcon(CampusIcons.jumpToday),
                  label: const Text('在地图上选点'),
                ),
              ],
            ],
          ),
          if (saved.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => setState(() => _manualLocation = false),
                child: const Text('用收藏的位置'),
              ),
            ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (chaoxingMapAvailable) ...[
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _pickOnMap(),
            icon: const CampusIcon(CampusIcons.jumpToday),
            label: const Text('在地图上选点'),
          ),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in saved)
              CampusGlassChip(
                label: item.label,
                selected: _savedLocation == item.location,
                onSelected: (_) => setState(() => _savedLocation = item.location),
              ),
            CampusGlassChip(label: '手动输入', selected: false, onSelected: (_) => setState(() => _manualLocation = true)),
          ],
        ),
        const SizedBox(height: 8),
        DotSeparatedText(
          _savedLocation == null
              ? '还没有收藏位置'
              : '${_savedLocation!.address} · ${_savedLocation!.formattedLatitude}, ${_savedLocation!.formattedLongitude}',
          style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
        ),
      ],
    );
  }
}

// 连续扫码时的最新二维码：签到要新码时，有比过期那个新的就直接给，没有就等下一次扫到。
class _QrFeed {
  ChaoxingQrCode? _latest;
  final _waiters = <Completer<ChaoxingQrCode>>[];
  bool _closed = false;

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
      if (_closed) throw const ChaoxingFailure(ChaoxingFailureCode.cancelled, '扫码已取消');
      final waiter = Completer<ChaoxingQrCode>();
      _waiters.add(waiter);
      await waiter.future;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.completeError(const ChaoxingFailure(ChaoxingFailureCode.cancelled, '扫码已取消'));
    }
    _waiters.clear();
  }
}
