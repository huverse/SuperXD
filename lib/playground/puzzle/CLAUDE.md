# playground/puzzle 益智板块

定位：益智板块的游戏，一个游戏一个子目录，规则（纯 Dart）与对局页各一个文件。框架与契约见 lib/playground/CLAUDE.md。

# 文件职责

- hanoi 汉诺塔（移动与规划）：
  - hanoi_rules.dart：HanoiRules：入门到普通是经典开局（3 到 5 盘），困难与专家打乱开局（6、7 盘，最少步数不少于经典的一半）；hanoiMinMoves 按最大盘的位置递推最少步数，hanoiSolution 给最优解，hanoiReplay 与 hanoiLegal 判定每一步；答案每步编成「起点 × 3 + 终点」，最多 hanoiMaxMoves 步。
  - hanoi_page.dart：HanoiPage：点柱子拿起（浮到柱顶上方）、再点放下，或按住盘子直接拖；盘子扁平、塔在棋盘区垂直居中；违规轻震并晃一下退回；盘子配色以激活色为中心向两边偏色相，小盘浅大盘深；目标柱柱身着淡激活色、下面写「目标」；读屏每根柱子一个按钮；状态写步数与最少步数，可撤销。
- nonogram 数织（格子谜题）：
  - nonogram_rules.dart：NonogramRules：5、7、10、12、15 见方，随机涂一半多再按九宫格多数平滑成块，小三档左右对称；每行段数有上限（提示栏不至于太宽）、不出空行；逐行求解器 nonogramLineSolve 能解开才出（保证唯一、不用猜），推理轮数进难度分；nonogramSolveLine 是单行的动态规划推理；答案按行优先编成 0、1 字符串。
  - nonogram_page.dart：NonogramPage：单指点或拖改一串格（锁定在起点那一行或那一列，起点已是这种标记时这一笔是擦掉；起点之后只改空格），下方分段选涂色或标叉，可按笔撤销；双指缩放平移（格子小于 44 时才能放大，第二根手指落下时这一笔作废）；提示数字 14 号字跟着格子对齐（提示栏隔一行、一列铺淡底色，两位数比格宽时只横向压窄），这一行（列）对上时变淡，手指按着的那一格所在行列加浅底；解开后叉号与格线淡出、涂色格过渡成激活色的图案；读屏导航时每格一个按钮。

# 加一个游戏的步骤

1. 在本目录建子目录，照 hanoi 目录的命名写规则文件（实现 PuzzleRules，只用 PuzzleRandom 出题，出题前用求解器确认可解，需要唯一解的确认唯一）与对局页文件（PlaySession 加 PlayFrame，棋盘自己画；文字 14 号起、触区至少 48 或可放大；违规用 playRejected，落子用 playTick；解开先放收尾动画再 showPlayResult）。
2. 在 playground_catalog.dart 登记到用户定的子类里（id 发出后不改），写一句话玩法与玩法说明；服务器核不了的（拼手速、物理模拟）challengeable 写假。
3. 测试放这个游戏自己的文件（文件名用 playground_ 加游戏 id 加 _test，几个游戏并行开发时互不冲突）：规则部分测每档出题可解、参考解通过、违规不算、编解码往返与坏输入，页面部分走完一局并弹出结果；汉诺塔与数织的写法在 playground_rules_test.dart 与 playground_ui_test.dart。
4. 在本文件与 lib/playground/CLAUDE.md 的测试一节登记，在 CHANGELOG 的 Unreleased 下记一条（几个游戏并行开发时由合并的人统一写一条）；在模拟器上 360dp 加 1.3 倍字号与 411dp 标准两种条件下、深浅两色看过再交。

# 关键规则

- 难度分 1–10 的口径：按求解要走的步数与推理深度，同档的题分数相近，档与档之间单调上升；挑战模式计分直接用它，改口径前先看 lib/playground/CLAUDE.md 的长期路线。
- 视觉照设计语言：颜色取 CampusPalette 的角色、不写死色值（棋子配色可从激活色推出）；动效克制、减少动画时直接到位；一次画完的图形拼成一条路径，不在 paint 里逐个画小图形。

# 测试

- 规则：playground_rules_test.dart；页面：playground_ui_test.dart。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/playground/puzzle
- 本目录暂无单独的标记，用户对游戏清单的选择在 lib/playground/playground_catalog.dart 文件头。
