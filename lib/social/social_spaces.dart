import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';

import 'package:superxd/social/identity_vault.dart';
import 'package:superxd/social/social_store.dart';

// 一个应用账号在这台手机上的私信：本机库与身份在安全存储里的键。
class SocialSpace {
  const SocialSpace({required this.accountId, required this.store, required this.identityKey});
  final String accountId;
  final SocialStore store;
  final String identityKey;
}

// 每个应用账号一份私信（人工决策见 social_service.dart 文件头）：身份存在安全存储的哪一项、本机库是哪个文件。
// 旧版留下的设备级私信（身份 identity、库 social.db）并进这台手机上第一个用私信的应用账号（11-14 定的默认做法，记在安全存储的 legacyOwner）；
// 之后的账号身份是 identity.<账号号>、库是 social/<账号号>.db（social 文件夹整个排除出备份）。库只开一次、切换账号不关（单实例，见 local/account_store.dart 的 open）。
class SocialSpaces {
  SocialSpaces({required this.vault, required this.directory});
  final IdentityVault vault;
  // 数据库目录。
  final String directory;
  final _stores = <String, SocialStore>{};
  final _lock = Lock();

  static const legacyDatabase = 'social.db';
  static const accountFolder = 'social';

  Future<SocialSpace> of(String accountId) => _lock.synchronized(() async {
    var owner = await vault.legacyOwner();
    if (owner == null) {
      await vault.setLegacyOwner(accountId);
      owner = accountId;
    }
    final legacy = owner == accountId;
    final file = legacy ? path.join(directory, legacyDatabase) : path.join(directory, accountFolder, '$accountId.db');
    if (!legacy) await Directory(path.dirname(file)).create(recursive: true);
    final store = _stores[file] ??= await SocialStore.open(file);
    return SocialSpace(accountId: accountId, store: store, identityKey: legacy ? 'identity' : 'identity.$accountId');
  });
}
