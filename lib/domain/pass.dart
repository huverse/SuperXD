import 'package:superxd/domain/app_account.dart';

// 积分时长券（[人工决策-2026-11-19 22:42:37] 见 lib/toolbox/cinema/cinema_service.dart 文件头与服务端 src/modules/pass/pass.service.ts；预接好、不启用）：
// 中转发布目录的 passes.json 写哪些服务要用积分换时长（不放就都不收，现在的状态）；这个账号买到哪天由服务器记，本机记一份，离线时按记着的放行到期为止。
// 灰度配置里不加这些字段：旧版本解析灰度配置是严格的，多一个字段整份拒收。

// 一种券：服务编号（同要收费的服务，如 toolbox.cinema）、名字、每次花多少积分、换几天。
class PassOffer {
  const PassOffer({required this.id, required this.title, required this.price, required this.days});
  final String id;
  final String title;
  final int price;
  final int days;
}

enum PassFailure { notSignedIn, unavailable, pointsShort, network, rateLimited, failed }

class PassException implements Exception {
  const PassException(this.failure, this.message);
  final PassFailure failure;
  final String message;
  @override
  String toString() => 'PassException($failure)';
}

// 中转端口（relay 实现）：清单免签名，自己的券与购买用这个应用账号的设备密钥签名。held 是还没到期的券到哪个时刻（UTC）。
abstract interface class PassClient {
  Future<List<PassOffer>> offers();
  Future<Map<String, DateTime>> held(AppAccountRef account);
  Future<Map<String, DateTime>> buy(AppAccountRef account, String id);
}

// 本机记录端口（local 实现）：上次拉到的清单，与每个应用账号买到哪天（换账号各记各的）。
abstract interface class PassMemory {
  List<PassOffer> get offers;
  Map<String, DateTime> heldOf(String accountId);
  Future<void> saveOffers(List<PassOffer> offers);
  Future<void> saveHeld(String accountId, Map<String, DateTime> held);
}

// 页面用的端口（application 实现，组合根注入）：locked 是这项要用积分换、当前账号又没有没到期的券；清单里没有就不拦（现在的状态）。
abstract interface class PassAccess {
  Stream<void> get changes;
  PassOffer? offer(String id);
  // 当前账号这项买到哪个时刻；没买或已到期为空。
  DateTime? until(String id);
  bool locked(String id);
  // 现在能不能买：登录着应用账号且联网偏好是联网。
  bool get canBuy;
  Future<void> refresh();
  // 花积分续一次，失败抛 PassException。
  Future<void> buy(String id);
}

const passOfferLimit = 20;
const passDaysMax = 366;
const passPriceMax = 100000;
final passIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');

// 清单是外部输入：逐项校验，编号不重复，不合格的整份不用。
List<PassOffer> decodePassOffers(Object? json) {
  if (json case {'offers': final List<Object?> items} when items.length <= passOfferLimit) {
    final offers = <PassOffer>[];
    for (final item in items) {
      if (item case {'id': final String id, 'title': final String title, 'price': final int price, 'days': final int days}
          when passIdPattern.hasMatch(id) && title.isNotEmpty && title.length <= 20 && price >= 1 && price <= passPriceMax && days >= 1 && days <= passDaysMax && offers.every((offer) => offer.id != id)) {
        offers.add(PassOffer(id: id, title: title, price: price, days: days));
      } else {
        throw const FormatException('时长券清单不合法');
      }
    }
    return offers;
  }
  throw const FormatException('时长券清单不合法');
}

Map<String, Object?> encodePassOffers(List<PassOffer> offers) => {
  'offers': [for (final offer in offers) {'id': offer.id, 'title': offer.title, 'price': offer.price, 'days': offer.days}],
};

// 自己的券 {held: [{id, until(毫秒)}]} 是外部输入：编号合法、时刻在合理范围。
Map<String, DateTime> decodePassHeld(Object? json) {
  if (json case {'held': final List<Object?> items} when items.length <= passOfferLimit) {
    final held = <String, DateTime>{};
    for (final item in items) {
      if (item case {'id': final String id, 'until': final int until} when passIdPattern.hasMatch(id) && until > 0 && until < 32503680000000) {
        held[id] = DateTime.fromMillisecondsSinceEpoch(until, isUtc: true);
      } else {
        throw const FormatException('时长券不合法');
      }
    }
    return held;
  }
  throw const FormatException('时长券不合法');
}
