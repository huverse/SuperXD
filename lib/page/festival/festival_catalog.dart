import 'package:superxd/page/festival/festival_stage.dart';
import 'reward_glow.dart';
import 'reward_kit.dart';

// 节日登记（人工决策见 domain/festival.dart）：每一次节日一项（同一个节日每一年是新的一项、新的动画），编号发出后不改。
// 不预制：维护者点名哪个节日，就为那一次单独设计、打磨一段动画（场景写在本目录，一次一个文件），在这里加一项；
// 要抽奖的先在服务器上建同编号的活动（server/src/modules/reward/reward_admin.ts），把编号写进 campaign。
// 加之前在开发者选项的「节日预览」里逐帧看过，再在模拟器上改系统日期走一遍真实触发。
// 红包主题：这一次的红包要换配色或卡面时，在本目录写一个 RewardTheme（照 reward_glow.dart），场景的 reward 指向它；
// 不写就用默认的流光卡（reward_glow.dart，颜色跟应用配色）。奖品按编号找到这一次的主题，domain 不用动。
final festivalCatalog = <FestivalScene>[];

// 奖品属于哪一次节日就用那一次登记的红包主题；没登记主题（或节日已不在登记里）用默认主题。
RewardTheme festivalRewardTheme(String occasion) => festivalCatalog.where((scene) => scene.occasion.id == occasion).firstOrNull?.reward ?? const RewardGlowTheme();
