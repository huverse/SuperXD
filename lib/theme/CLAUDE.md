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
- campus_motion.dart：CampusMotion 管理视觉动效的生命周期。以下任一情况都不播放装饰动效：减少动画、后台、分支不可见、当前路由不在最上层。后台暂停动效不代表取消业务请求。
- campus_transitions.dart：
  - 统一时长：页面进入 360ms、返回 320ms，弹层 300ms。
  - campusPage 让 GoRouter 与 push 共用同一套 Material 路由契约。
  - CampusDialogRoute、showCampusDialog：统一的弹窗转场。
  - CampusEntryFade：账号应用的整体淡入。它挂在按代次重建的账号应用内，所以应用启动和每次切换账号时都会触发。
  - 共享弹窗：showCampusNotice 用于只读提示，showCampusConfirm 用于二次确认。
- campus_loading.dart：
  - CampusLoader 绘制曲线加载动画，CampusLoading 是带文字的加载状态。
  - CampusBusyContent 让按钮在操作期间原地切换为忙碌态。
  - showCampusWaiting：只在已有的异步操作期间显示等待弹窗（延迟 150ms 出现），不增加业务等待时间。
- curve_geometry.dart：三种闭合曲线（无穷、玫瑰、李萨如）的几何与按弧长预采样。改编自 math-curve-loaders，授权说明见 assets/third_party_notices.txt。
- campus_icons.dart：CampusIcons 统一映射 Lucide 图标；CampusIcon 负责渲染单个图标；CampusMorphIcon 负责导航图标形变；configureCampusIcons 在启动时配置。
- glass_panel.dart：
  - GlassPanel 是液态玻璃面板，用于顶栏和底栏。
  - initializeCampusGlass 负责初始化玻璃渲染，失败时退回磨砂效果；campusGlassReady 表示是否初始化完成。
- campus_glass_surface.dart：CampusGlassSurface 是按钮和手势反馈共用的玻璃材质，本身不提供点击行为。
- campus_glass_button.dart：
  - 主按钮是紧凑的玻璃胶囊，视觉高度约 38dp，触区至少 48dp。
  - CampusGlassButtonSurface 是胶囊按钮，CampusGlassCircleButton 是圆形按钮。
- campus_surface.dart：CampusSurface 是通用卡片表面，可带点击。
- scroll_edge_fade.dart：ScrollEdgeFade 在浮动玻璃栏下只渐隐内容本身，露出真实背景；高对比度时不渐隐。它的子树里不能再放玻璃。
- third_party_licenses.dart：registerCampusLicenses 把第三方声明和字体许可注册进 LicenseRegistry。

# 关键规则

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
  - 导航栏透明
  - 配色
  - 转场时长与路由契约
