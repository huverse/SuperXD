import 'package:superxd/page/festival/festival_stage.dart';

// 节日登记（人工决策见 domain/festival.dart）：每一次节日一项（同一个节日每一年是新的一项、新的动画），编号发出后不改。
// 不预制：维护者点名哪个节日，就为那一次单独设计、打磨一段动画（场景写在本目录，一次一个文件），在这里加一项；
// 要抽奖的先在服务器上建同编号的活动（server/src/modules/reward/reward_admin.ts），把编号写进 campaign。
// 加之前在开发者选项的「节日预览」里逐帧看过，再在模拟器上改系统日期走一遍真实触发。
final festivalCatalog = <FestivalScene>[];
