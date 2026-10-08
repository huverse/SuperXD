import { HttpStatus } from '@nestjs/common';

// 错误码登记表：客户端只按 code 分支，message 只用于日志与排查。新错误码先在这里登记，并同步客户端：
// 私信看 lib/social/relay_client.dart 的 RelayCode，代签看 lib/toolbox/chaoxing/chaoxing_pack_client.dart 的 _failure。
export const RelayCode = {
  invalidRequest: 'INVALID_REQUEST', // 请求体或参数不合法
  unauthorized: 'UNAUTHORIZED', // 缺签名、签名错误或设备未注册
  clockSkew: 'CLOCK_SKEW', // 时间戳偏差过大，响应附 serverTime 供客户端校时
  replayed: 'REPLAYED', // 随机数重复，疑似重放
  deviceMismatch: 'DEVICE_MISMATCH', // 设备号与签名公钥不符
  rateLimited: 'RATE_LIMITED', // 触发限流，响应附 retryAfter 秒
  inviteNotFound: 'INVITE_NOT_FOUND', // 邀请不存在、已过期或已作废
  inviteSelf: 'INVITE_SELF', // 扫了自己的二维码
  inviteProofInvalid: 'INVITE_PROOF_INVALID', // 邀请凭证校验失败
  friendLimit: 'FRIEND_LIMIT', // 任一方好友数已满
  notFriend: 'NOT_FRIEND', // 双方不是好友（含已被对方删除）
  peerNotFound: 'PEER_NOT_FOUND', // 对方设备不存在
  envelopeTooLarge: 'ENVELOPE_TOO_LARGE', // 密文超过上限
  mailboxFull: 'MAILBOX_FULL', // 对方待取消息已满
  packNotFound: 'PACK_NOT_FOUND', // 代签凭据包不存在、已被取走或已过期
  internal: 'INTERNAL', // 未预期的服务端错误
} as const;

export type RelayCodeValue = (typeof RelayCode)[keyof typeof RelayCode];

export class RelayError extends Error {
  constructor(
    readonly code: RelayCodeValue,
    readonly status: HttpStatus,
    message: string,
    readonly extra: Record<string, unknown> = {},
  ) {
    super(message);
  }
}
