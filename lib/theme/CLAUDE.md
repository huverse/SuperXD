# theme 主题与通用视觉组件

定位：全应用共用的主题、配色、动效、玻璃材质和弹窗转场。只依赖本目录，唯一例外是日志出口 domain/campus_log.dart，不感知任何业务。设计语言见 UITEMP/design_language.md。

# 文件职责

- campus_palette.dart：CampusPalette 是设备级的完整色彩角色，有苔灰（默认）、雾蓝、藕粉、暮紫、燕麦五套，每套分浅色和深色。
  - accent 是控件激活色（开关开启轨道、滑杆已选段），同鸿蒙 component_activated、iOS 开关 onTintColor，与文字主色 primary 分开：primary 为文字可读压得深而灰，铺成大块轨道发闷。白色滑块对 accent 不低于 3:1。
- campus_theme.dart：
  - campusTheme 按配色和字体生成 ThemeData。headlineMedium（26）是底栏根页的大标题，titleLarge（18）是二级页标题。OutlinedButton 主题即次要按钮：内容区中性浅底胶囊配主色字、无描边。
  - campusFieldGap 给带浮动标签的输入框算上方间距，随字号缩放。
  - campusSystemOverlay 设置系统栏：导航栏全透明，按键明暗随主题变化。
  - CampusScrollBehavior：全局越界用弹性回弹、不加拉伸效果（拉伸会给列表套图像滤镜，里面的玻璃退成底色）；显式指定夹紧的列表不受影响。
  - 按压反馈同 iOS：不用扩散水波（NoSplash），按下整块变暗（highlightColor），松手淡出。卡片里的多行列表去掉卡片横向内边距、行自带边距，高亮横向铺满卡片；单项卡片直接让整卡可点。底栏的按压反馈由透镜承担，不叠变暗。
  - CampusBackground 是空包装，保留它只为兼容现有调用点。
- campus_background.dart：
  - CampusAtmosphere 是全应用唯一的背景循环（24 秒柔雾），放在 MaterialApp 上方，不随路由或列表项复制。
  - AtmospherePainter 负责绘制背景。
  - CampusWallpaper 是可选的自定义壁纸：设了壁纸时改画静态图，不再循环；按色调网格逐格铺一层淡化，保证直接压在背景上的文字可读。云雾仍是默认，高对比度时不显示壁纸。
  - 壁纸的模糊与透明度（0–100）来自 look 监听值：拖动滑杆时只重画背景，不重建应用；数值变化 160ms 平滑跟随，可读下限只在网格或配色变化时重算。
  - 云雾与壁纸互换、换图时交叉淡化 420ms；换上新图前先按铺满屏幕的尺寸解码好（precacheImage），从旧背景直接淡到新图。
  - FrostTexture 是固定的颗粒纹理，不逐帧生成随机噪点。
  - CampusBackdrop 向下提供一份同相位的背景副本，只给入场遮罩用。
- wallpaper_tone.dart：
  - WallpaperTone 是壁纸色调网格：导入时解码成小图，按格记下最暗与最亮的像素，运行时不再解码原图。
  - wallpaperVeilAlphas 按当前配色算每格最小淡化透明度（可读下限）：衬底色为 backgroundTop，叠在最不利的像素上，正文、次要文字和主色文字都不低于 4.8:1（给玻璃栏和取样留余量）。
  - wallpaperVeilAlpha 把用户透明度叠在下限之上（下限到完全盖住之间插值），单调不低于下限。
  - 每格结果先 3×3 取最大再 3×3 取平均：过渡平滑不显网格，且每格仍不低于所需。改动后要在模拟器上用高反差测试图复测。
- campus_motion.dart：CampusMotion 管理视觉动效的生命周期；另有玻璃控件专用的弹簧令牌（只给玻璃控件用，其余动效不回弹）；campusSpringCurve 是页面与底栏分支转场的曲线（临界阻尼弹簧归一化到固定时长，先快后慢、不回弹）。以下任一情况都不播放装饰动效：减少动画、后台、分支不可见、当前路由不在最上层。后台暂停动效不代表取消业务请求。
- campus_transitions.dart：
  - 统一时长：页面进入 360ms、返回 320ms，弹层 300ms。
  - campusPage 让 GoRouter 与 push 共用同一套 Material 路由契约。
  - CampusDialogRoute、showCampusDialog：统一的弹窗转场。
  - campusPageTransition：新旧页整屏并排平移、互不重叠，不淡入淡出；曲线为 campusSpringCurve，返回用翻转曲线；跟手返回期间及松手后的收尾按进度线性平移。
  - 跟手返回（CampusPageTransitions 内的 _CampusBackGesture）：Android 14 起的预测性返回，同 iOS、鸿蒙侧滑返回，页面随手指平移、松手从当前位置续接返回或回弹。只有最前面的页面响应（栈顶、允许返回、TickerMode 开启）；不用路由自带的 handleCommitBackGesture，它会把进度重置到 1 再倒放。需要 AndroidManifest 的 enableOnBackInvokedCallback。
  - CampusEntryFade：账号应用的整体入场。它挂在按代次重建的账号应用内，所以应用启动和每次切换账号时都会触发。内容不套透明度，由盖在上面的背景副本（CampusBackdrop）淡出，玻璃从第一帧起取到真实背景。
  - 共享弹窗：showCampusNotice 用于只读提示，showCampusConfirm 用于二次确认。
  - CampusGlassDialog：统一的玻璃弹窗，版式同 AlertDialog。options 对应 SimpleDialog 的选项；solid 固定实色（验证码弹窗用）。全应用弹窗一律用它，日期选择器除外。
  - showCampusToast：提示条，可带一个操作（如撤销）。沿用 SnackBar 的排队、读屏与滑动关闭，内容是 overlay 玻璃胶囊。不用库的 GlassToast，因为它的操作触区只有 32。用固定样式，只做高度展开不淡入。
  - showCampusDialog 的 glassPanel 默认为真，表示内容是玻璃面板、由面板自己显隐；日期选择器等系统弹窗传 false，仍整体改不透明度。
  - showCampusSheet、CampusSheetRoute：底部弹层，沿用系统弹层的拖动关闭、返回键与读屏，背景透明；内容放进 CampusSheetPanel（四周留 8 悬浮的 overlay 玻璃，圆角 24）。
  - CampusDialogRoute、CampusSheetRoute 经 CampusOverlayDepthRoute 登记 campusOverlayDepth。
- campus_loading.dart：
  - CampusLoader 绘制曲线加载动画，CampusLoading 是带文字的加载状态。
  - CampusBusyContent 让按钮在操作期间原地切换为忙碌态。
  - showCampusWaiting：只在已有的异步操作期间显示等待弹窗（延迟 150ms 出现），不增加业务等待时间。
- curve_geometry.dart：三种闭合曲线（无穷、玫瑰、李萨如）的几何与按弧长预采样。改编自 math-curve-loaders，授权说明见 assets/third_party_notices.txt。
- campus_icons.dart：CampusIcons 统一映射 Lucide 图标；CampusIcon 负责渲染单个图标；CampusMorphIcon 负责导航图标形变；configureCampusIcons 在启动时配置。
- glass_panel.dart：
  - GlassPanel 是液态玻璃面板，现只用于悬浮底栏。
  - CampusTopBar 是透明顶栏：无底板、无分割线，与主体同一背景，栏内按钮仍是玻璃。
  - CampusChrome 标记导航层（顶栏、悬浮按钮），其中的按钮画玻璃。
  - initializeCampusGlass 负责初始化玻璃渲染，失败时退回磨砂效果；campusGlassReady 表示是否初始化完成。
  - campusOverlayDepth 是正在显示的弹窗层数。大于 0 时顶栏和底栏改实色，不让玻璃叠玻璃；改实色与恢复都经 CampusGlassBlend 过渡。
  - CampusOverlayDepthRoute：浮层路由装入时层数加一，开始关闭（didPop）就减一，没经过 pop 被移除时在 dispose 补减，只减一次。
- campus_glass_controls.dart：
  - CampusGlassChip 是选择标签，复用主按钮的背景（内容区为中性色调胶囊），选中时带勾，宽度变化平滑展开。两三项的单选用 CampusSegmented。
  - CampusSwitchTile 是开关行，玻璃档用 GlassSwitch，实色档用系统 Switch；开启色都是 accent。
  - CampusSlider 是滑杆（0–1）：玻璃档用 GlassSlider（拖动时滑块化为玻璃透镜），实色档用系统 Slider 并合并读屏标签。GlassSlider 在系统取消与读屏增减时不回调 onChangeEnd，调用方要自行兜底保存。
  - 页面不再直接用 ChoiceChip、FilterChip、SwitchListTile、Slider。
- campus_glass_menu.dart：
  - showCampusMenu 从触发控件弹出 overlay 玻璃菜单，返回点选的值。菜单是路由：返回键关闭、读屏模态、经 CampusOverlayDepthRoute 登记层数。不用库的 GlassMenu，因为它直接插 OverlayEntry，返回键会退出底下的页面。
  - 展开按玻璃松手弹簧轻过冲一次，收回淡出不回弹；菜单项高至少 48，选中项着选中色并带勾。
  - CampusMenuField 是下拉字段，外观沿用带浮动标签的输入框，只在值变化时回调。
  - 页面不再直接用 DropdownButtonFormField、PopupMenuButton、showModalBottomSheet。
- campus_glass_tier.dart：玻璃档位。
  - 档位有四档：满档 full、标准 standard、磨砂 minimal、实色 solid。
  - resolveCampusGlassTier 按以下规则决定档位：无障碍条件走实色；简化模式或未就绪走磨砂；完整模式固定满档；自动模式跟随 GlassAdaptiveScope 的实测结果；限档时满档降为标准。
  - CampusGlassScope 向下传递模式与限档；外面常挂 GlassAdaptiveScope 采样帧耗时，只在自动模式下采用。按模式增减这一层会改变树结构，切换玻璃效果时整个应用被重建，所以不能这样做（test/campus_glass_test.dart 守护）。玻璃组件统一用 tierOf 取档位，并显式传给 AdaptiveGlass，不依赖库的隐式上限。
  - CampusGlassGuard 通过通道 superxd/glass 读写原生的限档状态，原生实现见 GlassGuard.kt。
- campus_glass_blend.dart：CampusGlassBlend 是玻璃换档的过渡（满档、标准、磨砂、未就绪之间，以及与实色互换）。使用方在玻璃内容层最底下铺同形状实色盖板（不透明度 cover），盖板渐显到不透明后才换档、再渐隐；换到实色就停在盖满。中途目标再变时从当前值续接，减少动画时直接换。用于 GlassPanel 与 CampusGlassSurface。
- campus_glass_material.dart：玻璃材质表。
  - 按角色区分：navigation（顶栏、底栏）、control（按钮、开关、标签）、overlay（菜单、弹层、弹窗、提示条）。
  - campusGlassSettings 按配色、角色和档位生成参数。满档以 iOS 27 预设为底并按配色轻着色：底色减薄、不加色散，背景饱和浅色 1.4、深色不加；选中或按下的控件底色铺厚。标准档和磨砂档保持升级前的参数。
  - 浮层满档完全雾化，不透出底层文字；浅色浮层各档整块均匀提亮（满档 .8，其余 .65）。底色、饱和与提亮都按模拟器五套配色深浅色实测取，改动后要重测玻璃上文字的对比度（不低于 4.5:1）。
  - 浮层传 floating 时加 campusFloatingShadow 投影，其余角色保持原有阴影。
  - campusGlassQuality 把档位映射为库的 GlassQuality。
- campus_glass_surface.dart：
  - CampusGlassSurface 是按钮和手势反馈共用的玻璃材质，本身不提供点击行为。
  - CampusOverlayGlass 是弹窗、菜单、弹层、提示条用的 overlay 玻璃面板，实色档用 surface。floating 表示没有遮罩、直接压在内容上（菜单、提示条），带柔和投影。
  - CampusOverlayReveal 由浮层路由提供显隐进度：有玻璃时面板用库的 GlassMaterializeTransition 驱动着色器可见度，实色时用 FadeTransition。
  - CampusGlassPresence 是玻璃控件的出现与消失（AnimatedOpacity 的玻璃版）：玻璃档用库的 GlassMaterialize，实色档改不透明度。
  - 按钮描边画在玻璃内容里（内描边），随玻璃一起显隐。
- campus_glass_button.dart：
  - 全局 FilledButton 主题用 CampusGlassButtonSurface 画背景，视觉高度约 38dp，触区至少 48dp。按所在层分流：在导航层（CampusChrome）或玻璃面板、浮层（GlassPanelScope）里是玻璃胶囊；其余属于内容区，画 CampusTonalSurface 色调胶囊（操作按钮主色浅底，选择标签中性浅底、选中 surfaceSelected 加主色细边，按下加深并缩到 97%）。
  - CampusGlassButtonSurface 是胶囊按钮，CampusGlassCircleButton 是圆形按钮（只用于顶栏操作和悬浮按钮，始终是玻璃）。圆形按钮默认 52，顶栏操作用 44。
  - 色调胶囊的底色按模拟器五套配色深浅色实测取，改动后要重测按钮文字对比度（不低于 4.5:1）。
- campus_glass_press.dart：玻璃控件的按压物理 CampusGlassPress。
  - 按下鼓起 6%，松手过冲一次后回位；内容只跟随一半。
  - 满档时在手指处画径向高光。减少动画时不形变。
  - 弹簧令牌在 campus_motion.dart：campusGlassSpring 用于按压与松手，campusGlassTravelSpring 用于指示器跨格移动。
- campus_surface.dart：CampusSurface 是通用卡片表面，可带点击。
- campus_segmented.dart：CampusSegmented 是内容区的分段控件（同 iOS 分段控件、鸿蒙 Segment）：中性浅底胶囊槽，选中项是浮起的实色胶囊并滑动切换，可拖动（规则见文件内人工决策），文字加粗不着主色，整行 48dp 触区。二至三项的单选（课表范围、消息、成绩视图与学期）一律用它。
- scroll_edge_fade.dart：ScrollEdgeFade 在浮动玻璃栏下只渐隐内容本身，露出真实背景；高对比度时不渐隐。它的子树里不能再放玻璃。
  - CampusScrollFade：页面滚动区的柔和边缘，透明顶栏下内容滚过上缘时自身渐隐（最多 24dp），下缘按底栏覆盖高度渐隐；遮罩常在，滚动不切换图层。顶栏页和 AppBar 页的滚动区都包一层；子树有玻璃开关或视频的页面（短视频解析、媒体预览）不包。
- third_party_licenses.dart：registerCampusLicenses 把第三方声明和字体许可注册进 LicenseRegistry。

# 关键规则

- 玻璃只用于导航层与浮层：悬浮底栏、顶栏按钮、悬浮按钮、弹窗、菜单、弹层、提示条和开关。内容区（页面与卡片里）的按钮与选择标签用色调胶囊，卡片和列表保持高遮色磨砂实卡，不叠玻璃（同苹果 HIG、鸿蒙 7）。新增玻璃组件一律从 campus_glass_material 取材质，从 CampusGlassScope.tierOf 取档位，不在组件里写死 LiquidGlassSettings。
- 玻璃换档与玻璃、实色互换不得突变：经 CampusGlassBlend 的盖板过渡，盖板画在玻璃内容层里，不是玻璃的祖先。
- 玻璃显隐不得用祖先 Opacity、FadeTransition 或 ShaderMask：玻璃在半透明图层下取不到背景，整段显示成底色实板，结束时才突然变回玻璃。浮层用 CampusOverlayReveal，控件用 CampusGlassPresence，页面与分支转场只平移不淡入淡出，入场用背景副本淡出。由 test/campus_glass_test.dart 的 expectGlassUnfaded、transition_sync_test.dart 与 account_lifecycle_test.dart 的转场中间帧检查守护。
- 颜色一律取 CampusPalette 的色彩角色，不在页面里写死色值。改配色要在深浅两套、所有配色、实际合成背景上测对比度，见 test/campus_glass_test.dart、test/atmosphere_test.dart。
- 必须尊重减少动画与无障碍设置。装饰动效用 CampusMotion.allowed 判断能否播放，业务转场不因为装饰暂停而跳过。
- 背景只画一份：新页面不再单独铺背景，也不给整页包遮罩。离屏遮罩会让玻璃取不到外层背景。唯一例外是入场的 360ms 内多画一份背景副本作遮罩。
- 页面、弹窗和转场的时长以 campus_transitions.dart 为准，不在页面里另设。
- 本层不写业务文案，也不做业务判断。
- 改视觉之前，先读本目录的人工决策注释，以及自动记忆里被否决的方案（切日胶囊、云雾、字体压缩、玻璃滚动边缘），不要重提。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/theme
- 本目录的标记位于以下几处：
  - 主按钮形态
  - 玻璃档位
  - 导航栏透明
  - 配色
  - 转场时长与路由契约
