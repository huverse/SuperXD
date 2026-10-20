import 'dart:convert';

// 拼多多取快递 / 身份码接口的常量与 entry_source 枚举，来自 mdkd H5（取快递、身份码页）的运行期分析。
// 协议按授权账号的互操作场景独立重写，不生成也不绕过拼多多的反爬与风控字段。
abstract final class PddConstants {
  static const apiBase = 'https://api.pinduoduo.com';
  static const loginPage = 'https://mobile.yangkeduo.com/login.html';
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
  const PddSession({this.accessToken = '', this.cookie = '', this.installToken = '', this.etag = '', this.userId = ''});

  final String accessToken;
  final String cookie;
  final String installToken;
  final String etag;
  final String userId;

  bool get isValid => accessToken.isNotEmpty || cookie.isNotEmpty;

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
  };

  // 存储里的会话按外部输入读：字段缺失当空串，坏了由上层当作未登录处理。
  factory PddSession.fromJson(Map<String, Object?> json) => PddSession(
    accessToken: '${json['accessToken'] ?? ''}',
    cookie: '${json['cookie'] ?? ''}',
    installToken: '${json['installToken'] ?? ''}',
    etag: '${json['etag'] ?? ''}',
    userId: '${json['userId'] ?? ''}',
  );

  String encode() => jsonEncode(toJson());

  factory PddSession.decode(String raw) => PddSession.fromJson(jsonDecode(raw) as Map<String, Object?>);
}

// 快递接口失败分类：页面只按 code 分支，message 只用来展示。
enum ExpressFailureCode { notLoggedIn, network, timeout, tooLarge, server, invalidResponse }

class ExpressFailure implements Exception {
  const ExpressFailure(this.code, this.message);
  final ExpressFailureCode code;
  final String message;

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

// 已绑定的取件手机号（服务端返回打码后的号码）。mobileIdScene 解绑时要回传。
class PddBoundMobile {
  const PddBoundMobile({this.mobileId = '', this.maskedMobile = '', this.alias = '', this.mobileIdScene});
  final String mobileId;
  final String maskedMobile;
  final String alias;
  final int? mobileIdScene;

  factory PddBoundMobile.fromJson(Map<String, Object?> json) => PddBoundMobile(
    mobileId: '${json['mobile_id'] ?? ''}',
    maskedMobile: '${json['mock_mobile'] ?? ''}',
    alias: '${json['alias'] ?? ''}',
    mobileIdScene: (json['mobile_id_scene'] as num?)?.toInt(),
  );
}

// 绑定取件手机号的预检查结果（只读）：是否已绑定、可一键快速绑定的已有号 mobileId 与场景、脱敏展示。
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
    mobileDesc: '${json['mobile_info_desc'] ?? ''}',
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

// 驿站待取件查询结果。测试账号当时无待取件，非空包裹列表的真实结构未实测，
// 故保留 raw 供调用方按真实返回读取，count 与手机尾号两处已核对。
class StationPackagesResult {
  const StationPackagesResult({this.count = 0, this.noPackageMobileInfo, this.packages = const [], this.raw = const {}});
  final int count;
  final PddNoPackageMobileInfo? noPackageMobileInfo;
  final List<Map<String, Object?>> packages;
  final Map<String, Object?> raw;

  factory StationPackagesResult.fromJson(Map<String, Object?> json) {
    List<Map<String, Object?>> parseList(Object? value) =>
        value is List ? value.whereType<Map>().map((entry) => entry.cast<String, Object?>()).toList() : const [];
    final packages = [
      ...parseList(json['list']),
      ...parseList(json['package_list']),
      ...parseList(json['recently_packages']),
      ...parseList(json['packages']),
    ];
    final noPackage = json['no_package_mobile_info'];
    final count = json['count'];
    return StationPackagesResult(
      count: count is num ? count.toInt() : 0,
      noPackageMobileInfo: noPackage is Map ? PddNoPackageMobileInfo.fromJson(noPackage.cast<String, Object?>()) : null,
      packages: packages,
      raw: json,
    );
  }
}
