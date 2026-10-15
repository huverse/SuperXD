import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pool/pool.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_batch.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_captcha_dialog.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_code_cells.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_face.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_face_sheet.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_gesture_field.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_image_pick.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_map_page.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_qr_feed.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_qrcode.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_settings_sheet.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_sign_flow.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_sign_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_sign_notices.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

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
  ToolboxImagePick? pickImage,
  ToolboxImagesPick? pickImages,
}) => showCampusSheet<ChaoxingSignSummary>(
  context: context,
  builder: (context) => _ChaoxingSignSheet(
    controller: controller,
    activity: activity,
    scanQrCode: scanQrCode,
    watchQrCode: watchQrCode,
    pickImage: pickImage,
    pickImages: pickImages,
  ),
);

class _ChaoxingSignSheet extends StatefulWidget {
  const _ChaoxingSignSheet({
    required this.controller,
    required this.activity,
    this.scanQrCode,
    this.watchQrCode,
    this.pickImage,
    this.pickImages,
  });
  final ChaoxingController controller;
  final ChaoxingActivity activity;
  final ToolboxQrScan? scanQrCode;
  final ToolboxQrWatch? watchQrCode;
  final ToolboxImagePick? pickImage;
  final ToolboxImagesPick? pickImages;
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

  // 扫码签到进行中（取景页开着、还没轮到连签）：也算忙，防止再点一次又开一个取景页。
  bool _scanning = false;
  // 手势或签到码校验没过：格子（图案）标红并清空，让人重画（重输）。
  bool _codeWrong = false;
  // 签到码/手势的校验方式（[人工决策-2026-10-08 16:39:31]）：标准=输码经服务端校验；绕过=不输码直接提交。
  bool _bypassCode = false;
  bool _manualLocation = false;
  ChaoxingLocation? _savedLocation;
  ChaoxingQrFeed? _feed;
  // 开签前现拍补给的人脸照片（只上传、还没进人脸照片列表）：签好后问存不存。
  final _newFaces = <ChaoxingSignTarget, String>{};

  ChaoxingSignType get _type => _activity.signType;
  bool get _needsLocation => _type == ChaoxingSignType.location || (_info?.needLocation ?? false);
  bool get _needsPhoto => _type == ChaoxingSignType.photo && (_info?.needPhoto ?? false);
  bool get _needsFace => _info != null && chaoxingFaceApplies(_type, _info!);
  bool get _needsCode => _type == ChaoxingSignType.password || _type == ChaoxingSignType.gesture;
  bool get _multi => _batch.targets.length > 1;
  bool get _busy => _preparing || _loadingRelated || _scanning || _batch.running;

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
      // 默认选中的位置（[人工决策-2026-10-14 21:26:16]，见 chaoxing_map_page.dart）：这门课上次签到用的 → 上次签到用的；
      // 都没有时嵌着的地图拿当前位置。地图用不了时退回最近用过的收藏。
      final remembered = await widget.controller.signedLocation(_activity);
      if (!mounted) return;
      setState(() {
        _info = info;
        // 列表里认不出的类型，用详情里认出的补上（对齐参考项目；详情也认不出就保持 unknown，提交前提示不支持）。
        if (_activity.signType == ChaoxingSignType.unknown && info.signType != null) {
          _activity = _activity.change(signType: info.signType);
        }
        _loadError = null;
        // 地图用不了时直接摊开经纬度，别让人先去点一下「手动输入」；改用收藏时默认选中上面那个位置。
        _manualLocation = !chaoxingMapAvailable;
        _savedLocation = remembered ?? (chaoxingMapAvailable ? null : widget.controller.locations.firstOrNull?.location);
        if (chaoxingMapAvailable) _address.text = remembered?.address ?? '';
        if (info.locationLatitude != null && info.locationLongitude != null && _manualLocation) {
          // 详情给的坐标是学习通的 BD-09 口径，输入框按高德 GCJ-02 解释，先转一层再预填（参考项目同样按 BD-09 使用）。
          final asGcj = bd09ToGcj02(info.locationLatitude!, info.locationLongitude!);
          _latitude.text = asGcj.latitude.toStringAsFixed(6);
          _longitude.text = asGcj.longitude.toStringAsFixed(6);
        }
      });
    } on ChaoxingFailure catch (failure) {
      if (mounted) setState(() => _loadError = failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=active_info errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _loadError = '活动详情没读到，请稍后重试');
    }
    unawaited(_presignOnOpen());
  }

  // 打开签到页先检查一遍（对齐参考项目，别等提交后才知道）：已签到、已截止或不在班级的人原地标出
  // 并取消勾选（只有一个账号时不取消）；全部被拦时弹窗给「关闭 / 仍然签到」，还有没勾的账号时多一个「为其他账号签到」。检查不挡详情显示，也不挡提交（提交时会再查一次，
  // 选了仍然签到的人不再查）。
  Future<void> _presignOnOpen() async {
    final checked = _activity.activeId;
    final selected = [for (final target in _batch.targets) if (target.selected) target];
    if (selected.isEmpty) return;
    final blocked = <ChaoxingSignTarget, ChaoxingFailure>{};
    // 每人要 preSign、analysis 两步加班级检查，多人时并发 3 个（与刷新列表同口径），不逐人串行干等。
    final pool = Pool(ChaoxingController.refreshConcurrency);
    await Future.wait(
      selected.map(
        (target) => pool.withResource(() async {
          try {
            final failure = await widget.controller.presignCheck(target, _activity);
            if (failure != null) blocked[target] = failure;
          } on ChaoxingFailure catch (failure) {
            // 会话过期等查不出结果的，留给提交时的检查处理。
            campusLog('[Chaoxing] action=presign_open errorType=${failure.code.name}');
          } catch (failure, stack) {
            campusLog('[Chaoxing] action=presign_open errorType=${failure.runtimeType}\n$stack');
          }
        }),
      ),
    );
    await pool.close();
    if (!mounted || blocked.isEmpty || _busy || _activity.activeId != checked) return;
    for (final entry in blocked.entries) {
      // 只有一个账号时没有勾选框，取消勾选就再也选不回来，点签到只会提示「请先选要签到的人」（真机反馈），保持勾选。
      if (_multi) entry.key.selected = false;
      entry.key
        ..state = ChaoxingTargetState.failed
        ..message = entry.value.message
        ..forceAvailable = true;
    }
    _batch.notifyChanged();
    if (blocked.length != selected.length) return;
    // 勾选的人全被拦：照参考项目给三选。
    // 并发检查的完成顺序不定，提示按勾选顺序取第一个被拦的人。
    // [人工决策-2026-10-14 13:34:56] 原来统一叫「这场签到检查没过」、末项「我认为是 BUG，强制签到」，真机上看不懂：
    // 标题按原因直说（同苹果、Material 弹窗规范），按钮用动作词；「为其他账号签到」只在还有没勾的账号时给。
    final first = selected.firstWhere(blocked.containsKey);
    final failure = blocked[first]!;
    final (title, detail) = switch (failure.code) {
      ChaoxingFailureCode.alreadySigned => ('这场已经签过了', null),
      ChaoxingFailureCode.expired => ('签到已经结束', '现在提交可能记为迟到或失败'),
      ChaoxingFailureCode.noPermission => ('这个账号不在这门课的班级里', '可能已退课或换了班'),
      _ => (failure.message, null),
    };
    final othersLeft = _batch.targets.any((target) => !blocked.containsKey(target));
    final choice = await showCampusDialog<int>(
      context: context,
      builder: (context) => CampusGlassDialog(
        title: Text(title),
        content: detail == null ? null : Text(detail),
        options: [
          if (othersLeft) SimpleDialogOption(onPressed: () => Navigator.pop(context, 0), child: const Text('为其他账号签到')),
          SimpleDialogOption(onPressed: () => Navigator.pop(context, 1), child: const Text('关闭')),
          SimpleDialogOption(onPressed: () => Navigator.pop(context, 2), child: const Text('仍然签到')),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 1) {
      Navigator.of(context).pop();
    } else if (choice == 2) {
      // [人工决策-2026-10-14 23:36:00] 「仍然签到」只是放行，不直接提交：关掉弹窗留在签到页接着选位置、输码、拍照，
      // 点签到（扫码）时这个人跳过签到前检查（同参考项目「我认为这是 BUG」只关掉提示）。以前点了就立刻强制提交，位置还没看就签出去了。
      first
        ..selected = true
        ..forced = true
        ..state = ChaoxingTargetState.idle
        ..message = null
        ..forceAvailable = false;
      _batch.notifyChanged();
    }
  }

  ChaoxingLocation? _currentLocation() {
    if (!_needsLocation) return null;
    if (!_manualLocation) {
      final selected = _savedLocation;
      if (selected == null || !chaoxingMapAvailable) return selected;
      // 地图模式下位置名称可改：没填就用选中位置自带的名称，地图点出来的没有名称，叫「地图选点」。
      final name = _address.text.trim();
      return ChaoxingLocation(
        latitude: selected.latitude,
        longitude: selected.longitude,
        address: name.isNotEmpty ? name : (selected.address.isNotEmpty ? selected.address : '地图选点'),
        system: selected.system,
      );
    }
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

  // 详情里有签到点与范围时在地图上画出来（学习通给的是 BD-09 口径，地图内部会换算成 GCJ-02）。
  ChaoxingLocation? get _rangeCenter {
    final latitude = _info?.locationLatitude;
    final longitude = _info?.locationLongitude;
    if (latitude == null || longitude == null) return null;
    return ChaoxingLocation(latitude: latitude, longitude: longitude, address: '', system: ChaoxingCoordinateSystem.bd09);
  }

  // 全屏选点（嵌着的地图太小时用）：从当前选中的位置开始，名称框里的名称带过去。
  Future<void> _pickOnMap() async {
    final ChaoxingLocation? picked;
    try {
      picked = await openChaoxingMapPicker(
        context,
        initial: _currentLocation() ?? _savedLocation,
        label: _address.text.trim(),
        rangeCenter: _rangeCenter,
        rangeMeters: _info?.locationRange.toDouble(),
      );
    } catch (error, stack) {
      campusLog('[Chaoxing] action=pick_on_map errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '地图没打开，可以手动输入位置');
      return;
    }
    if (!mounted || picked == null) return;
    final chosen = picked;
    // [人工决策-2026-10-08 19:35:38] 地图选点只用于这次签到，不自动收藏（同高德、Google 地图：保存要用户明确点）；
    // 收藏只走签到成功后的「收藏这次的位置？」询问（500 米内已有收藏不问）。取代选点即收藏的旧做法。
    // [人工决策-2026-10-15 19:42:58] 用户选了补齐参考项目的两处：管理收藏里可以主动在地图上添加（见 chaoxing_location_sheet.dart），
    // 签完的询问多一个「这附近不再问」（见 _offerSaveLocation）。这里地图选点仍然不自动收藏。
    setState(() {
      _savedLocation = chosen;
      _address.text = chosen.address;
      _manualLocation = false;
      _error = null;
    });
  }

  // 有人签到成功后记下这门课用的位置，下次签这门课默认选它（只存本机、不算收藏）；记不下不影响签到。
  void _rememberLocation(ChaoxingLocation? location) {
    if (location == null) return;
    widget.controller.rememberSignedLocation(_activity, location).catchError((Object error, StackTrace stack) {
      campusLog('[Chaoxing] action=remember_location errorType=${error.runtimeType}\n$stack');
    });
  }

  // 拍照签到每人一张照片（上传前各自随机裁剪旋转）：可以现场拍，也可以从相册选。
  Future<void> _pickPhoto(ChaoxingSignTarget target, {ImageSource source = ImageSource.gallery}) async {
    try {
      final bytes = await shootChaoxingPhoto(widget.pickImage, source: source);
      if (bytes == null || !mounted) return;
      setState(() {
        target
          ..photoBytes = bytes
          ..photoName = source == ImageSource.camera ? '现拍照片' : '相册照片'
          ..photoObjectId = null;
        _error = null;
      });
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=photo errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = chaoxingPhotoUnreadableMessage);
    }
  }

  // 多人拍照签到从相册一次选多张（同参考项目）：按签到对象的顺序分给还没有照片的人。
  Future<void> _pickPhotos(List<ChaoxingSignTarget> missing) async {
    try {
      final photos = await pickChaoxingPhotos(widget.pickImages, limit: missing.length);
      if (photos.isEmpty || !mounted) return;
      setState(() {
        // 老系统的选择器可能不认张数上限，多出来的不用。
        for (final (index, bytes) in photos.take(missing.length).indexed) {
          missing[index]
            ..photoBytes = bytes
            ..photoName = '相册照片'
            ..photoObjectId = null;
        }
        _error = null;
      });
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=photos errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = chaoxingPhotoUnreadableMessage);
    }
  }

  // 勾选了、还没签好、也还没有照片的人。
  List<ChaoxingSignTarget> _missingPhotos() => [
    for (final target in _batch.pending)
      if (target.photoBytes == null && target.photoObjectId == null) target,
  ];

  // 人脸照片：默认用这个人存着的那张，也可以这次另选一张。
  Future<void> _pickFace(ChaoxingSignTarget target) async {
    final objectId = await showChaoxingFaceSheet(context, controller: widget.controller, record: target.record, pickImage: widget.pickImage, pick: true);
    if (!mounted || objectId == null) return;
    setState(() {
      target.faceObjectId = objectId;
      _newFaces.remove(target);
    });
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
        _codeWrong = false;
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
    try {
      await widget.controller.saveLocation(location.address, location);
      if (mounted) setState(() => _error = null);
    } catch (error, stack) {
      campusLog('[Chaoxing] action=save_location errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '位置没收藏上，请重试');
    }
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

  // 一场签到共享一次位置收紧（对齐参考项目）：某人出界收紧后，后面的人直接从收紧档开始。
  // 输入按人现取：二维码签到每个人都从最新扫到的码开始。
  ChaoxingTargetSigner _signer(ChaoxingSignInputs Function() inputsOf, {ChaoxingFreshQrCode? freshQrCode}) {
    var tightenedShared = false;
    return (target, {required force}) async {
      final inputs = inputsOf();
      final result = await widget.controller.signTarget(
        target,
        _activity,
        info: _info!,
        inputs: inputs,
        solveCaptcha: _solveCaptcha,
        freshQrCode: freshQrCode,
        force: force,
        initialTightened: tightenedShared,
        onTightened: () => tightenedShared = true,
      );
      _rememberLocation(inputs.location);
      return result;
    };
  }

  // 开签前把所有人共用的输入与每个人的照片都核对一遍，缺什么原地提示。
  ChaoxingSignInputs? _inputs() {
    if (_type == ChaoxingSignType.unknown) {
      setState(() => _error = chaoxingUnsupportedTypeMessage);
      return null;
    }
    final location = _currentLocation();
    if (_needsLocation && location == null) {
      setState(() => _error = '这场签到要位置，请选一个位置或填写坐标');
      return null;
    }
    final signCode = _needsCode && !_bypassCode ? _code.text.trim() : null;
    if (_needsCode && !_bypassCode && signCode!.isEmpty) {
      setState(() => _error = _type == ChaoxingSignType.password ? '请填写签到码' : '请填写手势码');
      return null;
    }
    if (_batch.pending.isEmpty) {
      setState(() => _error = _batch.targets.any((target) => target.selected) ? '选中的人都已签到' : '请先选要签到的人');
      return null;
    }
    final missingPhoto = _needsPhoto ? _batch.pending.where((target) => target.photoBytes == null && target.photoObjectId == null).firstOrNull : null;
    if (missingPhoto != null) {
      setState(() => _error = _multi ? '请给 ${missingPhoto.record.name} 选签到照片' : chaoxingPhotoRequiredMessage);
      return null;
    }
    return ChaoxingSignInputs(signCode: signCode, location: location, bypassCodeCheck: _bypassCode);
  }

  // 开签前把每个人要用的人脸照片备齐（选了的→本机存的，随机挑一张并避开没通过过的），缺照片在这里补给：
  // 先问用不用学习通存的默认照片（随机裁剪旋转一张再上传，直接反复用会被比对出来），再给现场拍摄（3:4 裁剪），
  // 别等提交那一刻才失败、连签半路停队（对齐参考项目的开签前补齐时机）。
  Future<bool> _prepareFaces() async {
    for (final target in _batch.pending) {
      while (true) {
        try {
          await widget.controller.prepareFace(target, _activity, _info!);
          break;
        } on ChaoxingFailure catch (failure) {
          if (failure.code != ChaoxingFailureCode.faceRequired || !mounted) {
            if (mounted) setState(() => _error = failure.message);
            return false;
          }
          if (!await _supplyMissingFace(target)) {
            if (mounted) setState(() => _error = failure.message);
            return false;
          }
        } catch (failure, stack) {
          campusLog('[Chaoxing] action=prepare_face errorType=${failure.runtimeType}\n$stack');
          if (mounted) setState(() => _error = chaoxingSignRetryMessage);
          return false;
        }
      }
    }
    return true;
  }

  // 补给缺的人脸照片：学习通里有默认照片时先给「重处理默认照片 / 拍摄新照片」的选择，
  // 拍摄走相机并进 3:4 裁剪；补到的照片写回这个签到对象，取消返回 false。
  Future<bool> _supplyMissingFace(ChaoxingSignTarget target) async {
    String? profileId;
    try {
      profileId = await widget.controller.faces.profileFaceId(target.record);
    } on ChaoxingFailure catch (failure) {
      // 查不到就当学习通里没存过，直接进拍摄。
      campusLog('[Chaoxing] action=profile_face errorType=${failure.code.name}');
    }
    if (!mounted) return false;
    if (profileId != null) {
      final useProfile = await showCampusConfirm(
        context,
        title: '${target.record.name} 还没有人脸照片',
        message: '学习通里存着一张默认人脸照片。直接反复用它容易被比对出来，会随机裁剪旋转一张再上传；也可以现在拍一张新的。',
        action: '重处理默认照片',
        cancel: '拍摄新照片',
      );
      if (!mounted) return false;
      if (useProfile) {
        try {
          final objectId = await widget.controller.faces.reprocessProfileFace(target.record);
          if (objectId == null) {
            if (mounted) setState(() => _error = '学习通里的默认照片没取到，请拍一张');
            return false;
          }
          target.faceObjectId = objectId;
          return true;
        } on ChaoxingFailure catch (failure) {
          if (mounted) setState(() => _error = failure.message);
          return false;
        }
      }
    }
    try {
      final bytes = await pickChaoxingFacePhoto(widget.pickImage, source: ImageSource.camera);
      if (bytes == null || !mounted) return false;
      // 现拍的先只上传给这次签到用，签好后再问存不存（_offerSaveFaces），免得挤掉已经存着的照片。
      final objectId = await widget.controller.faces.uploadFaceImage(target.record, bytes, remember: false);
      target.faceObjectId = objectId;
      _newFaces[target] = objectId;
      return true;
    } on ChaoxingFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=supply_face errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '人脸照片没准备好，请重试');
    }
    return false;
  }

  // 位置签到成功后：附近 500 米内没有收藏、也没选过「这附近不再问」时，问一句要不要收藏这次的位置，
  // 收藏名当场可改（对齐参考项目）。
  Future<void> _offerSaveLocation(ChaoxingSignInputs inputs) async {
    final location = inputs.location;
    if (location == null || !_batch.targets.any((target) => target.selected && target.done)) return;
    if (!widget.controller.shouldOfferSave(location)) return;
    final name = TextEditingController(text: location.address);
    final choice = await showCampusDialog<String>(
      context: context,
      builder: (dialog) => CampusGlassDialog(
        title: const Text('收藏这次的位置？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: campusFieldGap(dialog)),
            TextField(controller: name, decoration: const InputDecoration(labelText: '收藏名')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, 'quiet'), child: const Text('这附近不再问')),
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('不收藏')),
          FilledButton(onPressed: () => Navigator.pop(dialog, 'save'), child: const Text('收藏')),
        ],
      ),
    );
    final label = name.text.trim();
    name.dispose();
    if (!mounted) return;
    if (choice == 'quiet') await widget.controller.quietNearby(location);
    if (choice == 'save') await widget.controller.saveLocation(label.isEmpty ? location.address : label, location);
  }

  // 开签前现拍的人脸照片：签好的人问一次要不要存进人脸照片（同参考项目），不存就只这次用；
  // 没签好的先留着，重试签好后再问。
  Future<void> _offerSaveFaces() async {
    final fresh = {for (final entry in _newFaces.entries) if (entry.key.done) entry.key: entry.value};
    if (fresh.isEmpty || !mounted) return;
    _newFaces.removeWhere((target, _) => fresh.containsKey(target));
    final agreed = await showCampusConfirm(
      context,
      title: '保存刚拍的人脸照片？',
      message: fresh.length > 1 ? '共 ${fresh.length} 张，存下后下次签到可以直接用' : '存下后下次签到可以直接用',
      action: '保存',
      cancel: '不保存',
    );
    if (!agreed) return;
    try {
      for (final entry in fresh.entries) {
        await widget.controller.faces.rememberFaceImage(entry.key.record, entry.value);
      }
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=save_new_faces errorType=${failure.runtimeType}\n$stack');
      if (mounted) showCampusToast(context, '人脸照片没存上');
    }
  }

  // 一轮签完后的顺手询问（收藏位置、存现拍的人脸照片）：没存上不影响签到结果。
  Future<void> _afterRun(ChaoxingSignInputs? inputs) async {
    try {
      if (inputs != null) await _offerSaveLocation(inputs);
      await _offerSaveFaces();
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=after_run errorType=${failure.runtimeType}\n$stack');
    }
  }

  Future<void> _start() async {
    if (_busy) return;
    final inputs = _inputs();
    if (inputs == null) return;
    // 每次校验前先熄掉上一次的输错标记：再错一次时格子（图案）要重新标红、重新震动。
    setState(() {
      _preparing = true;
      _error = null;
      _codeWrong = false;
    });
    try {
      final signCode = inputs.signCode;
      if (signCode != null && !await widget.controller.checkSignCode(_activity, signCode)) {
        // 校验没过：格子（图案）清空标红，重新输入（重画）后自动再试。
        if (mounted) {
          setState(() {
            _codeWrong = true;
            _error = _type == ChaoxingSignType.password ? '签到码不对，请重输' : '手势码不对，请重画';
          });
        }
        _code.clear();
        return;
      }
      if (mounted) setState(() => _codeWrong = false);
      if (!await _prepareFaces()) return;
    } on ChaoxingFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
      return;
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=check_code errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = chaoxingSignRetryMessage);
      return;
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
    if (!mounted) return;
    await _batch.run(_signer(() => inputs));
    await _afterRun(inputs);
    _finishIfDone();
  }

  // 二维码签到：取景页一直开着，扫到的新码交给连签，所有人签完自动关；码过期就等下一个新码接着签。
  // 没有连续扫码能力时（测试环境）退回单次扫码，过期了再打开一次扫码页。
  Future<void> _startQr({ChaoxingSignTarget? only, bool force = false}) async {
    if (_busy) return;
    final base = _inputs();
    if (base == null) return;
    final watch = widget.watchQrCode;
    final scan = widget.scanQrCode;
    if (watch == null && scan == null) {
      setState(() => _error = '当前版本不能扫码，请让老师贴出签到码');
      return;
    }
    setState(() => _scanning = true);
    try {
      if (!await _prepareFaces()) return;
      await _scanAndSign(base, watch: watch, scan: scan, only: only, force: force);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    await _afterRun(null);
    _finishIfDone();
  }

  Future<void> _scanAndSign(
    ChaoxingSignInputs base, {
    required ToolboxQrWatch? watch,
    required ToolboxQrScan? scan,
    required ChaoxingSignTarget? only,
    required bool force,
  }) async {
    final feed = _feed = ChaoxingQrFeed();
    final done = Completer<void>();
    final status = ValueNotifier<String?>(null);
    void onBatch() {
      final phone = _batch.currentPhone;
      final pending = _batch.pending;
      final current = pending.where((target) => target.phoneNumber == phone).firstOrNull;
      status.value = current == null ? null : '正在为 ${current.record.name} 签到，还剩 ${pending.length} 人';
    }

    _batch.addListener(onBatch);
    // 每扫到一个新码就查一次是否过期（同一个 enc 只查一次），过早在取景页上提示对准新码。
    final checkedEncs = <String>{};
    void checkFresh(String raw) {
      final parsed = chaoxingParseQrCode(raw);
      if (parsed == null || !checkedEncs.add(parsed.enc)) return;
      unawaited(
        widget.controller.qrCodeExpired(parsed, _activity).then((expired) {
          if (expired) status.value = '这个二维码已过期，请对准老师屏幕上的新码';
        }).catchError((Object error, StackTrace stack) {
          campusLog('[Chaoxing] action=qr_check errorType=${error.runtimeType}\n$stack');
        }),
      );
    }

    if (watch != null && mounted) {
      unawaited(
        watch(
          context,
          hint: _multi ? '对准老师的二维码，签完所有人自动关闭' : '把课堂签到二维码放入框内',
          accept: (raw) => chaoxingParseQrCode(raw) == null ? '这不是课堂签到二维码' : null,
          onCode: (raw) {
            feed.push(chaoxingParseQrCode(raw)!);
            checkFresh(raw);
          },
          until: done.future,
          status: status,
        ).catchError((Object error, StackTrace stack) {
          campusLog('[Chaoxing] action=qr_watch errorType=${error.runtimeType}\n$stack');
        }).whenComplete(feed.close),
      );
    }
    Future<ChaoxingQrCode> next(ChaoxingQrCode? expired) async {
      if (watch != null) return feed.next(expired);
      final raw = await scan!(context, '把课堂签到二维码放入框内', (value) => chaoxingParseQrCode(value) == null ? '这不是课堂签到二维码' : null);
      if (raw == null) throw const ChaoxingFailure(ChaoxingFailureCode.cancelled, chaoxingScanCancelledMessage);
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
      // 每个签到对象都从最新扫到的码开始（对齐参考项目：每人取 latestEnc），老师换了码后面的人立刻用上。
      Future<ChaoxingQrCode> fresh(ChaoxingQrCode expired) {
        status.value = '二维码过期了，正在等新的码';
        return next(expired);
      }

      final firstCode = code;
      final signer = _signer(() => ChaoxingSignInputs(location: base.location, qrCode: feed.latest ?? firstCode), freshQrCode: fresh);
      if (only == null) {
        // 连续扫码是逐码连签：任何一人失败就停，已签过、不在班级、登录过期的跳过接着签（对齐参考项目），等新码也是为了当前这个人。
        await _batch.run(signer, stopOnFailure: true);
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
    await _batch.retry(target, _signer(() => inputs), force: force);
    await _afterRun(null);
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
            // 读取、切换校验方式、出错与失败操作出现时，弹层高度平滑过渡而不是跳变（同成绩页的展开收起）。
            AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 250),
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topCenter,
              child: Padding(padding: const EdgeInsets.only(right: 12), child: _body(palette)),
            ),
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
        ChaoxingTimeNotice(activity: _activity),
        ChaoxingSignOutNotice(info: info, onOpenRelated: _busy ? null : _openRelated),
        if (_needsLocation) ...[
          const SizedBox(height: 16),
          Text('位置', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
          const SizedBox(height: 8),
          ChaoxingSignLocation(
            controller: widget.controller,
            manual: _manualLocation,
            selected: _savedLocation,
            latitude: _latitude,
            longitude: _longitude,
            address: _address,
            busy: _busy,
            onManual: (manual) => setState(() => _manualLocation = manual),
            onSelect: (location) => setState(() {
              _savedLocation = location;
              _address.text = location.address;
            }),
            onSave: () => unawaited(_saveLocation()),
            onPickOnMap: () => unawaited(_pickOnMap()),
            // 地图点出来的位置不带名称，名称框里写的照旧用。
            onMapPicked: (location) => setState(() {
              _savedLocation = location;
              _error = null;
            }),
            rangeCenter: _rangeCenter,
            rangeMeters: info.locationRange.toDouble(),
          ),
        ],
        if (_needsCode) ...[
          SizedBox(height: campusFieldGap(context)),
          // 校验方式两档（[人工决策-2026-10-08 16:39:31]）：普通=输码经服务端校验；绕过=不输码直接提交。
          CampusSegmented<bool>(
            values: const [false, true],
            label: (bypass) => bypass ? '绕过' : '普通',
            selected: _bypassCode,
            onSelected: (bypass) => setState(() {
              _bypassCode = bypass;
              _codeWrong = false;
            }),
          ),
          if (_bypassCode) ...[
            const SizedBox(height: 12),
            Text('该模式可能失效，请不要过度依赖此模式', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
          ] else ...[
            const SizedBox(height: 12),
            if (_type == ChaoxingSignType.gesture) ...[
              // 手势签到画 3×3 图案（对齐学习通客户端），画完自动校验并提交。
              ChaoxingGestureField(
                onCompleted: (pattern) {
                  _code.text = pattern;
                  unawaited(_start());
                },
                error: _codeWrong ? '手势码不对' : null,
              ),
            ] else ...[
              // 签到码按位数显示格子，输满自动校验并提交；位数未知时退回普通输入框。
              if (info.signCodeLength > 0)
                ChaoxingCodeCells(controller: _code, length: info.signCodeLength, onFilled: () => unawaited(_start()), error: _codeWrong ? '签到码不对' : null)
              else
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: '签到码'),
                ),
            ],
          ],
        ],
        if (_multi) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: Text('签到对象', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant))),
              TextButton.icon(
                onPressed: _busy || _batch.targets.every((target) => target.done)
                    ? null
                    : () => setState(() {
                      final allSelected = _batch.targets.where((target) => !target.done).every((target) => target.selected);
                      for (final target in _batch.targets) {
                        if (!target.done) target.selected = !allSelected;
                      }
                    }),
                icon: CampusIcon(_batch.targets.where((target) => !target.done).every((target) => target.selected) ? CampusIcons.close : CampusIcons.check),
                label: Text(
                  _batch.targets.where((target) => !target.done).every((target) => target.selected) ? '全不选' : '全选',
                ),
              ),
            ],
          ),
          if (_tagChips(palette) case final chips when chips.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: chips),
          ],
          // 好几个人都还缺照片时，一次从相册选齐（每人一行的按钮照旧能单独换）。
          if (_needsPhoto && widget.pickImages != null)
            if (_missingPhotos() case final missing when missing.length > 1) ...[
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _pickPhotos(missing),
                  icon: const CampusIcon(CampusIcons.images),
                  label: Text('从相册选 ${missing.length} 张'),
                ),
              ),
            ],
          const SizedBox(height: 8),
          for (final target in _batch.targets) _targetRow(palette, target),
        ] else ...[
          if (_needsPhoto) ...[
            const SizedBox(height: 16),
            // 普通签到老师勾了拍照才要照片（列表里只叫「普通签到」），这里说清楚。
            Text('这场签到要交一张照片', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _pickPhoto(single, source: ImageSource.camera),
                  icon: const CampusIcon(CampusIcons.camera),
                  label: const Text('现拍一张'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _pickPhoto(single),
                  icon: const CampusIcon(CampusIcons.image),
                  label: Text(single.photoName ?? '从相册选'),
                ),
              ],
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
          if (single.state == ChaoxingTargetState.failed || single.state == ChaoxingTargetState.idle && single.needsRepair)
            _failureActions(palette, single, inline: false),
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

  // 按标签一起勾选（同参考项目）：带这个标签、还没签好的人全勾上时标签算选中，再点一起取消；没人带的标签不列。
  List<Widget> _tagChips(CampusPalette palette) {
    final controller = widget.controller;
    return [
      for (final tag in controller.tags)
        if (_batch.targets.where((target) => !target.done && controller.hasTag(target.record, tag)).toList() case final tagged when tagged.isNotEmpty)
          CampusGlassChip(
            label: tag.name,
            selected: tagged.every((target) => target.selected),
            leading: CampusIcon(CampusIcons.tag, size: 18, color: palette.tagColors[tag.colorIndex]),
            onSelected: _busy ? null : (selected) => setState(() {
              for (final target in tagged) {
                target.selected = selected;
              }
            }),
          ),
    ];
  }

  // 每个签到对象一行：勾选、名字与状态，拍照/人脸要的输入，失败时的操作。
  Widget _targetRow(CampusPalette palette, ChaoxingSignTarget target) {
    final record = target.record;
    final statusText = switch (target.state) {
      ChaoxingTargetState.idle => [?widget.controller.ownerLabelOf(record), ?record.sessionLabel, ?record.deviceCodeLabel].join(' · '),
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
                    Text(record.displayName, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface)),
                    // 没开签时只写例外（「主账号」「代签账号 · 固定随机设备码」，都没有就不占这一行），开签后这一行换成状态。
                    if (target.state == ChaoxingTargetState.idle && statusText.isNotEmpty)
                      DotSeparatedText(statusText, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant))
                    else if (target.state != ChaoxingTargetState.idle)
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
              // 签到中的加载与签好的勾原地交替淡入，不突然换图。
              AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 200),
                child: switch (target.state) {
                  ChaoxingTargetState.signing => const CampusLoader(key: ValueKey('signing'), size: 20, delay: Duration.zero),
                  ChaoxingTargetState.succeeded => const CampusIcon(CampusIcons.success, key: ValueKey('succeeded')),
                  _ => const SizedBox.shrink(key: ValueKey('idle')),
                },
              ),
            ],
          ),
          if (target.selected && !target.done && (_needsPhoto || _needsFace))
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (_needsPhoto) ...[
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _pickPhoto(target, source: ImageSource.camera),
                      icon: const CampusIcon(CampusIcons.camera),
                      label: const Text('现拍'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _pickPhoto(target),
                      icon: const CampusIcon(CampusIcons.image),
                      label: Text(target.photoName ?? '选照片'),
                    ),
                  ],
                  if (_needsFace)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _pickFace(target),
                      icon: const CampusIcon(CampusIcons.scanFace),
                      label: Text(target.faceObjectId == null ? '人脸照片：用存着的' : '人脸照片：已另选'),
                    ),
                ],
              ),
            ),
          // 登录已失效的人还没开签就给「重新登录」，不用等提交失败。
          if (target.state == ChaoxingTargetState.failed || target.state == ChaoxingTargetState.idle && target.needsRepair)
            _failureActions(palette, target, inline: true),
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
        if (!inline) Text(target.message ?? target.record.sessionLabel ?? '', style: TextStyle(fontSize: 14, color: palette.danger)),
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

  String _windowText() {
    final end = _activity.endTime;
    if (end == null) return _activity.ongoing ? '进行中' : '已结束';
    return '截止 ${formatCampusTimestamp(end.toIso8601String())}';
  }
}
