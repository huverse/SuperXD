import 'dart:convert';

import 'package:crypto/crypto.dart';

// 胖乖生活（com.qiekj.user 1.148.0）的请求协议（纯计算）：两个域名、报给胖乖的 App 版本与渠道、请求头的签名。
// 签名照官方 App（移交包 v2.3 的 Demo 与参考客户端，用户 11-27 在 Demo 上真机走通全流程）：
// 「appSecret=…&channel=android_app&timestamp=…&token=…&version=1.148.0&路径」取 SHA-256 十六进制。
// appSecret 是安装包里人人共用的客户端常量，不是谁的凭据（同住理生活的平台密钥写在 zhuli_protocol.dart）。

// 胖乖自己的接口（登录、设备、下单、付款，饮水机的合作方会话也经它取）。
const pangguaiApi = 'https://userapi.qiekj.com';
// 饮水机的合作方（水卡的充值档位）。
const pangguaiPartner = 'https://apwork.cn';
const pangguaiVersion = '1.148.0';
const pangguaiChannel = 'android_app';
const pangguaiUserAgent = 'QEUser/1.148.0 (com.qiekj.user; build:303; Android 13; userChannel:android_app; version:1.148.0) OkHttp/4.12.0';
// 请求头 phoneBrand：不读手机型号，报本应用的名字（同住理生活登录时机型报 SuperXD）。
const pangguaiBrand = 'SuperXD';
// 易盾人机验证的业务 ID（胖乖登录用的那个，官方 App 里公开的常量）。
const pangguaiCaptchaId = 'b4c768e8f7124211ac78783d2034e33f';
const _appSecret = 'nFU9pbG8YQoAe1kFh+E7eyrdlSLglwEJeA0wwHB1j5o=';

String pangguaiSign(String path, {required String token, required String timestamp}) =>
    _sha256('appSecret=$_appSecret&channel=$pangguaiChannel&timestamp=$timestamp&token=$token&version=$pangguaiVersion&$path');

// 下单的位置签名（请求头 orderRiskSign）：同上再按字母顺序加进品类、设备号与经纬度。
String pangguaiRiskSign(String path, {required String token, required String timestamp, required String category, required String imei, required String latitude, required String longitude}) =>
    _sha256('appSecret=$_appSecret&categoryCode=$category&channel=$pangguaiChannel&imei=$imei&lat=$latitude&lng=$longitude&timestamp=$timestamp&token=$token&version=$pangguaiVersion&$path');

String _sha256(String text) => sha256.convert(utf8.encode(text)).toString();
