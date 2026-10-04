import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'package:superxd/domain/share_card.dart';

// 私信本机库 social.db（设备级，切换教务账号保留）：资料、好友、消息、邀请。
// 时间一律存 UTC ISO 字符串；私钥不在这里，在系统安全存储（identity_vault.dart）。
// 上限：好友 500；每个好友保留最近 200 条消息；邀请保留 31 天（覆盖信箱 30 天保留期内迟到的问候）。

const friendLimit = 500;
const conversationLimit = 200;
const inviteRetention = Duration(days: 31);

class SocialFriend {
  const SocialFriend({
    required this.deviceId,
    required this.nickname,
    required this.signPublicKey,
    required this.boxPublicKey,
    required this.since,
    required this.lastActivity,
    this.remark,
    this.removed = false,
    this.lastPreview = '',
    this.unread = 0,
  });
  final String deviceId;
  final String nickname;
  final String? remark;
  final String signPublicKey;
  final String boxPublicKey;
  final String since;
  final String lastActivity;
  // 对方已解除好友（发送被拒 NOT_FRIEND 或好友列表里已没有对方）；保留会话，不能再发送。
  final bool removed;
  final String lastPreview;
  final int unread;
  String get displayName => remark?.isNotEmpty == true ? remark! : nickname;

  static SocialFriend fromRow(Map<String, Object?> row) => SocialFriend(
    deviceId: row['device_id'] as String,
    nickname: row['nickname'] as String,
    remark: row['remark'] as String?,
    signPublicKey: row['sign_public_key'] as String,
    boxPublicKey: row['box_public_key'] as String,
    since: row['since'] as String,
    lastActivity: row['last_activity'] as String,
    removed: row['removed'] == 1,
    lastPreview: row['last_preview'] as String,
    unread: row['unread'] as int,
  );
}

enum MessageState { sending, sent, failed, received }

// 一条私信：分享卡片或系统提示（如“已成为好友”）。
class SocialMessage {
  const SocialMessage({required this.id, required this.friendId, required this.outgoing, required this.state, required this.createTime, this.card, this.system, this.error});
  final String id;
  final String friendId;
  final bool outgoing;
  final MessageState state;
  final String createTime;
  final ShareCard? card;
  // 系统提示的类型：friend_added。
  final String? system;
  // 发送失败的错误码。
  final String? error;

  static SocialMessage fromRow(Map<String, Object?> row) {
    final body = row['body'] as String?;
    ShareCard? card;
    if (body != null) {
      try {
        card = decodeShareCard(jsonDecode(body));
      } on Object {
        // 入库前已校验；库被改坏时按未知卡片显示，不让整页崩溃。
        card = const UnknownShare(type: 'corrupted', version: 0);
      }
    }
    return SocialMessage(
      id: row['id'] as String,
      friendId: row['friend_id'] as String,
      outgoing: row['outgoing'] == 1,
      state: MessageState.values.byName(row['state'] as String),
      createTime: row['create_time'] as String,
      card: card,
      system: row['system'] as String?,
      error: row['error'] as String?,
    );
  }
}

class SocialProfile {
  const SocialProfile({required this.nickname, required this.registered});
  final String nickname;
  final bool registered;
}

class SocialStore {
  SocialStore._(this._database);
  final Database _database;

  static Future<SocialStore> open(String path) async => SocialStore._(await openDatabase(path, version: 1, onCreate: (database, _) async {
    await database.execute('CREATE TABLE profile (id INTEGER PRIMARY KEY CHECK(id=1), nickname TEXT NOT NULL, registered INTEGER NOT NULL)');
    await database.execute(
      'CREATE TABLE friend (device_id TEXT PRIMARY KEY, nickname TEXT NOT NULL, remark TEXT, sign_public_key TEXT NOT NULL, box_public_key TEXT NOT NULL, '
      'since TEXT NOT NULL, last_activity TEXT NOT NULL, removed INTEGER NOT NULL DEFAULT 0, last_preview TEXT NOT NULL DEFAULT \'\', unread INTEGER NOT NULL DEFAULT 0)',
    );
    await database.execute('CREATE INDEX friend_activity ON friend (last_activity DESC, device_id)');
    await database.execute(
      'CREATE TABLE message (id TEXT PRIMARY KEY, friend_id TEXT NOT NULL, outgoing INTEGER NOT NULL, state TEXT NOT NULL, body TEXT, system TEXT, error TEXT, create_time TEXT NOT NULL)',
    );
    await database.execute('CREATE INDEX message_conversation ON message (friend_id, create_time DESC, id DESC)');
    await database.execute('CREATE TABLE invite (invite_id TEXT PRIMARY KEY, public_key TEXT NOT NULL, create_time TEXT NOT NULL)');
    await database.execute('CREATE INDEX invite_time ON invite (create_time)');
  }));

  Future<void> close() => _database.close();

  Future<SocialProfile?> profile() async {
    final row = (await _database.query('profile', where: 'id = 1')).firstOrNull;
    return row == null ? null : SocialProfile(nickname: row['nickname'] as String, registered: row['registered'] == 1);
  }

  Future<void> saveProfile(SocialProfile profile) => _database.insert('profile', {'id': 1, 'nickname': profile.nickname, 'registered': profile.registered ? 1 : 0}, conflictAlgorithm: ConflictAlgorithm.replace);

  // 关闭私信：清空本机全部私信数据。
  Future<void> clear() => _database.transaction((transaction) async {
    for (final table in ['profile', 'friend', 'message', 'invite']) {
      await transaction.delete(table);
    }
  });

  // 按最近活动倒序；好友最多 500 个，结果有界。
  Future<List<SocialFriend>> friends() async => [
    for (final row in await _database.query('friend', orderBy: 'last_activity DESC, device_id', limit: friendLimit)) SocialFriend.fromRow(row),
  ];

  Future<SocialFriend?> friend(String deviceId) async {
    final row = (await _database.query('friend', where: 'device_id = ?', whereArgs: [deviceId])).firstOrNull;
    return row == null ? null : SocialFriend.fromRow(row);
  }

  Future<int> friendCount() async => Sqflite.firstIntValue(await _database.rawQuery('SELECT COUNT(*) FROM friend'))!;

  // 加好友并写一条“已成为好友”提示；已是好友时只更新公钥与昵称并恢复为有效（重新扫码即重新加回）。
  Future<void> upsertFriend({required String deviceId, required String nickname, required String signPublicKey, required String boxPublicKey, required String now, required String systemId}) =>
      _database.transaction((transaction) async {
        final existing = (await transaction.query('friend', columns: ['removed'], where: 'device_id = ?', whereArgs: [deviceId])).firstOrNull;
        if (existing == null) {
          await transaction.insert('friend', {'device_id': deviceId, 'nickname': nickname, 'sign_public_key': signPublicKey, 'box_public_key': boxPublicKey, 'since': now, 'last_activity': now, 'last_preview': '已成为好友'});
        } else {
          await transaction.update('friend', {'nickname': nickname, 'sign_public_key': signPublicKey, 'box_public_key': boxPublicKey, 'removed': 0, 'last_activity': now, 'last_preview': '已成为好友'}, where: 'device_id = ?', whereArgs: [deviceId]);
          if (existing['removed'] == 0) return;
        }
        await transaction.insert('message', {'id': systemId, 'friend_id': deviceId, 'outgoing': 0, 'state': MessageState.received.name, 'system': 'friend_added', 'create_time': now}, conflictAlgorithm: ConflictAlgorithm.ignore);
      });

  Future<void> setRemark(String deviceId, String? remark) => _database.update('friend', {'remark': remark}, where: 'device_id = ?', whereArgs: [deviceId]);

  Future<void> markRemoved(String deviceId) => _database.update('friend', {'removed': 1}, where: 'device_id = ?', whereArgs: [deviceId]);

  Future<void> markRead(String deviceId) => _database.update('friend', {'unread': 0}, where: 'device_id = ? AND unread > 0', whereArgs: [deviceId]);

  // 删除好友连同会话。
  Future<void> deleteFriend(String deviceId) => _database.transaction((transaction) async {
    await transaction.delete('message', where: 'friend_id = ?', whereArgs: [deviceId]);
    await transaction.delete('friend', where: 'device_id = ?', whereArgs: [deviceId]);
  });

  // 写入一条卡片消息并更新会话摘要、未读数，再裁剪到每个好友 200 条。收到的消息按 id 幂等（中转至少投递一次）。
  // 未知卡片原样保留类型与版本，升级应用后仍显示为未知（内容未保存），提示对方重发。
  Future<bool> addCard({required String id, required String friendId, required bool outgoing, required MessageState state, required ShareCard card, required String now}) =>
      _database.transaction((transaction) async {
        final inserted = await transaction.insert('message', {
          'id': id,
          'friend_id': friendId,
          'outgoing': outgoing ? 1 : 0,
          'state': state.name,
          'body': jsonEncode(card is UnknownShare ? {'type': card.type, 'version': card.version, 'body': const {}} : encodeShareCard(card)),
          'create_time': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        if (inserted == 0) return false;
        await transaction.rawUpdate(
          'UPDATE friend SET last_activity = ?, last_preview = ?, unread = unread + ? WHERE device_id = ?',
          [now, shareCardSummary(card), outgoing ? 0 : 1, friendId],
        );
        // 只删最旧的超出部分：按会话索引取第 200 条之后的 id。
        await transaction.rawDelete(
          'DELETE FROM message WHERE id IN (SELECT id FROM message WHERE friend_id = ? ORDER BY create_time DESC, id DESC LIMIT -1 OFFSET ?)',
          [friendId, conversationLimit],
        );
        return true;
      });

  Future<void> setState(String id, MessageState state, {String? error}) => _database.update('message', {'state': state.name, 'error': error}, where: 'id = ?', whereArgs: [id]);

  Future<SocialMessage?> message(String id) async {
    final row = (await _database.query('message', where: 'id = ?', whereArgs: [id])).firstOrNull;
    return row == null ? null : SocialMessage.fromRow(row);
  }

  // 会话按时间倒序分页（走 message_conversation 索引）；会话最多 200 条，一页取完。
  Future<List<SocialMessage>> conversation(String friendId) async => [
    for (final row in await _database.query('message', where: 'friend_id = ?', whereArgs: [friendId], orderBy: 'create_time DESC, id DESC', limit: conversationLimit)) SocialMessage.fromRow(row),
  ];

  Future<void> deleteMessage(String id) => _database.delete('message', where: 'id = ?', whereArgs: [id]);

  // 应用被杀时停在“发送中”的消息，启动时改为失败，由用户点重发。
  Future<void> failInterrupted() => _database.update('message', {'state': MessageState.failed.name, 'error': 'INTERRUPTED'}, where: 'state = ?', whereArgs: [MessageState.sending.name]);

  Future<void> saveInvite(String inviteId, String publicKey, String now) =>
      _database.insert('invite', {'invite_id': inviteId, 'public_key': publicKey, 'create_time': now}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<String?> invitePublicKey(String inviteId) async =>
      (await _database.query('invite', columns: ['public_key'], where: 'invite_id = ?', whereArgs: [inviteId])).firstOrNull?['public_key'] as String?;

  Future<void> pruneInvites(String before) => _database.delete('invite', where: 'create_time < ?', whereArgs: [before]);

  Future<int> unreadTotal() async => Sqflite.firstIntValue(await _database.rawQuery('SELECT COALESCE(SUM(unread), 0) FROM friend'))!;
}
