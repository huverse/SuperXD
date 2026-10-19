# theme 主题与通用视觉组件

定位：全应用共用的主题、配色、动效、玻璃材质和弹窗转场。只依赖本目录，唯一例外是日志出口 domain/campus_log.dart，不感知任何业务。设计语言见 UITEMP/design_language.md。

# 文件职责

- 色彩与主题：
  - campus_palette.dart：设备级色彩角色 CampusPalette，五套配色（苔灰默认、雾蓝、藕粉、暮紫、燕麦）各分浅深。accent 是控件激活色（开关轨道、滑杆、强调按钮底），与文字主色 primary 分开（primary 为可读压得深而灰，铺成大块会发闷）；dangerFill 是破坏性按钮的红底；accentText 是激活色作大号强调文字时用的颜色（深色提亮，对卡片底不低于 4.5:1）；attention 是只读状态的提醒色；tagColors 是六种标签色，顺序即存储序号，只能在末尾追加。
  - campus_theme.dart：campusTheme 按配色和字体生成 ThemeData：按钮 textStyle 显式带应用字体（不带会回落系统字体）；AppBar 返回图标与内容左边距 16 对齐、标题从 56 起（人工决策见文件内）；OutlinedButton 与 TextButton 是中性胶囊。另有 campusFieldGap（带浮动标签输入框的上方间距，随字号缩放）、campusSystemOverlay（系统栏透明）、CampusScrollBehavior（弹性回弹、不加拉伸效果，拉伸会让里面的玻璃退成底色）；按压反馈不用水波、按下整块变暗。CampusBackground 是空包装，只为兼容现有调用点。
  - campus_icons.dart：CampusIcons 统一映射 Lucide 图标，CampusIcon 渲染，CampusMorphIcon 做导航图标形变，configureCampusIcons 启动时配置。
- 背景：
  - campus_background.dart：CampusAtmosphere 是全应用唯一的背景循环（24 秒柔雾），放在 MaterialApp 上方，弹窗、弹层开着时停在原处（overlays 由组合根传 campusOverlayDepth，不然整屏模糊每帧重算）；CampusWallpaper 是可选的自定义壁纸（静态图，按色调网格逐格铺淡化保证文字可读，高对比度时不显示）；FrostTexture 是固定颗粒纹理；CampusBackdrop 提供同相位的背景副本，只给入场遮罩和压在弹窗上的页面转场用。换背景前先按屏幕尺寸解码（precacheImage），再交叉淡化。
  - wallpaper_tone.dart：壁纸色调网格 WallpaperTone（导入时解码成小图记每格最暗最亮像素）与可读下限 wallpaperVeilAlphas、wallpaperVeilAlpha：叠在最不利的像素上，正文、次要文字和主色文字都不低于 4.8:1。改动后要在模拟器上用高反差测试图复测。
- 动效与转场：
  - campus_motion.dart：CampusMotion 管理装饰动效的生命周期（减少动画、后台、分支不可见、路由不在最上层时都不播）；玻璃控件专用的弹簧令牌；campusSpringCurve 是页面与分支转场曲线（临界阻尼、不回弹）；CampusFirstFrameVsync 让转场从新内容首帧画完后开始计时，首帧慢时转场不被吃掉。
  - campus_transitions.dart：统一时长（进入 360ms、返回 320ms、弹层 300ms）与全部路由、弹窗：
    - campusPage 与 CampusPageRoute 是唯一的页面路由（不直接用 MaterialPageRoute，code_conventions_test.dart 守护）；页面转场新旧页整屏并排平移、不淡入淡出。页面推在弹窗或弹层之上时，进出转场期间垫一份同相位背景副本盖住弹窗（页面透明，不垫会叠成两层），副本拍成快照只贴图（直接画每帧要重画几层全屏渐变），停稳即撤。
    - 跟手返回 _CampusBackGesture 只让最前面的页面响应，不用路由自带的 handleCommitBackGesture（它会把进度重置到 1 再倒放）。CampusEntryFade 是按代次重建的账号应用入场（盖背景副本淡出）。
    - 共享弹窗 showCampusNotice、showCampusConfirm（destructive 时主按钮警示红）与玻璃弹窗 CampusGlassDialog（按钮一到两个等宽并排，任一个放不下半宽或三个及以上时竖排、主操作在最上，[人工决策] 在操作区；全应用弹窗都用它，日期选择器除外）。
    - showCampusToast 提示条：在弹层、弹窗、菜单里调用时插进根 Overlay 浮在最上层（[人工决策] 在文件内；不给弹层套 Scaffold，它的 Material 会吃掉点按）。
    - showCampusSheet 与 CampusSheetPanel 是底部弹层（键盘弹出时整块浮到键盘上方）；弹窗与弹层都经 CampusOverlayDepthRoute 登记层数。
  - campus_rolling_text.dart：数字滚动 CampusRollingText（同 iOS 实时活动的数字过渡）：只有变了的位滚动，倒数时方向相反，位按右对齐，减少动画时直接换。
  - campus_refresh.dart：下拉刷新 CampusRefreshControl（基于 CupertinoSliverRefreshControl），放在 CustomScrollView 第一个 sliver，指示器是曲线动效、至少停留 600ms。
  - campus_loading.dart：曲线加载 CampusLoader 与带文字的加载状态 CampusLoading（整页样式自己居中；联网等待超过 8 秒说明在等谁）；CampusLoadError 是整块读取失败（原因加带图标的「重试」）；CampusBusyContent 让按钮原地切换忙碌态；showCampusWaiting 只在已有的异步操作期间显示等待弹窗。
  - curve_geometry.dart：三种闭合曲线的几何与按弧长预采样。改编自 math-curve-loaders，不随项目以 GPL 再授权，见 assets/third_party_notices.txt 与文件内人工决策。
- 玻璃：
  - glass_panel.dart：液态玻璃面板 GlassPanel（现只用于悬浮底栏）、透明顶栏 CampusTopBar、导航层标记 CampusChrome、玻璃初始化 initializeCampusGlass（失败退回磨砂）；campusOverlayDepth 是正在显示的弹窗层数，大于 0 时顶栏和底栏改实色，不让玻璃叠玻璃。
  - campus_glass_tier.dart：四档（满档、标准、磨砂、实色）与 resolveCampusGlassTier（无障碍走实色，简化或未就绪走磨砂，完整固定满档，自动跟随实测，限档时满档降为标准）。CampusGlassScope 向下传模式与限档，按模式增减树层会让整个应用重建，所以不能这样做（campus_glass_test.dart 守护）；玻璃组件统一用 tierOf 取档位。CampusGlassGuard 经通道 superxd/glass 读写原生限档状态（GlassGuard.kt），点「完整」解除本版本限档（人工决策见文件内）。
  - campus_glass_material.dart：玻璃材质表，按角色（navigation、control、overlay）、配色与档位生成参数 campusGlassSettings。磨砂档不调饱和：饱和不为 1 时库会在背景模糊里再嵌一层 BackdropFilter，OPPO 上键盘顶起的弹层会整块画黑（campus_glass_test.dart 守护「简化档弹层只有一层 BackdropFilter」）。底色、饱和与提亮都按五套配色深浅色实测取，改动后重测玻璃上文字的对比度（不低于 4.5:1）。
  - campus_glass_blend.dart：玻璃换档的过渡 CampusGlassBlend：玻璃内容层最底下铺同形状实色盖板，渐显到不透明后才换档、再渐隐。
  - campus_glass_surface.dart：按钮与手势反馈共用的玻璃材质 CampusGlassSurface、浮层面板 CampusOverlayGlass、浮层显隐 CampusOverlayReveal 与控件出现消失 CampusGlassPresence（AnimatedOpacity 的玻璃版）。
  - campus_glass_button.dart：全局 FilledButton 背景 CampusGlassButtonSurface：视觉约 38dp、触区至少 48dp；在导航层或玻璃面板里是玻璃胶囊，内容区画色调胶囊 CampusTonalSurface；圆形按钮 CampusGlassCircleButton 只用于顶栏操作与悬浮按钮。按钮四级：强调 campusProminent（每屏、每个弹窗一个主操作）、警示 campusDestructive、普通、中性；句中链接用 campusLink（规则见文件内人工决策）。色调胶囊底色改动后重测按钮文字对比度（不低于 4.5:1）。
  - campus_glass_press.dart：玻璃控件的按压物理 CampusGlassPress（按下鼓起、松手过冲一次回位，减少动画时不形变）。
  - campus_glass_controls.dart：选择标签 CampusGlassChip（选中前后是同一个按钮，只在按钮里给勾号让位、淡入；选中状态与按钮合成一个读屏节点，否则读屏听不到“已选中”；减少动画时不包 AnimatedSize，它时长为 0 会在自己的布局里报错）、开关行 CampusSwitchTile、滑杆 CampusSlider（GlassSlider 在系统取消与读屏增减时不回调 onChangeEnd，调用方要兜底保存）。页面不再直接用 ChoiceChip、FilterChip、SwitchListTile、Slider。
  - campus_glass_menu.dart：玻璃菜单 showCampusMenu（是路由：返回键关闭、读屏模态、登记层数；不用库的 GlassMenu，它直接插 OverlayEntry，返回键会退出底下的页面）与下拉字段 CampusMenuField。页面不再直接用 DropdownButtonFormField、PopupMenuButton、showModalBottomSheet。
- 通用组件：
  - campus_surface.dart：通用卡片表面 CampusSurface，可带点击（带点击时读屏报按钮）。
  - campus_segmented.dart：内容区分段控件 CampusSegmented，二至三项的单选一律用它（规则见文件内人工决策）。
  - campus_search_field.dart：搜索框 CampusSearchField：胶囊形、底色描边同卡片，占位文字不用浮动标签，有字时出「清空搜索」；成绩页与学习通群聊签到、按课程共用，页面不再自己拼搜索用的 TextField。
  - campus_field_table.dart：详情里的「标签 值」两列行 CampusFieldTable（左列次要色按最宽标签对齐，值可选中复制，空值的行不画）；课程详情与成绩详情共用。
  - campus_prose.dart：按行排版的长说明 CampusProse：「1. 正文」编号悬挂缩进，「登录：正文」冒号前的段内小标题半粗，以冒号结尾的整行是小节标题；协议、隐私政策、首次同意弹窗与学习通同意说明共用，文字原样显示。
  - campus_animated_list.dart：列表增删的过渡（[人工决策] 在文件头）：CampusAnimatedColumn 按 key 比对前后子项，新的展开淡入、去掉的原地收起；CampusAppear 给按需建的长列表里新到的一项展开。第一次显示不动画、减少动画时直接换，只用于没有玻璃的内容区列表。
  - dot_separated_text.dart：「甲 · 乙」式说明行 DotSeparatedText：按「 · 」分项放进 Wrap 换行，不把词拆成孤字，读屏读整句；page 层与百宝箱共用。
  - scroll_edge_fade.dart：ScrollEdgeFade 在浮动玻璃栏下只渐隐内容本身（子树里不能再放玻璃）；CampusScrollFade 是页面滚动区的柔和边缘，子树有玻璃开关或视频的页面不包。
  - third_party_licenses.dart：registerCampusLicenses 把本项目 GPL-3.0 全文、第三方声明和两套字体许可注册进 LicenseRegistry。

# 关键规则

- 玻璃只用于导航层与浮层：悬浮底栏、顶栏按钮、悬浮按钮、弹窗、菜单、弹层、提示条和开关。内容区的按钮与选择标签用色调胶囊，卡片和列表保持磨砂实卡，不叠玻璃。新增玻璃组件一律从 campus_glass_material 取材质、从 CampusGlassScope.tierOf 取档位，不在组件里写死 LiquidGlassSettings。
- 玻璃换档与玻璃、实色互换不得突变：经 CampusGlassBlend 的盖板过渡，盖板画在玻璃内容层里，不是玻璃的祖先。
- 玻璃显隐不得用祖先 Opacity、FadeTransition 或 ShaderMask（半透明图层下玻璃取不到背景，整段显示成底色实板）：浮层用 CampusOverlayReveal，控件用 CampusGlassPresence，页面与分支转场只平移不淡入淡出，入场用背景副本淡出。由 campus_glass_test.dart 的 expectGlassUnfaded、transition_sync_test.dart 与 account_lifecycle_test.dart 的转场中间帧检查守护。
- 给磨砂档加任何参数前，先确认不会让库多嵌一层 BackdropFilter。
- 颜色一律取 CampusPalette 的色彩角色，不在页面里写死色值；改配色要在深浅两套、所有配色、实际合成背景上测对比度。
- 必须尊重减少动画与无障碍设置：装饰动效用 CampusMotion.allowed 判断，业务转场不因装饰暂停而跳过。
- 背景只画一份：新页面不单独铺背景，也不给整页包遮罩（离屏遮罩会让玻璃取不到外层背景）；例外只有两处背景副本：账号应用入场的 360ms，以及页面推在弹窗、弹层上时的进出转场期间。
- 页面、弹窗和转场的时长以 campus_transitions.dart 为准，不在页面里另设。本层不写业务文案，也不做业务判断。
- 改视觉之前先读本目录的人工决策注释，以及自动记忆里被否决的方案（切日胶囊、云雾、字体压缩、玻璃滚动边缘），不要重提。
- 性能观察项：FrostTexture 逐点绘制颗粒，没有真机 profile 证据前不要改。

# 测试

- 玻璃与按钮：campus_glass_test.dart、campus_glass_button_test.dart。
- 背景、配色与深色：atmosphere_test.dart、dark_mode_test.dart、wallpaper_test.dart。
- 动效与转场：campus_motion_test.dart、transition_sync_test.dart、account_lifecycle_test.dart（入场与转场中间帧）。
- 通用组件：theme_components_test.dart（长说明排版、列表增删过渡、底部弹层挂根导航器）。
- 规范守护：code_conventions_test.dart（不直接用 MaterialPageRoute、setState 不返回 Future、只有图标的 IconButton 带 tooltip、⋯菜单破坏性项标警示色）。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/theme
- 本目录的标记位于：主按钮形态、玻璃档位与限档、导航栏透明、透明顶栏、云雾背景、图标形变、配色、转场时长与路由契约、转场弹簧曲线与跟手返回、玻璃换档与弹窗期间栏的过渡、控件激活色与强调按钮、弹窗按钮排布、壁纸透明度语义、二级页顶栏间距、分段控件、弹层里的提示条、曲线授权。
