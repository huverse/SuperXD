import { HttpStatus, Injectable, Logger } from '@nestjs/common';

import { RelayCode, RelayError } from 'src/common/relay_error';
import { inviteTtlSeconds } from 'src/common/relay_limits';
import { decodeBase64url, ed25519Key, inviteProofCanonical, verifyEd25519 } from 'src/common/crypto/relay_crypto';
import { InviteStore } from 'src/modules/invite/invite.store';

@Injectable()
export class InviteService {
  private readonly logger = new Logger('Invite');

  constructor(private readonly invites: InviteStore) {}

  async create(ownerDeviceId: string, inviteId: string, publicKey: string) {
    await this.invites.create(ownerDeviceId, inviteId, publicKey);
    this.logger.debug(`[Invite] action=create ownerDeviceId=${ownerDeviceId}`);
    return Date.now() + inviteTtlSeconds * 1000;
  }

  revoke(ownerDeviceId: string, inviteId: string) {
    return this.invites.revoke(ownerDeviceId, inviteId);
  }

  // 校验扫码方的邀请凭证，返回邀请人设备号。邀请在有效期内可被多人使用。
  async verify(inviteId: string, redeemerDeviceId: string, proof: string) {
    const invite = await this.invites.find(inviteId);
    if (invite === null) throw new RelayError(RelayCode.inviteNotFound, HttpStatus.NOT_FOUND, '邀请已过期');
    if (invite.ownerDeviceId === redeemerDeviceId) throw new RelayError(RelayCode.inviteSelf, HttpStatus.BAD_REQUEST, '不能添加自己');
    const signature = decodeBase64url(proof, 64);
    if (signature === null || !verifyEd25519(ed25519Key(decodeBase64url(invite.publicKey, 32)!), inviteProofCanonical(inviteId, redeemerDeviceId), signature)) {
      throw new RelayError(RelayCode.inviteProofInvalid, HttpStatus.FORBIDDEN, '邀请凭证无效');
    }
    return invite.ownerDeviceId;
  }
}
