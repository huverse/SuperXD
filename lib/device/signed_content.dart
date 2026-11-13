import 'dart:convert';
import 'dart:typed_data';

import 'package:superxd/domain/campus_crypto.dart';

// [人工决策-2026-11-10 12:58:34] 更新清单与开发者的话加签名（用户选定：现在就加签名、客户端内置公钥校验；HTTPS 等备案后再做，
// 没有备案域名短期上不了）。中转现在是明文 HTTP 加 IP 直连：安装包本身有 SHA-256 与签名证书核对、不怕改，但清单（最低可用版本可被改成
// 全员强制更新）与开发者的话（可被改成钓鱼文字）经过的每一跳都能改。
// 做法参照 Sparkle 的 EdDSA 更新签名与 TUF、DSSE：对「确切的字节」签名，不对重新序列化的 JSON 签名。信封是
// {signed: 载荷 UTF-8 JSON 字节的 base64url, signatures: [{keyId, sig}]}，任一受信公钥验过即可（便于轮换）；算法 Ed25519，
// 签名原文 = 内容类型的域前缀 + 载荷字节，两类内容的签名不能互相挪用（写法同私信协议的 SXD1-invite、SXD1-msg）。
// 签名挡不住冻结与回滚（中间人一直回放旧的清单或旧的信）：版本只升不降由已装版本号与系统安装器保证，冻结只能靠将来的 HTTPS；
// 载荷不带过期时间（没选：发版不定期，过期会让更新通道自己失效）。
// 新客户端只认验签通过的载荷，明文字段留给 1.0.0-alpha.15 及以前不验签的旧客户端。
// 2026-11-13 灰度配置（人工决策见 domain/rollout.dart）同样经明文 HTTP 下发、能改变客户端行为（分批更新的暂停与全量、功能开关），
// 按本条同样签名：第三类内容 rollout，由开发者的话那把钥（同在 relay 环境、同一类维护者内容）与离线备用钥签。
enum SignedContent {
  release('SXD1-release\n'),
  notes('SXD1-notes\n'),
  rollout('SXD1-rollout\n');

  const SignedContent(this.domain);
  final String domain;
}

class TrustedSigningKey {
  const TrustedSigningKey(this.keyId, this.publicKey, this.contents);
  final String keyId;
  // Ed25519 公钥 32 字节的 base64url（无填充）。
  final String publicKey;
  // 这把钥能签哪几类内容。
  final Set<SignedContent> contents;
}

// 内置的受信公钥，私钥都不在仓库里：
// - release：发版清单，私钥在 GitHub release 环境的机密 MANIFEST_SIGNING_KEY；
// - notes：开发者的话与灰度配置，私钥在 relay 环境的机密 NOTES_SIGNING_KEY；
// - offline：离线备用，私钥只在维护者本机，三类都受信；线上钥丢失或泄露时用它签一版换钥（步骤见 CONTRIBUTING.md）。
// 发版与 notes 流水线签完用这张表与客户端的解析代码再验一遍（tool/content_signing.dart），机密里的私钥和这里的公钥对不上就停。
const trustedSigningKeys = [
  TrustedSigningKey('release-2026-11', 'gCb1CCRvjVPWWDiVmUKY93Y2TGCObCx3Z8BHqd1194E', {SignedContent.release}),
  TrustedSigningKey('notes-2026-11', 'SKpm-cUy-FYmrldyyjRZE-mIdU6Jt4ODG6ULf1XZEwk', {SignedContent.notes, SignedContent.rollout}),
  TrustedSigningKey('offline-2026-11', 'tab0o-Uwvm8JQs6WwxnuBKN3fVu4y2txxU-f9eKzs6o', {SignedContent.release, SignedContent.notes, SignedContent.rollout}),
];

// 一个信封最多几个签名（换钥时新旧两把各签一份，留余量）；中转按同一上限校验（server/src/modules/app_release/app_release.dto.ts）。
const signedEnvelopeSignatureMax = 4;

final keyIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,31}$');

// 验不过时的原因：missing 没有信封，malformed 信封格式不对，unverified 没有一个受信公钥验得过。
class SignedEnvelopeException implements Exception {
  const SignedEnvelopeException(this.reason);
  final String reason;
  @override
  String toString() => 'SignedEnvelopeException($reason)';
}

// 签名原文：域前缀加载荷原样的字节。
Uint8List signedMessage(SignedContent content, List<int> payload) => Uint8List.fromList([...utf8.encode(content.domain), ...payload]);

// 信封是外部输入：逐项校验，返回验过的载荷字节；只认 keys 里能签这类内容的公钥，不认识的 keyId 跳过。
Future<Uint8List> openSignedEnvelope(Object? envelope, SignedContent content, {List<TrustedSigningKey> keys = trustedSigningKeys}) async {
  if (envelope == null) throw const SignedEnvelopeException('missing');
  if (envelope case {'signed': final String signed, 'signatures': final List<Object?> signatures}
      when signatures.isNotEmpty && signatures.length <= signedEnvelopeSignatureMax) {
    final payload = tryDecodeBase64UrlNoPad(signed);
    if (payload == null) throw const SignedEnvelopeException('malformed');
    final message = signedMessage(content, payload);
    for (final item in signatures) {
      if (item case {'keyId': final String keyId, 'sig': final String sig} when keyIdPattern.hasMatch(keyId)) {
        final signature = tryDecodeBase64UrlNoPad(sig, length: 64);
        if (signature == null) throw const SignedEnvelopeException('malformed');
        for (final key in keys.where((key) => key.keyId == keyId && key.contents.contains(content))) {
          if (await verifyEd25519(tryDecodeBase64UrlNoPad(key.publicKey, length: 32)!, message, signature)) return payload;
        }
      } else {
        throw const SignedEnvelopeException('malformed');
      }
    }
    throw const SignedEnvelopeException('unverified');
  }
  throw const SignedEnvelopeException('malformed');
}
