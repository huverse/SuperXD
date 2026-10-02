# theme 主题与通用视觉组件

定位：全应用共用的主题、配色、动效、玻璃材质和弹窗转场。只依赖本目录，唯一例外是日志出口 domain/campus_log.dart，不感知任何业务。设计语言见 UITEMP/design_language.md。

# 文件职责

- campus_palette.dart：CampusPalette 是设备级的完整色彩角色，有苔灰（默认）、雾蓝、藕粉、暮紫、燕麦五套，每套分浅色和深色。
- campus_theme.dart：
  - campusTheme 按配色和字体生成 ThemeData。
  - campusFieldGap 给带浮动标签的输入框算上方间距，随字号缩放。
  - campusSystemOverlay 设置系统栏：导航栏全透明，按键明暗随主题变化。
  - CampusBackground 是空包装，保留它只为兼容现有调用点。
- campus_background.dart：
  - CampusAtmosphere 是全应用唯一的背景循环（24 秒柔雾），放在 MaterialApp 上方，不随路由或列表项复制。
  - AtmospherePainter 负责绘制背景。
  - FrostTexture 是固定的颗粒纹理，不逐帧生成随机噪点。
- campus_motion.dart：CampusMotion 管理视觉动效的生命周期；另有玻璃控件专用的弹簧令牌（只给玻璃控件用，其余动效不回弹）。以下任一情况都不播放装饰动效：减少动画、后台、分支不可见、当前路由不在最上层。后台暂停动效不代表取消业务请求。
- campus_transitions.dart：
  - 统一时长：页面进入 360ms、返回 320ms，弹层 300ms。
  - campusPage 让 GoRouter 与 push 共用同一套 Material 路由契约。
  - CampusDialogRoute、showCampusDialog：统一的弹窗转场。
  - CampusEntryFade：账号应用的整体淡入。它挂在按代次重建的账号应用内，所以应用启动和每次切换账号时都会触发。
  - 共享弹窗：showCampusNotice 用于只读提示，showCampusConfirm 用于二次确认。
  - CampusGlassDialog：统一的玻璃弹窗，版式同 AlertDialog。options 对应 SimpleDialog 的选项；solid 固定实色（验证码弹窗用）。全应用弹窗一律用它，日期选择器除外。
  - showCampusToast：提示条，可带一个操作（如撤销）。沿用 SnackBar 的排队、读屏与滑动关闭，内容是 overlay 玻璃胶囊。不用库的 GlassToast，因为它的操作触区只有 32。
  - CampusDialogRoute 装入和销毁时增减 campusOverlayDepth。
- campus_loading.dart：
  - CampusLoader 绘制曲线加载动画，CampusLoading 是带文字的加载状态。
  - CampusBusyContent 让按钮在操作期间原地切换为忙碌态。
  - showCampusWaiting：只在已有的异步操作期间显示等待弹窗（延迟 150ms 出现），不增加业务等待时间。
- curve_geometry.dart：三种闭合曲线（无穷、玫瑰、李萨如）的几何与按弧长预采样。改编自 math-curve-loaders，授权说明见 assets/third_party_notices.txt。
- campus_icons.dart：CampusIcons 统一映射 Lucide 图标；CampusIcon 负责渲染单个图标；CampusMorphIcon 负责导航图标形变；configureCampusIcons 在启动时配置。
- glass_panel.dart：
  - GlassPanel 是液态玻璃面板，用于顶栏和底栏。
  - initializeCampusGlass 负责初始化玻璃渲染，失败时退回磨砂效果；campusGlassReady 表示是否初始化完成。
  - campusOverlayDepth 是正在显示的弹窗层数。大于 0 时顶栏和底栏改实色，不让玻璃叠玻璃。
- campus_glass_controls.dart：
  - CampusGlassChip 是选择标签，复用主按钮的玻璃与按压，选中时带勾。
  - CampusSwitchTile 是开关行，玻璃档用 GlassSwitch，实色档用系统 Switch。
  - 页面不再直接用 ChoiceChip、FilterChip、SwitchListTile。
- campus_glass_tier.dart：玻璃档位。
  - 档位有四档：满档 full、标准 standard、磨砂 minimal、实色 solid。
  - resolveCampusGlassTier 按以下规则决定档位：无障碍条件走实色；简化模式或未就绪走磨砂；完整模式固定满档；自动模式跟随 GlassAdaptiveScope 的实测结果；限档时满档降为标准。
  - CampusGlassScope 向下传递模式与限档；自动模式下外包 GlassAdaptiveScope 采样帧耗时。玻璃组件统一用 tierOf 取档位，并显式传给 AdaptiveGlass，不依赖库的隐式上限。
  - CampusGlassGuard 通过通道 superxd/glass 读写原生的限档状态，原生实现见 GlassGuard.kt。
- campus_glass_material.dart：玻璃材质表。
  - 按角色区分：navigation（顶栏、底栏）、control（按钮、开关、标签）、overlay（菜单、弹层、弹窗、提示条）。
  - campusGlassSettings 按配色、角色和档位生成参数。满档以 iOS 27 预设为底并按配色着色，色散只给控件与浮层；标准档和磨砂档保持升级前的参数。
  - 浮层满档完全雾化，不透出底层文字；浅色浮层各档整块均匀提亮。提亮值按模拟器五套配色实测取，改动后要重测弹窗次要文字对比度。
  - campusGlassQuality 把档位映射为库的 GlassQuality。
- campus_glass_surface.dart：
  - CampusGlassSurface 是按钮和手势反馈共用的玻璃材质，本身不提供点击行为。
  - CampusOverlayGlass 是弹窗、提示条用的 overlay 玻璃面板，实色档用 surface。
- campus_glass_button.dart：
  - 主按钮是紧凑的玻璃胶囊，视觉高度约 38dp，触区至少 48dp。全局 FilledButton 主题用它画背景，所以所有主操作都是玻璃按钮。
  - CampusGlassButtonSurface 是胶囊按钮，CampusGlassCircleButton 是圆形按钮。圆形按钮默认 52，顶栏操作用 44。
- campus_glass_press.dart：玻璃控件的按压物理 CampusGlassPress。
  - 按下鼓起 6%，松手过冲一次后回位；内容只跟随一半。
  - 满档时在手指处画径向高光。减少动画时不形变。
  - 弹簧令牌在 campus_motion.dart：campusGlassSpring 用于按压与松手，campusGlassTravelSpring 用于指示器跨格移动。
- campus_surface.dart：CampusSurface 是通用卡片表面，可带点击。
- scroll_edge_fade.dart：ScrollEdgeFade 在浮动玻璃栏下只渐隐内容本身，露出真实背景；高对比度时不渐隐。它的子树里不能再放玻璃。
- third_party_licenses.dart：registerCampusLicenses 把第三方声明和字体许可注册进 LicenseRegistry。

# 关键规则

- 玻璃只用于浮在内容之上的导航与控件层，内容卡片和列表保持高遮色磨砂实卡，不叠玻璃。新增玻璃组件一律从 campus_glass_material 取材质，从 CampusGlassScope.tierOf 取档位，不在组件里写死 LiquidGlassSettings。
- 颜色一律取 CampusPalette 的色彩角色，不在页面里写死色值。改配色要在深浅两套、所有配色、实际合成背景上测对比度，见 test/campus_glass_test.dart、test/atmosphere_test.dart。
- 必须尊重减少动画与无障碍设置。装饰动效用 CampusMotion.allowed 判断能否播放，业务转场不因为装饰暂停而跳过。
- 背景只画一份：新页面不再单独铺背景，也不给整页包遮罩。离屏遮罩会让玻璃取不到外层背景。
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
