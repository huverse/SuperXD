import 'package:superxd/toolbox/chaoxing/chaoxing_accounts.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_credential_pack.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_pack_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';

// 代签码：出示（把当前账号封成凭据包放到中转）与取件导入（取件、解密、用对方设备码登录确认后存进本机）。
// 中转没配时（hub 为空或不可用）两边都报不可用；导入后刷新账号列表由页面控制器做。
class ChaoxingDelegateController {
  ChaoxingDelegateController({required this.accounts, required this.hub, required this.currentClient});
  final ChaoxingAccounts accounts;
  final ChaoxingPackHub? hub;
  final ChaoxingClient Function() currentClient;

  ChaoxingPackHub _requireHub() {
    final packHub = hub;
    if (packHub == null || !packHub.available) {
      throw const ChaoxingFailure(ChaoxingFailureCode.unavailable, '还没有配置中转服务，代签码用不了');
    }
    return packHub;
  }

  // 出示代签码：把当前账号封成凭据包（可附带人脸照片），密文放到中转，二维码里只有取件号与一次性密钥。
  // 返回二维码文本，以及作废这张码要用的取件号与口令（中转还没升级时口令为空）。
  Future<({String ticket, String pickupId, String? revokeToken})> createTicket({List<String> faceObjectIds = const []}) async {
    final client = currentClient();
    final packHub = _requireHub();
    final password = await accounts.vault.readPassword(client.phoneNumber);
    if (password == null || password.isEmpty) {
      throw const ChaoxingFailure(ChaoxingFailureCode.sessionExpired, '请先重新登录这个账号再出示代签码');
    }
    final sealed = await sealChaoxingCredentialPack(
      ChaoxingCredentialPack(
        phoneNumber: client.phoneNumber,
        encryptedPassword: password,
        name: client.account!.name,
        deviceCode: client.deviceCode,
        faceObjectIds: faceObjectIds.take(chaoxingPackFaceLimit).toList(),
      ),
    );
    final submitted = await packHub.submit(sealed.cipherText);
    return (
      ticket: encodeChaoxingPackTicket(ChaoxingPackTicket(pickupId: submitted.id, key: sealed.key)),
      pickupId: submitted.id,
      revokeToken: submitted.revokeToken,
    );
  }

  // 作废出示过的码（换码、改附带照片、离开出示页时）：没有口令（中转还没升级）就跳过。
  Future<void> revokeTicket({required String pickupId, required String? revokeToken}) async {
    if (revokeToken == null) return;
    await _requireHub().revoke(pickupId, revokeToken);
  }

  // 导入别人的代签码：取件、解密、用对方的设备码登录一次确认，再按代签账号存进本机。
  // accountCount 是本机现有账号数：取件号取一次就作废，账号已满时在取件前拦下，免得对方还要重新生成。
  Future<ChaoxingAccountRecord> importTicket(String raw, {required int accountCount}) async {
    final packHub = _requireHub();
    final ticket = decodeChaoxingPackTicket(raw);
    if (ticket == null) {
      throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, chaoxingNotPackTicketMessage);
    }
    if (accountCount >= ChaoxingStore.accountLimit) throw ChaoxingAccounts.full;
    final cipherText = await packHub.pickup(ticket.pickupId);
    final pack = await openChaoxingCredentialPack(ChaoxingSealedPack(key: ticket.key, cipherText: cipherText));
    return accounts.importOther(pack);
  }
}
