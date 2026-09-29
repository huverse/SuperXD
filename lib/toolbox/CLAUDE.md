# toolbox 百宝箱

定位：设备级工具集，不需要教务登录，也不依赖教务相关的任何层（只依赖 domain 与 theme）。不读取教务凭据或 cookie；切换账号时，下载任务不销毁。当前只注册了一个工具：短视频解析与下载。子目录 download 与 short_video 也登记在本文件。

# 文件职责

- 框架：
  - toolbox_runtime.dart：ToolboxRuntime 是设备级组合根。
    - 在应用支持目录的 toolbox 子目录下，打开 toolbox.db、资源目录和下载目录。
    - 组装 ParseCoordinator（当前只有 BugPK）、下载管理器、后台传输和文件导出。
    - 跟随应用前后台状态恢复下载。
  - toolbox_catalog.dart：工具注册表 toolboxCatalog。路由按这里的 id 生成免登录的工具路由。
  - toolbox_module.dart：ToolboxModule 描述一个工具，字段有 id、名称、图标、页面构造器和可选的按需资源。
  - toolbox_page.dart：百宝箱首页 ToolboxPage，展示工具列表。右滑只揭示卸载按钮，卸载须点击确认。
  - toolbox_models.dart：公共模型与接口。
    - 模型：ToolboxException、ToolboxCancellation、ToolboxResource、ToolboxDownload 及其状态机。
    - 接口：ToolboxTransfer（传输）、ToolboxFilePublisher（导出）。
  - toolbox_store.dart：ToolboxStore 管理 toolbox.db，表如下：
    - downloads：下载记录，完整状态存在 payload 里。
    - consent：按来源与版本记录用户同意。
    - resources：已安装的按需资源。
    - toolbox_preferences：偏好设置，例如 parse_source、history_enabled。
    - parse_history：解析历史。
  - toolbox_resource_manager.dart：重型按需资源的安装、校验与卸载。
    - 按版本、sha256 和字节数校验。
    - 每个工具只保留当前版本。
    - 卸载只删本工具的资源，不删用户已导出的文件。
  - toolbox_url.dart：链接安全。
    - toolboxPublicUrl：只接受公开的 http 或 https 地址，拒绝本机、内网、带凭据或非标准端口的地址，长度上限 8192。
    - shortVideoInput：从分享文案中提取唯一的作品链接。
  - media_resource.dart：解析结果里的单项媒体 MediaResource，类型分视频、图片、音频。
- download 下载：
  - toolbox_download_manager.dart：下载管理器 ToolboxDownloadManager。
    - 负责入队、去重、暂停、继续、取消、校验、导出和清理。
    - 每组 1–100 项；待处理任务组最多 10 个；同时传输最多 2 个。
    - 已结束的记录最多保留 100 项且 30 天。创建超过 24 小时仍未完成的任务，在启动时取消。
  - background_transfer.dart：基于 background_downloader 的后台传输 BackgroundTransfer。未授予通知权限时，改用普通 WorkManager 任务，避免 ANR。
  - android_file_publisher.dart：通过 MethodChannel superxd/toolbox_files 调用原生 ToolboxFileExporter.kt，把文件导出到公共目录 Download/SuperXD。
  - downloads_page.dart：下载管理页 DownloadsPage，按组展示任务。整组操作在⋯菜单里，条目顺序稳定。
  - download_status.dart：共享组件，包括状态文案、进度条 DownloadProgress 和操作按钮 downloadActions，供结果页和下载页共用。
- short_video 短视频：
  - parse_source.dart：解析来源端口。
    - ParseSource 描述一个来源：id、域名、适配版本、授权版本、最小请求间隔。
    - ParseProvider 是来源的实现接口。
  - parse_coordinator.dart：ParseCoordinator 负责解析编排。
    - 总预算 30 秒，单次尝试最多 25 秒。
    - 成功结果放进最多 20 条的 LRU 缓存，保留 2 分钟。
    - 按来源限制请求间隔，遇到限流按对方返回的时间退避。
    - 自动模式最多依次尝试 3 个已启用且已同意的来源。
  - bugpk_video_parser.dart：BugPK 来源的实现。
  - parse_http.dart：解析用的 HTTP 封装。25 秒超时，响应上限 1MB；识别限流，退避时间限制在 1–300 秒之间。
  - parse_result.dart：解析结果 ParseResult、失败类型 ParseFailure 与失败码、每次尝试的记录。
  - short_video_controller.dart：短视频页状态 ShortVideoController。
    - 管理来源选择与启用、历史开关、解析与取消。
    - 从历史或下载任务重开时，按原来源解析，不改写用户保存的来源选择。
  - short_video_page.dart：短视频页 ShortVideoPage。
    - 首次使用来源前需要用户同意。
    - 页面有输入框、解析和取消。
    - 有最近解析与下载入口；历史或下载任务可直达结果页。
  - media_result_page.dart：结果页 MediaResultPage，展示预览和逐项下载。下载按钮原地切换为进度、暂停继续，完成后变为打开。
  - media_preview.dart：视频预览 MediaPreview 与图集预览 GalleryPreview。
  - media_image.dart：网络图片 MediaImage。加载失败后点按重试，不自动循环请求。
  - parse_history_page.dart：解析历史全部页 ParseHistoryPage 和条目组件 ParseHistoryTile，支持删除单条与清空。

# 关键规则

- 第三方来源：
  - 每个来源、每个授权版本都要单独征得同意。旧的同意不会扩大到新来源或新版本。
  - 自动模式只尝试已启用且已同意的来源，不并发广播链接。
  - 接入新来源，或把链接发给新服务之前，必须先让用户确认。
- 解析历史：
  - 默认开启。未设置时视为开启，用户手动关闭后保持关闭。
  - 只存本机，最多 80 条且保留 30 天。
  - 不保存签名的媒体地址；删除历史不删除已下载的文件。
- 下载与导出：
  - 媒体地址必须是公网 https。
  - 导出成功以原生侧 is_pending=0 且哈希一致为准。插件接受暂停请求不代表已经暂停，要等实际的状态事件。
  - 导出的视频归用户所有，卸载工具时不删除。
- 轻量逻辑随应用一起发布，只有重型纯资源才按需安装。解析器没有大资源，不显示假的下载安装过程。
- 真实作品链接只在用户授权后联调；离线测试一律用合成数据。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/toolbox android/app/src
- 本目录的标记集中在以下几处：
  - 免登录与设备级归属
  - 注册表
  - 卸载确认
  - 资源卸载范围
  - 来源选择
  - 历史默认开启
- 公共目录导出的决策在 ToolboxFileExporter.kt。
