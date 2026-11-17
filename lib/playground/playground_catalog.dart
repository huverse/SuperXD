import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/puzzle/balance/balance_page.dart';
import 'package:superxd/playground/puzzle/boxes/boxes_page.dart';
import 'package:superxd/playground/puzzle/flash/flash_page.dart';
import 'package:superxd/playground/puzzle/cipher/cipher_page.dart';
import 'package:superxd/playground/puzzle/hanoi/hanoi_page.dart';
import 'package:superxd/playground/puzzle/ice/ice_page.dart';
import 'package:superxd/playground/puzzle/knights/knights_page.dart';
import 'package:superxd/playground/puzzle/lights/lights_page.dart';
import 'package:superxd/playground/puzzle/mines/mines_page.dart';
import 'package:superxd/playground/puzzle/loop/loop_page.dart';
import 'package:superxd/playground/puzzle/logicgrid/logicgrid_page.dart';
import 'package:superxd/playground/puzzle/nonogram/nonogram_page.dart';
import 'package:superxd/playground/puzzle/pour/pour_page.dart';
import 'package:superxd/playground/puzzle/queens/queens_page.dart';
import 'package:superxd/playground/puzzle/river/river_page.dart';
import 'package:superxd/playground/puzzle/twentyfour/twentyfour_page.dart';
import 'package:superxd/playground/puzzle/schulte/schulte_page.dart';
import 'package:superxd/theme/campus_icons.dart';

// [人工决策-2026-11-12 21:00:20] 游乐场的板块、子类与游戏只在这一处登记（同百宝箱 toolbox_catalog.dart）；id 发出后不改。
// 首个版本只有益智板块，子类与游戏清单是用户 11-12 选定的 17 个（实装一个登记一个，没做的不放占位卡）：
// 逻辑推理：骑士与无赖、逻辑网格推理、八皇后、天平称球、密码破译；数字计算：24 点；格子谜题：数回、数织、扫雷（无猜）、点灯；
// 移动与规划：汉诺塔、过河问题、推箱子、冰面滑行；记忆与反应：记忆闪光、舒尔特方格；物理：画线入杯。
// [人工决策-2026-11-14 23:11:48] 用户第三次提描述性文字太多：一句话玩法十个字上下，玩法说明只写规则与目标、一两句，
// 怎么操作靠界面本身（按钮、分段、方向键）说明，不写「每道题都唯一」这类安心话。全项目同一口径，守护见 test/code_conventions_test.dart。
const puzzleSection = PlaygroundSection(id: 'puzzle', name: '益智', icon: CampusIcons.puzzle);

const logicGroup = PlaygroundGroup(id: 'logic', name: '逻辑推理', section: puzzleSection);
const numberGroup = PlaygroundGroup(id: 'number', name: '数字计算', section: puzzleSection);
const gridGroup = PlaygroundGroup(id: 'grid', name: '格子谜题', section: puzzleSection);
const planningGroup = PlaygroundGroup(id: 'planning', name: '移动与规划', section: puzzleSection);
const memoryGroup = PlaygroundGroup(id: 'memory', name: '记忆与反应', section: puzzleSection);
const physicsGroup = PlaygroundGroup(id: 'physics', name: '物理', section: puzzleSection);

// 板块与子类的显示顺序；没有游戏的子类首页不显示。
const playgroundSections = [puzzleSection];
const playgroundGroups = [logicGroup, numberGroup, gridGroup, planningGroup, memoryGroup, physicsGroup];

final playgroundCatalog = <PlaygroundGame>[
  PlaygroundGame(
    id: 'nonogram',
    name: '数织',
    summary: '按行列提示涂格，拼出一幅小图',
    howToPlay: '每行（列）的数字是这一行（列）里依次连续涂色的格数，段与段之间至少空一格。',
    icon: CampusIcons.nonogram,
    group: gridGroup,
    builder: (context, game, store, challenge, first) => NonogramPage(game: game, store: store, first: first, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'hanoi',
    name: '汉诺塔',
    summary: '把整叠盘子挪到目标柱',
    howToPlay: '把整叠盘子挪到「目标」柱：一次挪一个，大盘不能压在小盘上。',
    icon: CampusIcons.hanoi,
    group: planningGroup,
    builder: (context, game, store, challenge, first) => HanoiPage(game: game, store: store, first: first, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'queens',
    name: '八皇后',
    summary: '补齐皇后，互不攻击',
    howToPlay: '补齐皇后，任意两个不同行、不同列、不在同一斜线。锁定的皇后不能动。',
    icon: CampusIcons.queens,
    group: logicGroup,
    builder: (context, game, store, challenge, first) => QueensPage(game: game, store: store, first: first, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'ice',
    name: '冰面滑行',
    summary: '一滑到底，停在终点上',
    // 长文案：五种格子（岩石、雪地、冰洞、薄冰、宝石）与步数上限各一条规则，少一条就看不懂棋盘。
    howToPlay: '一滑到底，撞岩石或边界才停，进雪地就停；别掉进冰洞，薄冰滑过就碎。收齐宝石，限步停在终点。',
    icon: CampusIcons.ice,
    group: planningGroup,
    builder: (context, game, store, challenge, first) => IcePage(game: game, store: store, first: first, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'lights',
    name: '点灯',
    summary: '翻转十字，把灯全点亮',
    howToPlay: '点一格，它和上下左右的灯一起翻转。把灯全部点亮。',
    icon: CampusIcons.lights,
    group: gridGroup,
    builder: (context, game, store, challenge, first) => LightsPage(game: game, store: store, first: first, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'knights',
    name: '骑士与无赖',
    summary: '谁说真话，谁在说谎',
    howToPlay: '骑士只说真话，无赖只说假话；「我们」包括说话的人。定下每个人的身份。',
    icon: CampusIcons.knights,
    group: logicGroup,
    builder: (context, game, store, challenge, first) => KnightsPage(game: game, store: store, first: first, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'river',
    name: '过河问题',
    summary: '小船往返，全员过河',
    howToPlay: '坐船或过桥，把大家都送到右岸，不能违反上方写的规矩。',
    icon: CampusIcons.river,
    group: planningGroup,
    builder: (context, game, store, challenge, first) => RiverPage(game: game, store: store, first: first, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'boxes',
    name: '推箱子',
    summary: '把箱子都推到目标点',
    howToPlay: '把箱子都推到目标点。只能推不能拉，一次推一个。',
    icon: CampusIcons.boxes,
    group: planningGroup,
    builder: (context, game, store, challenge, first) => BoxesPage(game: game, store: store, first: first, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'twentyfour',
    name: '24 点',
    summary: '加减乘除，凑出 24',
    howToPlay: '四个数各用一次，算出 24。困难起可以用乘方和开方。',
    icon: CampusIcons.twentyfour,
    group: numberGroup,
    builder: (context, game, store, challenge, first) => TwentyFourPage(game: game, store: store, first: first, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'flash',
    name: '记忆闪光',
    summary: '记住亮起的格，再点出来',
    howToPlay: '记住亮起的格再点：入门简单不论先后，普通按先后，困难倒着点，专家按数字从小到大。',
    icon: CampusIcons.flash,
    group: memoryGroup,
    builder: (context, game, store, challenge, first) => FlashPage(game: game, store: store, first: first, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'balance',
    name: '天平称球',
    summary: '用天平找出不一样的球',
    howToPlay: '有一个球重量不同，在限定次数内称出它；称的结果能唯一确定它才算找出。',
    icon: CampusIcons.balance,
    group: logicGroup,
    builder: (context, game, store, challenge, first) => BalancePage(game: game, store: store, first: first, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'mines',
    name: '扫雷',
    summary: '只靠推理排雷，不用猜',
    howToPlay: '数字是周围八格里的雷数。翻开所有不是雷的格，长按插旗。',
    icon: CampusIcons.mines,
    group: gridGroup,
    builder: (context, game, store, challenge, first) => MinesPage(game: game, store: store, first: first, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'loop',
    name: '数回',
    summary: '画一个圈，对上格里的数字',
    howToPlay: '沿格线画一个不分叉的闭合圈，每个数字是它四条边里在圈上的条数。',
    icon: CampusIcons.loop,
    group: gridGroup,
    builder: (context, game, store, challenge, first) => LoopPage(game: game, store: store, first: first, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'logicgrid',
    name: '逻辑网格',
    summary: '按线索推出谁有什么',
    howToPlay: '按线索推出每个人在每一类里各是哪一样。座位从左到右是 1 号起。',
    icon: CampusIcons.logicgrid,
    group: logicGroup,
    builder: (context, game, store, challenge, first) => LogicGridPage(game: game, store: store, first: first, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'cipher',
    name: '密码破译',
    summary: '看线索，推出密码',
    howToPlay: '密码的各位数字互不相同。每行线索写着：几个数字位置也对、几个数字对但位置不对。',
    icon: CampusIcons.cipher,
    group: logicGroup,
    builder: (context, game, store, challenge, first) => CipherPage(game: game, store: store, first: first, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'schulte',
    name: '舒尔特方格',
    summary: '从小到大，尽快依次点完',
    howToPlay: '从小到大尽快依次点完。专家档黑红交替：黑 1、红 12、黑 2、红 11……',
    icon: CampusIcons.schulte,
    group: memoryGroup,
    challengeable: false,
    timeInTenths: true,
    builder: (context, game, store, _, _) => SchultePage(game: game, store: store),
  ),
  PlaygroundGame(
    id: 'pour',
    name: '画线入杯',
    summary: '画一条线，把球引进杯子',
    howToPlay: '画线把球引进杯子，墨水有限，线不能碰到球。画好点「放球」。',
    icon: CampusIcons.pour,
    group: physicsGroup,
    challengeable: false,
    builder: (context, game, store, _, _) => PourPage(game: game, store: store),
  ),
];
