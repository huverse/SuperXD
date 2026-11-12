import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/puzzle/hanoi/hanoi_page.dart';
import 'package:superxd/playground/puzzle/nonogram/nonogram_page.dart';
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
];
