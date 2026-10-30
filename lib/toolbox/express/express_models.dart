import 'dart:convert';

// 拼多多取快递 / 身份码接口的常量与 entry_source 枚举，来自 mdkd H5（取快递、身份码页）的运行期分析。
// 协议按授权账号的互操作场景独立重写，不生成也不绕过拼多多的反爬与风控字段。
abstract final class PddConstants {
  static const apiBase = 'https://api.pinduoduo.com';
  static const loginPage = 'https://mobile.yangkeduo.com/login.html';
  // 拉起微信用公开的 weixin:// 链接（只能打开微信首页，打不开指定网页：那要接微信开放平台 SDK 并登记 AppID）。
  static const weChatScheme = 'weixin://';
  static const mdkdReferer = 'https://m.pinduoduo.net/mdkd/package?pr_page_from=scheme';
  static const idCodeReferer = 'https://m.pinduoduo.net/mdkd/package?pr_page_from=scheme&tab=ID_CODE';

  // 驿站待取件 entry_source：8 普通入口，4 扫驿站二维码进入（带 station_code）。
  static const entryScan = 4;
  static const entryOther = 8;

  // 绑定取件手机号的流程常量（mdkd 绑定弹窗）：protocol_code 与 scene 固定，mobile_type 区分「输入新号」与「用已有 mobile_id」。
  // [人工决策-2026-10-20 17:22:42] 实测绑定/解绑的 francis、apoc、lobit 接口都经风控，缺 anti_content 会 403/参数错；
  // 逆向确认 anti_content 只能在 WebView 里由拼多多自己的反爬 JS 现场生成（纯 Dart 生成不了）。用户选「原生绑定 + 隐藏 WebView 取 anti_content」，
  // 原模块「不生成也不绕过反爬字段」在此让步——仅用于本人已授权账号的取件手机号绑定/解绑，用官方 JS 产出合法 anti_content、不自行重写风控。
  // anti_content 有时效：每次请求前现生成、不缓存（见 express_anti_content.dart）。多数接口放 anti-content 请求头；解绑/别名另在 body 的 anti_content 再带一份。
  // [人工决策-2026-10-30 18:03:16] 10-29 起用户账号查物流一律回 1011「手机网络繁忙」，当时推断是缺 anti-content（官方 mdkd 的请求封装每个请求都带），
  // 用户选「查物流也带 anti-content」（未选「先打诊断包确认原因」「只修点物流、补查不带」），用途扩成取件手机号绑定/解绑与查物流（只读）。
  // [人工决策-2026-10-30 18:43:18] 真机三轮诊断推翻了上面的推断：失败的是「近一周已取出」的件（链接里 order_sn、source_type 为空，走 GET 通用物流），
  // 带不带 anti-content、带不带空的 source_type 都回 1011，官方 App 里同一件能看（走 App 原生网络层）。用户选「保留，照官方每个请求都带」（未选撤回）：
  // 查物流照旧带，不再当成 1011 的修法；驿站、身份码等其余查询仍不带。
  // [人工决策-2026-10-30 22:51:44] 用户换账号后已取出的件能正常查物流，1011 是那个账号的问题（不是网页通道拿不到）；已取出的件照旧在应用里查，见 express_page.dart 里 recentPackages 处。
  static const antiContentHeader = 'anti-content';
  static const bindProtocolCode = 'QJXXJSFWTK1_1';
  static const bindSmsScene = '1000123';
  static const bindBoxPopupService = 'express_assistant';
  // entry_source 派生（逆向结论）：身份码入口的快速绑定发 "4"；新绑定（cellPhoneList 口径）发 "APP"。
  static const fastBindEntrySource = '4';
  static const newBindEntrySource = 'APP';
  static const mobileTypeMobile = 1;
  static const mobileTypeMobileId = 2;
  // 生成 anti_content 用的官方页（已加载反爬 bundle）。
  static const antiContentPage = 'https://m.pinduoduo.net/mdkd/package?pr_page_from=scheme';

  // 官方安全验证页（接口回 54001 时官方 mdkd 页面跳去的同一个页面），验证完跳回 from 指定的地址；from 填官方 mdkd 页，跳到它就算通过。
  static const verifyPage = 'https://m.yangkeduo.com/psnl_verification.html';
  static const verifyReturn = 'https://m.pinduoduo.net/mdkd/package';

  // 接口没返回 expire_mills 时按页面同款缺省值刷新。
  static const defaultExpireMills = 600000;

  static const userAgent =
      'android Mozilla/5.0 (Linux; Android 14; sdk_gphone64_x86_64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
      'Chrome/113.0.5672.136 Mobile Safari/537.36';
}

// 账号会话：登录态等同账号，只进系统安全存储（见 express_vault.dart），不打印、不进业务库。
// PDDAccessToken 是 HttpOnly Cookie，JS 读不到，但原生 CookieManager 可读（见 express_login_webview.dart）。
class PddSession {
  const PddSession({
    this.accessToken = '',
    this.cookie = '',
    this.installToken = '',
    this.etag = '',
    this.userId = '',
    this.nickname,
    this.pickupMobile,
    this.pickupMore = false,
  });

  final String accessToken;
  final String cookie;
  final String installToken;
  final String etag;
  final String userId;
  // 账号卡用来认出是哪个账号的两项（见 ExpressController._fillAccount）：拼多多昵称与常用取件手机号（拼多多只给打码的号），
  // pickupMore 表示还绑了别的号。null 是还没读过（刚登录，或加这两项之前登录的会话），空串是读过但拼多多没给（没昵称、没绑号）。
  final String? nickname;
  final String? pickupMobile;
  final bool pickupMore;

  bool get isValid => accessToken.isNotEmpty || cookie.isNotEmpty;

  PddSession withAccount({String? nickname, String? pickupMobile, bool? pickupMore}) => PddSession(
    accessToken: accessToken,
    cookie: cookie,
    installToken: installToken,
    etag: etag,
    userId: userId,
    nickname: nickname ?? this.nickname,
    pickupMobile: pickupMobile ?? this.pickupMobile,
    pickupMore: pickupMore ?? this.pickupMore,
  );

  // 身份码与快递接口的请求头：AccessToken 或账号 Cookie 二者其一即可（实测不强制 anti-token）。
  Map<String, String> headers({required String referer}) {
    final result = <String, String>{
      'Content-Type': 'application/json;charset=UTF-8',
      'Referer': referer,
      'User-Agent': PddConstants.userAgent,
    };
    if (accessToken.isNotEmpty) result['AccessToken'] = accessToken;
    if (cookie.isNotEmpty) result['Cookie'] = cookie;
    if (etag.isNotEmpty) result['ETag'] = etag;
    return result;
  }

  Map<String, Object?> toJson() => {
    'accessToken': accessToken,
    'cookie': cookie,
    'installToken': installToken,
    'etag': etag,
    'userId': userId,
    'nickname': nickname,
    'pickupMobile': pickupMobile,
    'pickupMore': pickupMore,
  };

  // 存储里的会话按外部输入读：字段缺失当空串，坏了由上层当作未登录处理。
  factory PddSession.fromJson(Map<String, Object?> json) => PddSession(
    accessToken: '${json['accessToken'] ?? ''}',
    cookie: '${json['cookie'] ?? ''}',
    installToken: '${json['installToken'] ?? ''}',
    etag: '${json['etag'] ?? ''}',
    userId: '${json['userId'] ?? ''}',
    nickname: json['nickname'] is String ? '${json['nickname']}' : null,
    pickupMobile: json['pickupMobile'] is String ? '${json['pickupMobile']}' : null,
    pickupMore: json['pickupMore'] == true,
  );

  String encode() => jsonEncode(toJson());

  factory PddSession.decode(String raw) => PddSession.fromJson(jsonDecode(raw) as Map<String, Object?>);
}

// 快递接口失败分类：页面只按 code 分支，message 只用来展示。
// verifyRequired 是拼多多风控要用户本人先过一次官方安全验证（错误码 54001，带 verify_auth_token），verifyToken 就是这个令牌。
enum ExpressFailureCode { notLoggedIn, verifyRequired, network, timeout, tooLarge, server, invalidResponse }

class ExpressFailure implements Exception {
  const ExpressFailure(this.code, this.message, {this.verifyToken = ''});
  final ExpressFailureCode code;
  final String message;
  final String verifyToken;

  bool get isNotLoggedIn => code == ExpressFailureCode.notLoggedIn;

  @override
  String toString() => 'ExpressFailure(${code.name}): $message';
}

// 身份码返回的手机号信息（展示与「更换」链接）。
class PddMobileInfo {
  const PddMobileInfo({this.desc = '', this.linkText = '', this.linkUrl = ''});
  final String desc;
  final String linkText;
  final String linkUrl;

  factory PddMobileInfo.fromJson(Map<String, Object?> json) => PddMobileInfo(
    desc: '${json['mobile_info_desc'] ?? ''}',
    linkText: '${json['link_text'] ?? ''}',
    linkUrl: '${json['link_url'] ?? ''}',
  );
}

// 身份码结果：码值由服务端生成（格式观测为 dd + yyyyMMdd + 数字串），expireMills 是当前码的剩余有效期。
// 身份码是取件凭证、短时有效，不落盘、不打印、不上传。
class IdentityCodeResult {
  const IdentityCodeResult({required this.identificationCode, required this.expireMills, this.mobileInfo});
  final String identificationCode;
  final int expireMills;
  final PddMobileInfo? mobileInfo;

  // 到期后按剩余有效期重新请求即可拿到新码。
  Duration get refreshAfter => Duration(milliseconds: expireMills);

  factory IdentityCodeResult.fromJson(Map<String, Object?> json) {
    final expire = json['expire_mills'];
    final mobile = json['mobile_info'];
    return IdentityCodeResult(
      identificationCode: '${json['identification_code'] ?? ''}',
      expireMills: expire is num ? expire.toInt() : PddConstants.defaultExpireMills,
      mobileInfo: mobile is Map ? PddMobileInfo.fromJson(mobile.cast<String, Object?>()) : null,
    );
  }
}

// 已绑定的取件手机号（服务端返回打码后的号码）。mobileIdScene 解绑时要回传；commonlyUsed 是拼多多标的常用号。
class PddBoundMobile {
  const PddBoundMobile({this.mobileId = '', this.maskedMobile = '', this.alias = '', this.mobileIdScene, this.commonlyUsed = false});
  final String mobileId;
  final String maskedMobile;
  final String alias;
  final int? mobileIdScene;
  final bool commonlyUsed;

  factory PddBoundMobile.fromJson(Map<String, Object?> json) => PddBoundMobile(
    mobileId: '${json['mobile_id'] ?? ''}',
    maskedMobile: '${json['mock_mobile'] ?? ''}',
    alias: '${json['alias'] ?? ''}',
    mobileIdScene: (json['mobile_id_scene'] as num?)?.toInt(),
    commonlyUsed: json['commonly_used'] == true,
  );
}

// 绑定取件手机号的预检查结果（只读）：是否已绑定、可一键快速绑定的已有号 mobileId 与场景、本账号手机号。
// 本账号手机号按官方绑定弹窗读 mobile_des（打码，弹窗里写成本账号的号）；身份码接口的 mobile_info_desc 是另一段说明文字，预检查里没有。
class PddBindPreCheck {
  const PddBindPreCheck({this.hasBound = false, this.mobileId = '', this.mobileIdScene, this.mobileDesc = ''});
  final bool hasBound;
  final String mobileId;
  final int? mobileIdScene;
  final String mobileDesc;

  // 预检查给了已有号 mobileId 就能走免短信的快速绑定。
  bool get canFastBind => mobileId.isNotEmpty;

  factory PddBindPreCheck.fromJson(Map<String, Object?> json) => PddBindPreCheck(
    hasBound: json['has_binding_express_mobile'] == true,
    mobileId: '${json['mobile_id'] ?? ''}',
    mobileIdScene: (json['mobile_id_scene'] as num?)?.toInt(),
    mobileDesc: '${json['mobile_des'] ?? ''}',
  );
}

// 无待取件时服务端给的手机尾号信息。
class PddNoPackageMobileInfo {
  const PddNoPackageMobileInfo({this.mobileList = const [], this.largerThanTwo = false});
  final List<String> mobileList;
  final bool largerThanTwo;

  factory PddNoPackageMobileInfo.fromJson(Map<String, Object?> json) {
    final list = json['mobileList'];
    return PddNoPackageMobileInfo(
      mobileList: list is List ? list.map((entry) => '$entry').toList() : const [],
      largerThanTwo: json['largerThan2'] == true,
    );
  }
}

List<Map<String, Object?>> _mapList(Object? value) =>
    value is List ? value.whereType<Map>().map((entry) => entry.cast<String, Object?>()).toList() : const [];

// 查一件包裹物流要的参数，同官方物流页（/track）读它链接里的：带 order_sn（驿站包裹的记录号）的查驿站物流，按 order_sn、source_type 与 entry_source；
// 没有的按 tracking_number、shipping_id 与可选的 source_type 查（见 ExpressClient.queryShippingTrack）。
typedef ExpressTrackQuery = ({String trackingNumber, String shippingId, String sourceType, String orderSn, String entrySource});

// 官方点一件包裹是带着它的 jump_url（/track?order_sn=…&source_type=…）进物流页，所以参数先取 jump_url 里的，没有再用条目自己的字段。
ExpressTrackQuery _trackQueryOf(Map<String, Object?> json) {
  final jump = Uri.tryParse('${json['jump_url'] ?? ''}')?.queryParameters ?? const <String, String>{};
  String field(String key) => jump[key] ?? '${json[key] ?? ''}';
  return (trackingNumber: field('tracking_number'), shippingId: field('shipping_id'), sourceType: field('source_type'), orderSn: field('order_sn'), entrySource: field('entry_source'));
}

// 驿站里的一件待取包裹（combine_track_list 的一项），字段按官方 mdkd 包裹卡片的渲染取。
class StationPackage {
  const StationPackage({this.pickCode = '', this.shippingName = '', this.trackingNumber = '', this.mobileAlias = '', this.shippingId = '', required this.trackQuery});
  final String pickCode;
  final String shippingName;
  final String trackingNumber;
  final String mobileAlias;
  final String shippingId;
  final ExpressTrackQuery trackQuery;

  // 取件码有时带「取件码」前缀，官方页面去掉前缀再显示。
  factory StationPackage.fromJson(Map<String, Object?> json) => StationPackage(
    pickCode: '${json['pick_code'] ?? ''}'.replaceAll('取件码', '').trim(),
    shippingName: '${json['shipping_name'] ?? ''}',
    trackingNumber: '${json['tracking_number'] ?? ''}',
    mobileAlias: '${json['mobile_alias'] ?? ''}',
    shippingId: '${json['shipping_id'] ?? ''}',
    trackQuery: _trackQueryOf(json),
  );
}

// 近一周已取出的一件（package_out_list 的一项）：官方弹层写取件地址、取件时间（服务端给好的文字）、快递公司与运单号，点一项同样经它的 jump_url 进物流页。
class StationOutPackage {
  const StationOutPackage({this.address = '', this.operateTime = '', this.shippingName = '', this.trackingNumber = '', required this.trackQuery});
  final String address;
  final String operateTime;
  final String shippingName;
  final String trackingNumber;
  final ExpressTrackQuery trackQuery;

  factory StationOutPackage.fromJson(Map<String, Object?> json) => StationOutPackage(
    address: '${json['address'] ?? ''}',
    operateTime: '${json['operate_time'] ?? ''}',
    shippingName: '${json['shipping_name'] ?? ''}',
    trackingNumber: '${json['tracking_number'] ?? ''}',
    trackQuery: _trackQueryOf(json),
  );
}

// 一条物流轨迹：info 是描述、time 是服务端给好的时间文字；官方按返回顺序列出，第一条是最新的。
class ShippingTrace {
  const ShippingTrace({this.info = '', this.time = ''});
  final String info;
  final String time;

  factory ShippingTrace.fromJson(Map<String, Object?> json) => ShippingTrace(info: '${json['info'] ?? ''}', time: '${json['time'] ?? ''}');
}

// 物流详情（两个物流接口返回的 shipping，字段一样）：快递公司、运单号、预计送达说明、轨迹与这件寄到的手机尾号。
// 派件员姓名电话（postman_info/postman_contact）是第三方个人信息，不读。
class ShippingTrack {
  const ShippingTrack({this.shippingName = '', this.trackingNumber = '', this.forecast = '', this.traces = const [], this.ownerTail = ''});
  final String shippingName;
  final String trackingNumber;
  final String forecast;
  final List<ShippingTrace> traces;
  // 这件寄到哪个手机号的尾号：驿站查询不给，只有物流接口的 package_info 写「尾号5678 的快递」（10-22 真机），取出数字；格式对不上就当不知道。
  final String ownerTail;

  factory ShippingTrack.fromJson(Map<String, Object?> json) {
    final forecast = json['time_forecast'];
    return ShippingTrack(
      shippingName: '${json['shipping_name'] ?? ''}',
      trackingNumber: '${json['tracking_number'] ?? ''}',
      forecast: forecast is Map ? '${forecast['time_forecast_desc'] ?? ''}' : '',
      traces: _mapList(json['traces']).map(ShippingTrace.fromJson).toList(),
      ownerTail: RegExp(r'尾号\s*(\d{3,4})').firstMatch('${json['package_info'] ?? ''}')?.group(1) ?? '',
    );
  }
}

// 一家驿站的待取件（combine_list 的一项）：company_name 是站名；station_delivery_track_list 是已安排送货上门的件，官方只显示件数。
// 组里的包裹在官方 H5 里是 combine_track_list；10-21 审阅移交包说 App 版是 list。两边都没有真实非空样本，所以先读前者、没有再读后者。
class StationPackageGroup {
  const StationPackageGroup({this.stationName = '', this.address = '', this.packages = const [], this.deliveryCount = 0});
  final String stationName;
  final String address;
  final List<StationPackage> packages;
  final int deliveryCount;

  factory StationPackageGroup.fromJson(Map<String, Object?> json) {
    final tracks = _mapList(json['combine_track_list']);
    return StationPackageGroup(
      stationName: '${json['company_name'] ?? ''}',
      address: '${json['address'] ?? ''}',
      packages: (tracks.isNotEmpty ? tracks : _mapList(json['list'])).map(StationPackage.fromJson).toList(),
      deliveryCount: _mapList(json['station_delivery_track_list']).length,
    );
  }
}

// 驿站待取件查询结果，字段按官方 mdkd 包裹页取：combine_list 按驿站分组，count 是待取件数；
// 没有待取件时 no_package_mobile_info 给查过的手机尾号（官方只显示前两个，largerThan2 表示还有更多）。
// 带驿站码查时有 station_name；only_wx_scan 为真表示拼多多把这个账号划进了只能微信扫码取件的实验组（账号级，官方此时整页只提示用微信扫码）。
class StationPackagesResult {
  const StationPackagesResult({this.count = 0, this.groups = const [], this.recentPackages = const [], this.noPackageMobileInfo, this.stationName = '', this.onlyWxScan = false});
  final int count;
  final List<StationPackageGroup> groups;
  // 近一周已取出（package_out_list），不算进待取件数。
  final List<StationOutPackage> recentPackages;
  final PddNoPackageMobileInfo? noPackageMobileInfo;
  final String stationName;
  final bool onlyWxScan;

  // 外部响应按边界容错：count 缺失时按列表里的件数算。
  int get total => count > 0 ? count : groups.fold(0, (sum, group) => sum + group.packages.length + group.deliveryCount);

  factory StationPackagesResult.fromJson(Map<String, Object?> json) {
    final noPackage = json['no_package_mobile_info'];
    final count = json['count'];
    return StationPackagesResult(
      count: count is num ? count.toInt() : 0,
      groups: _mapList(json['combine_list']).map(StationPackageGroup.fromJson).toList(),
      recentPackages: _mapList(json['package_out_list']).map(StationOutPackage.fromJson).toList(),
      noPackageMobileInfo: noPackage is Map ? PddNoPackageMobileInfo.fromJson(noPackage.cast<String, Object?>()) : null,
      stationName: '${json['station_name'] ?? ''}',
      onlyWxScan: json['only_wx_scan'] == true || json['only_wx_scan'] == 1,
    );
  }
}

// 扫到的驿站码。真实驿站二维码是带 station_code 参数的链接（https://mdkd.pinduoduo.com/weixin/package?station_code=…，
// 拼多多与微信扫同一张码）；官方页面从链接参数取 station_code，链接带 t 参数（动态码）时查询带 dynamic_qrcode=true。
typedef StationScan = ({String code, bool dynamicQr});

// 从链接、App 内链、JSON 或裸码里取站点码；取不到返回空——带协议头却没有 station_code 的链接不能当码发给服务端。
StationScan? parseStationScan(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  if (text.startsWith('{')) {
    try {
      final decoded = jsonDecode(text);
      final code = decoded is Map ? decoded['station_code'] ?? decoded['stationCode'] : null;
      return code is String && code.isNotEmpty ? (code: code, dynamicQr: false) : null;
    } on FormatException {
      return null;
    }
  }
  final uri = Uri.tryParse(text);
  if (uri != null && uri.hasScheme) {
    final code = uri.queryParameters['station_code'] ?? '';
    return code.isEmpty ? null : (code: code, dynamicQr: uri.queryParameters.containsKey('t'));
  }
  // 裸码只认字母、数字、下划线与连字符，别把随便一段文字当站点码发出去。
  return RegExp(r'^[A-Za-z0-9_-]{4,64}$').hasMatch(text) ? (code: text, dynamicQr: false) : null;
}

// 驿站的微信取件页（驿站二维码里的链接），给只能微信取件的账号生成二维码存相册用。
String weChatStationUrl(String stationCode) => Uri.https('mdkd.pinduoduo.com', '/weixin/package', {'station_code': stationCode}).toString();
