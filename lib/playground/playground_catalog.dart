import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/puzzle/boxes/boxes_page.dart';
import 'package:superxd/playground/puzzle/hanoi/hanoi_page.dart';
import 'package:superxd/playground/puzzle/ice/ice_page.dart';
import 'package:superxd/playground/puzzle/knights/knights_page.dart';
import 'package:superxd/playground/puzzle/lights/lights_page.dart';
import 'package:superxd/playground/puzzle/nonogram/nonogram_page.dart';
import 'package:superxd/playground/puzzle/queens/queens_page.dart';
import 'package:superxd/playground/puzzle/river/river_page.dart';
import 'package:superxd/playground/puzzle/twentyfour/twentyfour_page.dart';
import 'package:superxd/theme/campus_icons.dart';

// [人工决策-2026-11-12 21:00:20] 游乐场的板块、子类与游戏只在这一处登记（同百宝箱 toolbox_catalog.dart）；id 发出后不改。
// 首个版本只有益智板块，子类与游戏清单是用户 11-12 选定的 17 个（实装一个登记一个，没做的不放占位卡）：
// 逻辑推理：骑士与无赖、逻辑网格推理、八皇后、天平称球、密码破译；数字计算：24 点；格子谜题：数回、数织、扫雷（无猜）、点灯；
// 移动与规划：汉诺塔、过河问题、推箱子、冰面滑行；记忆与反应：记忆闪光、舒尔特方格；物理：画线入杯。
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
    howToPlay: '每行左边、每列上边的数字，是这一行（列）里连续涂色格的长度，按顺序排列，两段之间至少空一格。\n'
        '在格子上点按或拖动来涂色；确定不涂的格可以切到「标叉」做记号。拖动会锁定在起点那一行或那一列。双指可以放大。\n'
        '每道题都只靠推理就能唯一解出，不用猜。',
    icon: CampusIcons.nonogram,
    group: gridGroup,
    builder: (context, game, store) => NonogramPage(game: game, store: store),
  ),
  PlaygroundGame(
    id: 'hanoi',
    name: '汉诺塔',
    summary: '把整叠盘子挪到目标柱',
    howToPlay: '一次只能挪一根柱子最上面的一个盘子，大盘子不能放在小盘子上面，把全部盘子挪到标着「目标」的柱子上。\n'
        '点一根柱子拿起盘子，再点另一根放下；也可以直接拖。\n'
        '困难和专家档的开局是打乱的，最少步数按开局算。',
    icon: CampusIcons.hanoi,
    group: planningGroup,
    builder: (context, game, store) => HanoiPage(game: game, store: store),
  ),
  PlaygroundGame(
    id: 'queens',
    name: '八皇后',
    summary: '补齐皇后，互不攻击',
    howToPlay: '在 N×N 的棋盘上放 N 个皇后，任意两个不能在同一行、同一列或同一条斜线上。\n'
        '题面已经摆好几个锁定的皇后（垫着底板，不能动），补齐其余的；每道题的补法都唯一。\n'
        '点空格放皇后，再点一次拿掉。互相攻击的皇后会标成红色并连一条线；按住一个皇后能看它管到的格子。棋盘大时双指可以放大。',
    icon: CampusIcons.queens,
    group: logicGroup,
    builder: (context, game, store) => QueensPage(game: game, store: store),
  ),
  PlaygroundGame(
    id: 'ice',
    name: '冰面滑行',
    summary: '一滑到底，停在终点上',
    howToPlay: '小企鹅朝一个方向滑出去，一直滑到撞上岩石或边界才停。\n'
        '要正好停在插旗的终点格上才算到达，滑过去不算。\n'
        '在棋盘上朝上下左右滑动来推它，也可以点下方的方向键；走错了可以撤销。',
    icon: CampusIcons.ice,
    group: planningGroup,
    builder: (context, game, store) => IcePage(game: game, store: store),
  ),
  PlaygroundGame(
    id: 'lights',
    name: '点灯',
    summary: '翻转十字，把灯全点亮',
    howToPlay: '每格一盏灯。点一格，这一盏和它上下左右相邻的灯一起翻转：亮的变灭，灭的变亮。\n'
        '把全部灯点亮就解开了。同一格点两下等于没点，点的先后也不影响结果。\n'
        '每道题都有解，状态行写着最少要点几下；点错了可以撤销。',
    icon: CampusIcons.lights,
    group: gridGroup,
    builder: (context, game, store) => LightsPage(game: game, store: store),
  ),
  PlaygroundGame(
    id: 'knights',
    name: '骑士与无赖',
    summary: '谁说真话，谁在说谎',
    howToPlay: '岛上住着骑士和无赖：骑士永远说真话，无赖永远说假话。每张卡片上是一个人说的一句话，「我们」包括说话的人自己。\n'
        '点卡片上的「骑士」或「无赖」定下这个人的身份，再点一次取消。\n'
        '全部定下就判定：每个人的话都要和他的身份对得上。对不上的人会标成红色，自己找出矛盾再改；每道题的答案都唯一。',
    icon: CampusIcons.knights,
    group: logicGroup,
    builder: (context, game, store) => KnightsPage(game: game, store: store),
  ),
  PlaygroundGame(
    id: 'river',
    name: '过河问题',
    summary: '小船往返，全员过河',
    howToPlay: '用一条小船把所有人和物都送到右岸。船上至少一人、不超过船的容量，船上要有会划船的人才开得了。\n'
        '点岸上的人上船（船要停在这一岸），点船上的人下船；坐好了点「开船」。靠岸以后船上的人算在那一岸，可以留在船上接着坐。\n'
        '每档的规矩不同，河上方写着这一道的：农夫过河只有农夫会划船，没人看着时狼会吃羊、羊会吃白菜；大人与小孩是有大人的岸上，小孩不能比大人多；'
        '父子是爸爸不在时，孩子不能和别人家的爸爸待在一起。会犯规的开不了船，会提示原因；撤销按整次渡河退回。',
    icon: CampusIcons.river,
    group: planningGroup,
    builder: (context, game, store) => RiverPage(game: game, store: store),
  ),
  PlaygroundGame(
    id: 'boxes',
    name: '推箱子',
    summary: '把箱子都推到目标点',
    howToPlay: '在房间里上下左右走，走进箱子就把它朝前推一格。只能推、不能拉，一次只能推一个，箱子前面是墙或别的箱子就推不动。\n'
        '在棋盘上滑一下走一格，也可以点下方的方向键；推错了可以撤销。\n'
        '把所有箱子都推到圆环标出的目标点上就解开了。状态行写推了几次和最少要推几次。',
    icon: CampusIcons.boxes,
    group: planningGroup,
    builder: (context, game, store) => BoxesPage(game: game, store: store),
  ),
  PlaygroundGame(
    id: 'twentyfour',
    name: '24 点',
    summary: '加减乘除，凑出 24',
    howToPlay: '四张卡上各有一个 1 到 13 的数，每个数恰好用一次，用加减乘除算出 24。\n'
        '点一张卡，再点一个运算和另一张卡，两张就合成一张写着结果的新卡（减和除是第一张减、除以第二张），除不尽的写成分数。\n'
        '合到只剩一张、正好是 24 就解开了；算错了可以撤销，一步步退回。',
    icon: CampusIcons.twentyfour,
    group: numberGroup,
    builder: (context, game, store) => TwentyFourPage(game: game, store: store),
  ),
];
