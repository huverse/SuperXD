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
import 'package:superxd/toolbox/chaoxing/chaoxing_captcha_dialog.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_map_page.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_qrcode.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 签到弹层：先取活动详情，再按类型要输入；签到在弹层里原地给状态，成功后随结果一起关掉。
// 需要滑块验证码时就地弹验证，过了自动把这次签到重发一遍。
Future<ChaoxingSignResult?> showChaoxingSignSheet(
  BuildContext context, {
  required ChaoxingController controller,
  required ChaoxingActivity activity,
  ToolboxQrScan? scanQrCode,
}) => showCampusSheet<ChaoxingSignResult>(
  context: context,
  builder: (context) => _ChaoxingSignSheet(controller: controller, activity: activity, scanQrCode: scanQrCode),
);

class _ChaoxingSignSheet extends StatefulWidget {
  const _ChaoxingSignSheet({required this.controller, required this.activity, this.scanQrCode});
  final ChaoxingController controller;
  final ChaoxingActivity activity;
  final ToolboxQrScan? scanQrCode;
  @override
  State<_ChaoxingSignSheet> createState() => _ChaoxingSignSheetState();
}

class _ChaoxingSignSheetState extends State<_ChaoxingSignSheet> {
  final _code = TextEditingController();
  final _latitude = TextEditingController();
  final _longitude = TextEditingController();
  final _address = TextEditingController();
  late ChaoxingActivity _activity = widget.activity;
  ChaoxingActiveInfo? _info;
  ChaoxingQrCode? _qrCode;
  String? _loadError;
  String? _error;
  bool _signing = false;
  bool _loadingRelated = false;
  bool _manualLocation = false;
  ChaoxingLocation? _savedLocation;
  List<int>? _photoBytes;
  String? _photoName;
  String? _photoObjectId;

  ChaoxingSignType get _type => _activity.signType;
  bool get _needsLocation => _type == ChaoxingSignType.location || (_info?.needLocation ?? false);
  bool get _needsPhoto => _type == ChaoxingSignType.photo && (_info?.needPhoto ?? false);
  bool get _busy => _signing || _loadingRelated;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _code.dispose();
    _latitude.dispose();
    _longitude.dispose();
    _address.dispose();
    super.dispose();
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

  Future<void> _pickPhoto() async {
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 95,
      );
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        _photoBytes = bytes;
        _photoName = file.name;
        _photoObjectId = null;
      });
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=photo errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '照片读取失败，请重新选择');
    }
  }

  Future<void> _scanQrCode() async {
    final scan = widget.scanQrCode;
    if (scan == null) {
      setState(() => _error = '当前版本不能扫码，请让老师贴出签到码');
      return;
    }
    try {
      final raw = await scan(context);
      if (!mounted || raw == null) return;
      final code = chaoxingParseQrCode(raw);
      if (code == null) {
        setState(() => _error = '这不是课堂签到二维码');
        return;
      }
      setState(() {
        _qrCode = code;
        _error = null;
      });
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=scan errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '扫码没完成，请重试');
    }
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
        _qrCode = null;
        _photoBytes = null;
        _photoName = null;
        _photoObjectId = null;
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

  Future<String?> _solveCaptcha() => showChaoxingCaptchaDialog(
    context,
    load: () => widget.controller.captchaPuzzle(_activity),
    loadImage: widget.controller.captchaImage,
    verify: (puzzle, position) => widget.controller.solveCaptcha(_activity, puzzle, position),
  );

  // 服务端要求验证码时，先弹验证；过了带着 validate 与 enc2 把这次签到重发一遍。
  Future<void> _submit(int attempt, String? validate, String? enc2, String? signCode, ChaoxingLocation? location) async {
    try {
      final result = await widget.controller.sign(
        _activity,
        signCode: signCode,
        location: location,
        photoObjectId: _photoObjectId,
        qrCode: _qrCode,
        captchaValidate: validate,
        enc2: enc2,
      );
      if (mounted) Navigator.pop(context, result);
    } on ChaoxingFailure catch (failure) {
      if (failure.code == ChaoxingFailureCode.captchaRequired && attempt < 3) {
        final answer = await _solveCaptcha();
        if (!mounted) return;
        if (answer == null) {
          setState(() => _error = '需要完成安全验证才能签到');
          return;
        }
        return _submit(attempt + 1, answer, failure.payload ?? enc2, signCode, location);
      }
      rethrow;
    }
  }

  void _start() {
    final location = _currentLocation();
    if (_needsLocation && location == null) {
      setState(() => _error = '这场签到要位置，请选一个位置或填写坐标');
      return;
    }
    final needsCode = _type == ChaoxingSignType.password || _type == ChaoxingSignType.gesture;
    final signCode = needsCode ? _code.text.trim() : null;
    if (needsCode && signCode!.isEmpty) {
      setState(() => _error = _type == ChaoxingSignType.password ? '请填写签到码' : '请填写手势码');
      return;
    }
    if (_type == ChaoxingSignType.qrCode && _qrCode == null) {
      setState(() => _error = '请先扫描老师的签到二维码');
      return;
    }
    if (_needsPhoto && _photoBytes == null) {
      setState(() => _error = '这场签到要照片，请先选一张');
      return;
    }
    setState(() {
      _signing = true;
      _error = null;
    });
    _run(signCode, location);
  }

  Future<void> _run(String? signCode, ChaoxingLocation? location) async {
    try {
      // 照片只传一次：验证码重试用的是同一个 objectId。
      if (_needsPhoto && _photoObjectId == null && _photoBytes != null) {
        _photoObjectId = await widget.controller.uploadPhoto(_photoBytes!);
        if (!mounted) return;
      }
      if (signCode != null) {
        final valid = await widget.controller.checkSignCode(_activity, signCode);
        if (!valid) {
          if (mounted) setState(() => _error = _type == ChaoxingSignType.password ? '签到码不对，核对后再试' : '手势码不对，核对后再试');
          return;
        }
      }
      await _submit(0, null, null, signCode, location);
    } on ChaoxingFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=sign errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '签到没完成，请稍后重试');
    } finally {
      if (mounted) setState(() => _signing = false);
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        Text(
          '${_activity.subtitle} · ${_activity.title}',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface),
        ),
        const SizedBox(height: 4),
        Text('${_type.label} · ${_windowText()}', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
        _signOutNotice(palette, info),
        if (_needsLocation) ...[
          const SizedBox(height: 16),
          Text('位置', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
          const SizedBox(height: 8),
          _locationPicker(palette),
        ],
        if (_type == ChaoxingSignType.qrCode) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _scanQrCode(),
            icon: const CampusIcon(CampusIcons.scan),
            label: Text(_qrCode == null ? '扫描签到二维码' : '重新扫描二维码'),
          ),
        ],
        if (_type == ChaoxingSignType.password || _type == ChaoxingSignType.gesture) ...[
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
        if (_needsPhoto) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _pickPhoto(),
            icon: const CampusIcon(CampusIcons.image),
            label: Text(_photoName ?? '选择签到照片'),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(fontSize: 14, color: palette.danger)),
        ],
        const SizedBox(height: 20),
        FilledButton(
          style: campusProminent,
          onPressed: _busy ? null : _start,
          child: CampusBusyContent(
            busy: _busy,
            label: '签到',
            busyLabel: _needsPhoto && _photoObjectId == null ? '上传中' : '签到中',
            icon: const CampusIcon(CampusIcons.check),
          ),
        ),
      ],
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
    if (end == null) return '已开始';
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
        Text(
          _savedLocation == null
              ? '还没有收藏位置'
              : '${_savedLocation!.address} · ${_savedLocation!.formattedLatitude}, ${_savedLocation!.formattedLongitude}',
          style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
        ),
      ],
    );
  }
}
