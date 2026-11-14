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
    builder: (context, game, store, challenge) => NonogramPage(game: game, store: store, challenge: challenge),
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
    builder: (context, game, store, challenge) => HanoiPage(game: game, store: store, challenge: challenge),
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
    builder: (context, game, store, challenge) => QueensPage(game: game, store: store, challenge: challenge),
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
    builder: (context, game, store, challenge) => IcePage(game: game, store: store, challenge: challenge),
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
    builder: (context, game, store, challenge) => LightsPage(game: game, store: store, challenge: challenge),
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
    builder: (context, game, store, challenge) => KnightsPage(game: game, store: store, challenge: challenge),
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
    builder: (context, game, store, challenge) => RiverPage(game: game, store: store, challenge: challenge),
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
    builder: (context, game, store, challenge) => BoxesPage(game: game, store: store, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'twentyfour',
    name: '24 点',
    summary: '加减乘除，凑出 24',
    howToPlay: '四张卡上各有一个 1 到 13 的数，每个数恰好用一次，用加减乘除算出 24。\n'
        '点一张卡，再点一个运算和另一张卡，两张就合成一张写着结果的新卡（减和除是第一张减、除以第二张），除不尽的写成分数。\n'
        '困难起还可以用乘方和开方：乘方同上，第二张是指数（要是整数）；开方只作用在选着的那一张上，要开得尽。\n'
        '合到只剩一张、正好是 24 就解开了；算错了可以撤销，一步步退回。',
    icon: CampusIcons.twentyfour,
    group: numberGroup,
    builder: (context, game, store, challenge) => TwentyFourPage(game: game, store: store, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'flash',
    name: '记忆闪光',
    summary: '记住亮起的格，再点出来',
    howToPlay: '点「开始」后，棋盘上同时亮起几格，停一会儿就熄灭。熄灭后把刚才亮过的格子全部点出来，顺序不限；亮着的时候不能点。\n'
        '点对的格子保持点亮。点错一格这一轮就作废：会亮出漏掉的格子，再换一组新图案重来。\n'
        '一道题 5 轮，每轮全部点对才进下一轮；档位越高，格子越多、亮的格越多、亮的时间越短。',
    icon: CampusIcons.flash,
    group: memoryGroup,
    builder: (context, game, store, challenge) => FlashPage(game: game, store: store, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'balance',
    name: '天平称球',
    summary: '用天平找出不一样的球',
    howToPlay: '一组外观一样的球里恰好有一个重量不同，用天平称有限的几次把它找出来；有的档还要说出它偏轻还是偏重。天平上方写着这一道的球数和次数。\n'
        '选「放左盘」或「放右盘」，点桌上的球放进去，点盘里的球拿回来；两边球数一样才能称，每次的结果记在下方。\n'
        '确定了就点「指认」，点那个球（要说轻重的再选偏重或偏轻）确认。秤不会让你碰运气：只有称的结果只剩它一个时才算找出。「做记号」可以给球标可能偏重、可能偏轻或好球。',
    icon: CampusIcons.balance,
    group: logicGroup,
    builder: (context, game, store, challenge) => BalancePage(game: game, store: store, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'mines',
    name: '扫雷',
    summary: '只靠推理排雷，不用猜',
    howToPlay: '翻开的格子上写着周围八格里有几颗雷。把所有不是雷的格子都翻开就解开了；翻到雷这一局就结束，只能从头来或换一道题。\n'
        '开局已经翻开一片。下方选「翻开」或「插旗」，再点格子；长按没翻开的格子也能插旗，长按旗子拔掉，旗子只是记号。点已翻开的数字，周围插的旗正好等于这个数字时，其余格子一起翻开。棋盘大时双指可以放大。\n'
        '每道题都只靠推理就能翻完，不用猜。',
    icon: CampusIcons.mines,
    group: gridGroup,
    builder: (context, game, store, challenge) => MinesPage(game: game, store: store, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'loop',
    name: '数回',
    summary: '沿着点阵画一个圈，对上格里的数字',
    howToPlay: '沿着点与点之间的边画一条闭合的回路：不分叉、不交叉，全盘只有一个圈。\n'
        '格子里的数字是这一格四条边里有几条在回路上，没有数字的格不限。\n'
        '点一条边画线，再点一次取消；按住沿着点拖动可以连着画。确定不走的边可以切到「标叉」做记号。棋盘大时双指可以放大。\n'
        '每道题的答案都唯一。',
    icon: CampusIcons.loop,
    group: gridGroup,
    builder: (context, game, store, challenge) => LoopPage(game: game, store: store, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'logicgrid',
    name: '逻辑网格',
    summary: '按线索推出谁有什么',
    howToPlay: '每个人在每一类里各有一样，同一类里每样只属于一个人。按下面的线索推出整张表。\n'
        '点表格的一格，在「是」里选一个填上；确定不是的可以在「不是」里标掉，做记号用。点一条线索可以标成用过了。\n'
        '座位从左到右是 1 号到 N 号。填满就判定，对不上的线索会标成红色；每道题的答案都唯一。',
    icon: CampusIcons.logicgrid,
    group: logicGroup,
    builder: (context, game, store, challenge) => LogicGridPage(game: game, store: store, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'cipher',
    name: '密码破译',
    summary: '看线索，推出密码',
    howToPlay: '密码是几位各不相同的数字。每行线索是一组数字，下面写着它和密码比有几个数字对、位置对不对。\n'
        '只靠这些线索就能推出唯一的密码。点线索里的数字可以做记号：点一下是不在密码里，再点是在密码里，再点清掉。\n'
        '用下方的数字键填答案，点答案格清掉那一位；填满点「确认」。不对时，和答案对不上的线索会标红。',
    icon: CampusIcons.cipher,
    group: logicGroup,
    builder: (context, game, store, challenge) => CipherPage(game: game, store: store, challenge: challenge),
  ),
  PlaygroundGame(
    id: 'schulte',
    name: '舒尔特方格',
    summary: '从小到大，尽快依次点完',
    howToPlay: '方格里打乱排着一组数，从 1 开始按从小到大的顺序尽快依次点完。点对的格会变淡；点错会震一下、记一次，不往下走。计时从点第一下开始。\n'
        '专家档分黑、红两色：黑色实心格从 1 点到 13，红色描边格从 12 点到 1，两色交替：黑 1、红 12、黑 2、红 11……最后是黑 13。',
    icon: CampusIcons.schulte,
    group: memoryGroup,
    challengeable: false,
    timeInTenths: true,
    builder: (context, game, store, _) => SchultePage(game: game, store: store),
  ),
  PlaygroundGame(
    id: 'pour',
    name: '画线入杯',
    summary: '画一条线，把球引进杯子',
    howToPlay: '用手指在棋盘上画线，松手后线就固定不动；墨水有限，顶上的细条是剩下的墨水，用完就画不了。线不能碰到球。\n'
        '画好后点「放球」，球在重力下落下。全部球滚进杯子并停稳就过关；没进可以撤销上一笔或重画，再放一次。\n'
        '可以画好几笔。放球时不能画线，点「停下」让球回到起点。',
    icon: CampusIcons.pour,
    group: physicsGroup,
    challengeable: false,
    builder: (context, game, store, _) => PourPage(game: game, store: store),
  ),
];
