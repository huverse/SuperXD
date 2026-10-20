# toolbox 百宝箱

定位：设备级工具集，不需要教务登录，只依赖 domain 与 theme，不依赖教务相关的任何层，不读取教务凭据或 cookie；切换账号时下载任务不销毁。当前注册了三个工具：短视频解析与下载、学习通签到、快递（拼多多身份码与快递查询）。学习通的文件与规则在 chaoxing/CLAUDE.md，快递在 express/CLAUDE.md，download 与 short_video 两个子目录登记在本文件。

# 文件职责

- 框架：
  - toolbox_runtime.dart：设备级组合根 ToolboxRuntime。在应用支持目录的 toolbox 子目录下打开 toolbox.db、资源目录与下载目录；组装下载管理、后台传输与文件导出这些公共能力，不替任何工具组装业务对象；跟随前后台恢复下载。注册表由组合根传入，工具服务经 runtime.service 取用、退出时按接口统一关闭，打开失败不留缓存。组合根注入的能力：relayUrl（中转地址，只来自构建参数）、shareVideo（分享给好友，为空不显示入口，百宝箱不感知私信）、pickImage 与 pickImages（取图，缓存副本用完必须 discard）、扫码、campusTimetable（本应用课表今天的课，只读，给学习通推断正在上的课；为空当没有课表）。
  - toolbox_catalog.dart：工具注册表 toolboxCatalog，工具只在这一处登记（名称、图标、页面、资源与服务），路由按这里的 id 生成免登录的工具路由；工具 id 全处统一（路由、服务、同意记录同一个 id，[人工决策] 在文件头）。
  - toolbox_module.dart：ToolboxModule 描述一个工具：id、名称、图标、页面构造器、可选的按需资源、可选的服务打开函数 openService（登记了就要给 clearedData 写明清除数据会删什么）与可选的好友分享卡片入口 openShared。ToolboxServiceContext 是框架交给工具服务的公共能力。
  - toolbox_page.dart：百宝箱首页 ToolboxPage：有按需资源的工具可「卸载」，有本机数据的工具（登记了 openService）可「清除数据」，⋯与右滑揭示都须点击确认（人工决策见文件内）。
  - toolbox_models.dart：公共模型与接口：ToolboxException、ToolboxCancellation、ToolboxResource、ToolboxDownloadRequest、ToolboxDownload 及其状态机（origin 是发起工具的附加信息，下载管理原样存取），接口 ToolboxTransfer、ToolboxFilePublisher、ToolboxService（close 与 clearData）。
  - toolbox_store.dart：toolbox.db：downloads（下载记录）、consent（按来源与版本记录同意，清除工具数据时按工具 id 撤销）、resources（已装的按需资源）。旧版本的 toolbox_preferences、parse_history 属于短视频，由短视频库打开时搬走后删表。
  - toolbox_resource_manager.dart：重型按需资源的安装、校验（版本、sha256、字节数）与卸载；每个工具只留当前版本，卸载只删本工具的资源、不删用户已导出的文件。
  - toolbox_url.dart：toolboxPublicUrl 只接受公开的 http 或 https 地址（拒绝本机、内网、带凭据或非标准端口，长度上限 8192）；shortVideoInput 从分享文案中提取唯一的作品链接。
- download 下载：
  - toolbox_download_manager.dart：通用下载管理 ToolboxDownloadManager，不认识任何工具的数据（[人工决策] 在 enqueue）。按工具 id 与 identity 加每项 id 去重；负责入队、暂停、继续、取消、校验、导出与清理，clearTool 清除一个工具的下载数据（已导出的文件不动）。每组 1–100 项、待处理任务组最多 10 个、同时传输最多 2 个。
  - background_transfer.dart：基于 background_downloader 的后台传输 BackgroundTransfer；没有通知权限时改用普通 WorkManager 任务，避免 ANR。
  - android_file_publisher.dart：经通道 superxd/toolbox_files 调原生 ToolboxFileExporter.kt 导出到 Download/SuperXD。publish 是下载管理的导出（source 限定下载目录）；publishExternal 是一次性导出（source 只认应用缓存目录、只放行图片 mime、文件名按名幂等且不得含分隔符与控制字符）。
  - downloads_page.dart：下载管理页 DownloadsPage，只列给定工具 id 的任务，按组展示，整组操作在⋯里，条目顺序稳定；给了 reopenLabel 时失败任务可交回调用方重做。
  - download_status.dart：结果页与下载页共用的状态文案、进度条 DownloadProgress 与操作按钮 downloadActions。
- short_video 短视频：
  - short_video_service.dart：短视频的服务 ShortVideoService：自己组装解析来源（现在只有 BugPK）、打开自己的库、经框架下载管理下载（toolId 为 short_video）；清除数据取消并删本工具的下载记录、删库、撤各来源同意，已导出文件保留（[人工决策] 在文件内）。
  - short_video_store.dart：short_video.db：偏好（解析来源、参与自动解析的来源、历史开关）与解析历史；第一次打开从框架库搬旧数据（先写后删、不覆盖已有的）；destroy 删库。
  - parse_source.dart：解析来源端口：ParseSource（id、域名、适配版本、授权版本、最小请求间隔）与实现接口 ParseProvider。
  - parse_coordinator.dart：解析编排 ParseCoordinator：总预算 30 秒、单次最多 25 秒；成功结果进最多 20 条、保留 2 分钟的 LRU；按来源限制间隔，限流时按对方给的时间退避；自动模式最多依次试 3 个已启用且已同意的来源（[人工决策] 在文件内）。
  - parse_http.dart：解析用的 HTTP 封装：25 秒超时、响应上限 1MB，识别限流，退避限制在 1–300 秒。
  - bugpk_video_parser.dart：BugPK 来源的实现。
  - parse_result.dart：解析结果 ParseResult、失败类型 ParseFailure 与失败码、每次尝试的记录。
  - media_resource.dart：结果里的单项媒体 MediaResource（视频、图片、音频），下载时由服务转成通用下载项。
  - short_video_controller.dart：短视频页状态：来源选择与启用、历史开关、解析与取消；从历史或下载任务重开时按原来源解析，不改写用户保存的来源选择。
  - short_video_page.dart：短视频页：首次使用来源前要用户同意；最近解析与下载入口可直达结果页；解析设置在底部弹层（[人工决策] 在文件内）。autoParse 打开好友分享的作品时直接开始解析，首次使用来源仍先征得本人同意。
  - media_result_page.dart：结果页：预览与逐项下载，下载按钮原地切换为进度、暂停继续，完成后变为打开；注入了 shareVideo 时可分享给好友（只发作品原链接与标题作者）。汇总「进行中」含排队项（[人工决策] 在文件内）。
  - media_preview.dart：视频预览 MediaPreview 与图集预览 GalleryPreview。
  - media_image.dart：网络图片 MediaImage，加载失败后点按重试，不自动循环请求。
  - parse_history_page.dart：解析历史全部页 ParseHistoryPage 与条目 ParseHistoryTile，可删除单条与清空。

# 关键规则

- 第三方来源：每个来源、每个授权版本都单独征得同意，旧的同意不扩大到新来源或新版本；自动模式只试已启用且已同意的来源，不并发广播链接；接入新来源或把链接发给新服务之前，先让用户确认。
- 网络：解析总预算 30 秒、单次响应上限 1MB；媒体地址必须是公网 https，拒绝本机和内网地址。真实作品链接只在用户授权后联调，离线测试一律用合成数据。
- 解析历史：只存本机 short_video.db，最多 80 条且保留 30 天；默认开启（未设置视为开启，用户关了保持关闭）；不保存签名的媒体地址，删历史不删已下载的文件。
- 下载与导出：
  - 导出成功以原生侧 is_pending=0 且哈希一致为准（background_downloader 在清除 pending 失败时仍报成功，所以自写 MediaStore 适配）；插件接受暂停请求不代表已暂停，要等实际的状态事件。
  - 导出前只按文件头识别类型（先查 mime 默认表，再查下载管理补充的规则），不按 Content-Type 或链接后缀兜底；音频的 MP4 容器按 audio/mp4 导出。
  - 待保存不带错误时是中性等待（排队导出或等回前台），带错误才显示重试保存，判定见 ToolboxDownload.saveFailed。
  - 已结束的下载记录最多保留 100 项且 30 天；创建超过 24 小时仍未完成的任务在启动时取消。导出的文件归用户所有，卸载工具、清除数据都不删。
- 清除数据：工具服务自己清（ToolboxService.clearData），框架再撤掉按工具 id 记的同意记录并从缓存拿掉服务；登记了 openService 的工具必须给 clearedData。
- 轻量逻辑随应用发布，只有重型纯资源才按需安装；解析器没有大资源，不显示假的下载安装过程。
- 性能观察项：结果页和下载页随进度通知整页重建，没有真机 profile 证据前不要改。

# 测试

- toolbox_widget_test.dart、toolbox_download_test.dart：首页、注册表与下载管理。
- toolbox_media_features_test.dart：短视频库迁移、旧下载记录兼容、按工具清空下载、清除数据、分享卡片按注册表打开。
- short_video_parser_test.dart、media_image_test.dart；支撑在 toolbox_test_support.dart。
- 手动入口：tool/verify_toolbox.dart（Android 原生下载与导出）。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/toolbox android/app/src
- 本目录（不含学习通）的标记位于：免登录与设备级归属（toolbox_runtime.dart）、资源卸载范围（toolbox_resource_manager.dart）、单点登记与工具 id 统一、好友分享走注册表（toolbox_catalog.dart）、卸载确认与清除数据（toolbox_page.dart）、下载管理通用化（toolbox_download_manager.dart）、短视频服务化与清除数据（short_video_service.dart）、历史默认开启（short_video_store.dart）、来源选择（parse_coordinator.dart）、汇总「进行中」含排队项（media_result_page.dart、downloads_page.dart）、解析设置底部弹层（short_video_page.dart）；公共目录导出在 ToolboxFileExporter.kt。
