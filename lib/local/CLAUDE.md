# local 本地存储

定位：设备上的持久化，只依赖 domain，不访问网络，也不感知页面。数据库文件都放在应用数据库目录（getDatabasesPath）下；iOS 上组合根把它改到应用支持目录的 databases（默认的 Documents 开放给「文件」App 放导出的文件）。

# 文件职责

- account_store.dart：账号索引与账号库定位。
  - account_index.db 有三张表：
    - account：账号键、来源、学号、显示名、旧库暂缓标记。显示名是教务姓名，同步课表时记下（saveDisplayName），登录时传空不覆盖已知的；会话被清后靠它补回（displayNameOf）。
    - active_account：活动账号指针，只有一行。
    - legacy_claim：旧库认领记录，只有一行，状态从 claimed 变为 done。
  - 账号键：对规范化后的来源 URL 与学号取 sha256。
    - 来源 URL 保留校园部署的 base path；端口、大小写和末尾斜线的等价写法共用同一个库。
    - 拒绝带凭据、查询或片段的来源。
  - 账号库路径为 accounts/账号键.db，打开时校验 owner。
  - 旧版单库 superxd.db：用户确认归属后只认领一次，导入目标必须是该账号自己的库。
- app_database.dart：单个账号的业务库 AppDatabase（版本号见 openDatabase 的 version）。
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
    - reminder_setting：课前提醒设置，每学期一行（v6 新增；v7 加状态栏胶囊开关 live，默认关闭）。
    - schedule_sync_hold：和本地改过的课表冲突、等用户来选的教务课表（v8 新增），每学期最多一行，dismissed 为选过保留本地（同一份不再等）；教务课表落成新版本时在同一事务里删掉。
    - auto_sync：自动同步的设置与上次结果（v8 新增），只有一行。
  - 课表写入（saveSchedule、syncSchedule、mergeSchedule、restoreRevision）在同一事务内完成：
    - mergeSchedule 一次写两版：先教务同步（下次三方合并的基准，latestEduCourses 走 (xn, xq, source, sequence) 索引取最近一版），合并结果不同时再写一版我的修改；教务这份和最近一版教务同步一样时只写我的修改。readAutoSync 认不出库里的名字时跳过那一项、不抛错。
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
  - DisplaySettings 存在 display_settings.db，包括字号（text_scale：0 是跟随系统，否则是字号条上选的实际显示大小 80%–200%、5% 一档，跟随系统时也不小于 80%、最多到组合根量的推荐上限，[人工决策] 在 textSizeMin 处）、配色（四套，默认 defaultPaletteId 雾蓝；改任何一项都整份快照落库，存过的保持原值，[人工决策] 在常量处）、字体（默认 Maple；安卓与 iOS 都多一项系统字体 systemFont，fontFamily 为空即系统字体，[人工决策] 在 systemFont 处；衬线是下载的字体包）、深浅色、玻璃效果（auto、full、reduced，默认 auto），以及自定义壁纸（文件名、色调网格、模糊与淡化 0–100）。v6 把旧的三档下标按原效果换算成连续量；v7 把删掉的苔灰换成雾蓝、iOS 存着的系统字体一次性换成 Maple；v8 把字号从系统字号上的倍数换成实际大小（原来的标准跟随系统，较大及以上换成当时的系统字号 × 倍数）。
  - wallpaperLook 是壁纸模糊与淡化的当前外观：previewWallpaper 只改它、不落库，背景单独监听；setWallpaperLook 立即更新外观并在保存锁内落库，落库后不回写外观（保存期间继续拖动不会被拽回）。
  - 壁纸文件交给 WallpaperStore；复制、落库、删旧文件在保存锁内一次完成。启动时文件丢失则按未设置处理，并清理残留文件。
  - DisplayScope 负责向下传递；CampusTextScale 把字号（跟随系统或选的大小；跟随时最多到 followLimit，由组合根的 page/text_size_range.dart 的 TextSizeComfort 量好传入）按线性缩放交给全应用，变化时在 duration 内连续过渡（组合根套在 MaterialApp.builder 里，减少动画时直接换，[人工决策] 在类上），systemOf 给界面页取系统本来的字号。
  - appearance 是当前界面配置（AppearanceShare，不含壁纸图片），用于分享与套用前的撤销点；applyAppearance 套用好友分享的配置，本版本支持的取值在保存锁内一并落库，不支持的保持不变并返回跳过的项名；里面的衬线本机没装时照样选上并开始下载，这个版本下不了（没配中转、本机也没有）才按不支持跳过。
  - 字体包（人工决策见 domain/font_pack.dart）：fontPacks 是组合根注入的 FontPackLibrary（测试与内存实例为空，此时字体包里的字体当作已装好）。fontId 是选的字体，fontInUse 是界面实际用的：选的字体包还没装好（升级上来、下载中、文件坏了）时先用默认字体、选择保留，装好再换过去，只在实际用的字体变了才通知（下载进度不让整个应用重建）。open 时选着字体包就核对本机文件并注册（首帧之前，不联网）；chooseFont（界面页点选）先下载、核对、注册好再换上，期间又点了别的就作罢；ensureFontPack 由组合根在同意协议与政策之后调，把选着却没装的下回来；deleteFontPack 正在用就先换回默认字体再删文件。
- font_packs.dart：FontPackLibrary 管下载的字体包（人工决策见 domain/font_pack.dart）：文件放应用支持目录 font_packs（排除出系统备份与换机迁移，iOS 由组合根标记），每个文件核对大小与 SHA-256 才用（下载完一次、注册前读文件时再一次，都在后台 isolate 里读与算），用 FontLoader 注册（registerFontPack，测试可注入）；下载经组合根注入的 FontPackSource（device 层，没配中转时为空、只能用已经下好的）；同一个包同时只装一份；进度按整百分比通知；失败留着已下好的字重、重试只下缺的，取消与删除把这个包的文件全删。保留与清理：只留登记表里现有的文件（每个包几 MB 的固定一组），打开时删掉别的（旧版本、下载残留）；换字体不删，用户可在界面页⋯里删除，系统清除数据或卸载即删。
- wallpaper_store.dart：WallpaperStore 管理壁纸文件，放在应用支持目录 display/wallpaper 下，只保留当前一份，单图上限 20MB；每次导入用新文件名。
- app_update_memory.dart：FileAppUpdateMemory 实现应用更新的检查记录端口 AppUpdateMemory：应用支持目录下固定大小的 app_update.json（上次检查成功的时刻 UTC、跳过的版本、是否待必须更新），先写临时文件再改名；读到坏文件当没有记录。不放数据库：只有三个字段，不随数据增长。
- legal_notice_memory.dart：LegalNoticeMemory 记用户协议与隐私政策同意过、看过哪一版：应用支持目录下固定大小的 legal_notice.json（同意与已读两个修订号），写法同上；check 决定弹什么（没在首次启动弹窗里同意过的先征得同意，新装与老用户都算；同意过的有实质变化时提示一次，[人工决策] 在方法上），takePending 一次运行只取一次（pending 表示还有没取走的，打扰时机等它先弹），点「同意」后 markAgreed、点「知道了」后 markSeen；agreed 在同意后完成，组合根等它再联网。
- diagnostic_log.dart：本机诊断日志 DiagnosticLog，campusLog 的第二份输出（组合根用 tee 接上），写进应用专属外部目录的 logs（Android/data/包名/files/logs，连电脑可 adb pull，其他应用读不到，卸载即删；取不到时退回应用支持目录的 logs；两处都已排除备份与换机迁移；iOS 没有外部目录，放在应用支持目录 device_only/logs，组合根标记排除）。
  - 平时只记错误（消息带 errorType= 或堆栈，堆栈的调试包写法与 --split-debug-info 正式包的写法都认），开发者模式记全部；先进内存缓冲，每 2 秒或切到后台时批量追加，写盘出错只报到控制台。
  - 日志目录上的读写（追加、轮换改名、清理压缩、读取、打包、删除）都排在同一把锁上（synchronized 的 Lock），读到一半不会撞上改名；两处同时导出共用一次。
  - 打开时不等清理：清理与跨天压缩排进写入队列，不拖慢启动；存储出错（外部存储暂时不可用等）也只报到控制台，不挡应用启动。
  - 上限（常量在文件头）：错误记录 errors.log 写满 diagnosticErrorLimit 改名成 errors.1.log，两份合计约 1MB；开发者模式日志按校园日分文件、单个超过 diagnosticFileLimit 另起分卷（只往当天最新一卷追加，卷号就是先后），保留 diagnosticKeepDays 天、总量不超过 diagnosticTotalLimit，打开与每次写入后从最旧的删起。
  - 落盘前把链接（含 www. 开头与不带协议的域名加路径）与手机号（含 +86 前缀与空格、短横分隔）掩掉（日志可能被导出、贴进公开 Issue）；recent 只读最新的一段（diagnosticViewBytes、最多 diagnosticViewLimit 条）给查看页，errorKinds 读整份错误记录，两者的读文件、解压与解析都在后台 isolate 里做；clearDiagnostics 只删开发者模式日志，clear 全删。
  - 同类错误聚合（[人工决策] 在类上）：签名 diagnosticErrorSignature 是掩码后首行再掩掉编号与数字，带堆栈的再接上前三帧出错位置的短摘要（正式包用 virt 偏移），上次退出原因（diagnosticExitHead）不参与合并；同一签名 diagnosticRepeatWindow 内只记第一条全文、其余计数，窗口到了补一条 action=repeat（count、seconds、last），同时记着的签名不超过 diagnosticRepeatKinds；flush(settle) 在导出、切到后台与按种类汇总前全部结算，clear 时一并忘掉。errorKinds 按种类汇总错误、summary 拼诊断摘要。
  - 早于今天的开发者模式日志在后台 isolate 里压成 .log.gz（超过保留天数的先删、不压），查看时解开读、导出原样放进 zip。
  - textSize 是组合根在开发者模式下随变化更新的字号状态，摘要与 about.txt 写在运行环境后面。
  - export 把全部日志加 about.txt（运行环境、字号状态、导出时刻）在后台 isolate 里打成 zip，经组合根注入的 publish 存进 Download/SuperXD，临时包放缓存的 diagnostics_export、用完即删。
  - upload 打同一个包交给组合根注入的 DiagnosticUploader（device 层：本机加密后传到中转，人工决策见 domain/diagnostic_upload.dart），回诊断编号，临时包用完即删；没配中转时不注入，canUpload 为假、开发者选项里不出现上传。
- developer_note_memory.dart：FileDeveloperNoteMemory 实现开发者的话的本机记录 DeveloperNoteMemory：应用支持目录下的 developer_notes.json（上次拉到的信、读过与弹过的编号、上次拉取成功的时刻 UTC），信最多 developerNoteLimit 封、编号只留还在清单里的，大小有上限；写法同 legal_notice.json，写入经锁一个接一个，读到坏文件当没有记录。
- festival_memory.dart：FileFestivalMemory 实现节日的本机记录 FestivalMemory：应用支持目录下的 festival.json（抽奖身份的状态（密钥本身在安全存储）、近 30 天打开过的校园日、最近 festivalHistoryLimit 次播过与抽过的节日、抽中的奖品），写法同 legal_notice.json，读到坏文件或坏项丢掉；各项有上限，奖品由 application/festivals.dart 按节日结束后 3 天清。
- rollout_memory.dart：FileRolloutMemory 实现灰度的本机记录 RolloutMemory（人工决策见 domain/rollout.dart）：应用支持目录下的 rollout.json（这台设备的随机编号，没登录应用账号时分桶用、只在本机不上传；上次拉到的配置与时刻），写法同 legal_notice.json，坏文件当没有、编号重新生成；只有一份配置，不随使用增长。
- painting_library.dart：PaintingLibrary 实现 domain 的 PaintingGallery：启动时读随安装包的画作清单，按清单顺序接着上次取这次开屏的一幅（next，一次运行只取一次）；轮换记录是应用支持目录下固定大小的 splash_painting.json（只记上次那幅的 id，写法同 legal_notice.json，读到坏文件从第一幅起）；save 把原图拷到缓存、经组合根注入的 publish（device/picture_export.dart）存进 Download/SuperXD，用完即删。
- developer_settings.dart：DeveloperSettings 记开发者模式与性能浮层两个开关：应用支持目录下固定大小的 developer.json（iOS 放 device_only 下），写法同 legal_notice.json，写入经锁一个接一个（连点开关不交错）；已排除备份与换机迁移（[人工决策] 在类上）；关掉开发者模式时性能浮层一起关，读到坏文件当都关着。
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
- 显示设置、开发者设置与本机日志属于设备，切换账号时保留。显示设置保存时在锁内合并完整快照，快速连续修改不会互相覆盖。
- 新增表或列时：
  - 只在 onUpgrade 里按版本号迁移，并同步更新 test/schedule_migration_test.dart 或对应的迁移测试。
  - 只增不删的表，必须同时给出上限或清理策略。
- AppDatabase 的 revisionSummaries、termStartDate、gradesPayload、insertRevision、openMemory 只有测试或工具在用，删除前先改测试。

# 测试

- 账号库与旧库：account_store_test.dart、account_isolation_test.dart、legacy_import_test.dart。
- 课表与作息持久化：schedule_version_test.dart、schedule_migration_test.dart、bells_persistence_test.dart；等用户来选的教务课表、自动同步设置与 v8 升级：auto_sync_test.dart。
- 显示设置与壁纸：appearance_settings_test.dart、wallpaper_test.dart；字体包的本机文件、核对、注册与显示设置的接线：font_pack_test.dart；开屏画作的轮换与保存：painting_test.dart；应用更新检查记录：app_update_test.dart；开发者的话的本机记录：developer_notes_test.dart；节日的本机记录：festival_test.dart；灰度的本机记录：rollout_test.dart；协议已读记录：legal_page_test.dart；本机日志与开发者设置：diagnostic_log_test.dart。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/local
- 本目录的标记位于以下几处：
  - 账号库归属与旧库认领
  - 版本上限与裁剪
  - 凭据保存条件
  - 显示设置的设备归属与深浅色
  - 配色（删苔灰）与字体默认值（默认 Maple、安卓与 iOS 都可选系统字体，v7 一次性迁移）
  - 协议的同意与更新提示的判定
  - 本机日志的同类错误聚合口径（diagnostic_log.dart 类上）
  - 开发者设置排除备份（developer_settings.dart 类上）
