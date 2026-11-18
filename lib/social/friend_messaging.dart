import 'package:flutter/foundation.dart';

import 'package:superxd/domain/share_card.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/social/social_store.dart';

// 一组好友加分享卡片：线上私信 SocialService 与面对面私信 NearbyService 都实现，会话页与添加好友页不分是哪一种。
// 失败一律抛 SocialException（错误码见 social_service.dart 的 SocialCode）。
abstract interface class FriendMessaging implements Listenable {
  List<SocialFriend> get friends;
  SocialProfile? get profile;
  // 二维码倒计时用的当前时刻（毫秒）：线上是按服务器校正过的，面对面是本机的。
  int get serverNow;
  Future<List<SocialMessage>> conversation(String friendId);
  Future<void> markRead(String friendId);
  Future<SocialMessage> send(String friendId, ShareCard card);
  Future<SocialMessage> retry(String messageId);
  Future<void> deleteMessage(String messageId);
  Future<void> setRemark(String friendId, String? remark);
  Future<void> removeFriend(String friendId);
  Future<InviteCode> createInvite();
  Future<void> revokeInvite(String inviteId);
  Future<SocialFriend> redeem(InviteCode code);
}
