# local 本地存储

定位：设备上的持久化，只依赖 domain，不访问网络，也不感知页面。数据库文件都放在应用数据库目录（getDatabasesPath）下。

# 文件职责

- account_store.dart：账号索引与账号库定位。
  - account_index.db 有三张表：
    - account：账号键、来源、学号、显示名、旧库暂缓标记。
    - active_account：活动账号指针，只有一行。
    - legacy_claim：旧库认领记录，只有一行，状态从 claimed 变为 done。
  - 账号键：对规范化后的来源 URL 与学号取 sha256。
    - 来源 URL 保留校园部署的 base path；端口、大小写和末尾斜线的等价写法共用同一个库。
    - 拒绝带凭据、查询或片段的来源。
  - 账号库路径为 accounts/账号键.db，打开时校验 owner。
  - 旧版单库 superxd.db：用户确认归属后只认领一次，导入目标必须是该账号自己的库。
- app_database.dart：单个账号的业务库 AppDatabase，schema 版本 6。
  - 表：
    - session：会话与 cookie，只有一行。
    - term：学期、当前学期标记、开学日。
    - schedule_revision：课表版本。
    - schedule_head：每学期的当前版本。
    - grades_cache：成绩载荷与学年摘要。
    - bells_cache：作息原始缓存。
    - term_bells_source：作息的采用来源绑定。
    - account_owner：库的归属，只有一行。
    - legacy_import_marker：旧库导入完成标记。
    - reminder_setting：课前提醒设置，每学期一行（v6 新增）。
  - 课表写入（saveSchedule、syncSchedule、restoreRevision）在同一事务内完成：
    1. 读取 head，核对 expectedRevisionId。
    2. 写入新版本并更新 head。
    3. 裁剪到每学期 100 版，当前 head 与最近一次教务基线受保护。
  - 分页与批量：
    - 版本列表按 sequence 游标分页（revisionPage），单页最多 100 条。
    - 升级和导入之后的全量裁剪按学期分批进行。
    - 成绩学年摘要 summary_json 缺失时按需回填。
  - 开启了 SQLite 外键：schedule_head 引用 schedule_revision。
  - 表结构只通过 onCreate、onUpgrade 按版本号创建和迁移。
- credential_store.dart：
  - CredentialStore：记住账号的凭据存取接口。
  - SecureCredentialStore：基于系统安全存储的实现，按账号键保存带版本号的 JSON。
- display_settings.dart：设备级显示设置。
  - DisplaySettings 存在 display_settings.db（schema 版本 5），包括字号、配色、字体、深浅色、玻璃效果（auto、full、reduced，默认 auto），以及自定义壁纸（文件名、色调网格、模糊与淡化档位）。
  - 壁纸文件交给 WallpaperStore；复制、落库、删旧文件在保存锁内一次完成。启动时文件丢失则按未设置处理，并清理残留文件。
  - DisplayScope 负责向下传递；CampusTextScaler 在系统字号基础上叠加应用字号。
- wallpaper_store.dart：WallpaperStore 管理壁纸文件，放在应用支持目录 display/wallpaper 下，只保留当前一份，单图上限 20MB；每次导入用新文件名。
- legacy_import.dart：旧单库导入 importLegacyDatabase。
  - 旧库只读打开，只支持 user_version 1–2。
  - 按主键游标每批读取 200 行。发生冲突时一律保留目标数据，计为跳过。
  - 旧版本 id 加前缀，避免与现有 id 冲突。
  - 只绑定本次真正导入的作息与版本；不导入旧会话。
  - 写入完成标记，保证重复导入幂等。

# 关键规则

- 每个账号独立一个库。库内 owner 与当前身份不一致时直接拒绝打开；不认领没有 owner 的旧库。
- 切换账号时保留各账号的数据；退出登录只清会话，不删除缓存。
- 凭据只在用户明确同意记住账号且认证成功后写入系统安全存储；业务库、账号索引和日志都不存密码。
- 显示设置属于设备，切换账号时保留。保存时在锁内合并完整快照，快速连续修改不会互相覆盖。
- 新增表或列时：
  - 只在 onUpgrade 里按版本号迁移，并同步更新 test/schedule_migration_test.dart 或对应的迁移测试。
  - 只增不删的表，必须同时给出上限或清理策略。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/local
- 本目录的标记位于以下几处：
  - 账号库归属与旧库认领
  - 版本上限与裁剪
  - 凭据保存条件
  - 显示设置的设备归属与深浅色
